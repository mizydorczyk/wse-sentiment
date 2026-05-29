suppressPackageStartupMessages({
  library(jsonlite)
  library(dplyr)
  library(tidyr)
  library(stringr)
  library(stringi)
  library(udpipe)
  library(stopwords)
})

source("src/common/constants.R")

load_articles_with_tickers <- function(
  manifest_path = constants$processed_manifest_file,
  articles_dir = constants$articles_directory,
  min_relevance = 0
) {
  if (!file.exists(manifest_path)) {
    stop(sprintf("Processed manifest not found: %s. Run src/assign_tickers.R first.", manifest_path))
  }

  manifest <- fromJSON(manifest_path, simplifyVector = FALSE)
  rows <- lapply(manifest, function(item) {
    article_file <- file.path(articles_dir, item$file)
    if (!file.exists(article_file)) return(NULL)
    article <- fromJSON(article_file, simplifyVector = FALSE)

    lead <- article$content$lead %||% ""
    paragraphs <- unlist(article$content$paragraphs) %||% character(0)
    text <- paste(c(lead, paragraphs), collapse = "\n")

    pub_date <- article$metadata$publication_date %||% NA_character_
    title <- article$metadata$title %||% NA_character_

    tickers <- item$tickers
    if (length(tickers) == 0) {
      data.frame(
        article_id = item$id,
        ticker = NA_character_,
        relevance_score = NA_integer_,
        publication_date = pub_date,
        title = title,
        text = text,
        stringsAsFactors = FALSE
      )
    } else {
      do.call(rbind, lapply(tickers, function(t) {
        data.frame(
          article_id = item$id,
          ticker = t$ticker,
          relevance_score = t$relevance_score,
          publication_date = pub_date,
          title = title,
          text = text,
          stringsAsFactors = FALSE
        )
      }))
    }
  })

  bind_rows(rows) |>
    filter(is.na(relevance_score) | relevance_score >= min_relevance)
}

clean_text <- function(x) {
  x <- stri_trans_nfc(x)
  x <- str_replace_all(x, "[‘’‚‛′ʼ`´]", "'")
  x <- str_replace_all(x, "[“”„‟″]", "\"")
  x <- str_replace_all(x, " ", " ")
  x <- tolower(x)
  x <- str_replace_all(x, "[[:digit:]]+", " ")
  x <- str_replace_all(x, "[[:punct:]]+", " ")
  x <- str_squish(x)
  x
}

lemmatize_tokens <- function(articles_df, udpipe_model, doc_id_col = "article_id",
                             cache_path = NULL, batch_size = 200L) {
  # Batched udpipe call (default 200 articles/batch) instead of one monster call
  # over all 9666 — gives progress, allows incremental cache save (resume after kill),
  # and avoids the silent slowdown observed on huge vector inputs to udpipe_annotate.
  needed_ids <- unique(articles_df[[doc_id_col]])

  # Resume: if a partial cache exists, skip articles already lemmatized.
  cached <- NULL
  if (!is.null(cache_path) && file.exists(cache_path)) {
    cached <- readRDS(cache_path)
    cached_ids <- unique(cached$article_id)
    missing_ids <- setdiff(needed_ids, cached_ids)
    if (length(missing_ids) == 0) {
      message(sprintf("Lemmatize cache hit: %s (%d tokens, %d articles)",
                      cache_path, nrow(cached), length(cached_ids)))
      return(cached |> filter(.data$article_id %in% needed_ids))
    }
    message(sprintf("Lemmatize cache resume: %d/%d articles already done, %d to go",
                    length(intersect(needed_ids, cached_ids)), length(needed_ids), length(missing_ids)))
    articles_df <- articles_df |> filter(.data[[doc_id_col]] %in% missing_ids)
  }

  texts <- clean_text(articles_df$text)
  ids <- articles_df[[doc_id_col]]
  unique_idx <- !duplicated(ids)
  unique_texts <- texts[unique_idx]
  unique_ids <- ids[unique_idx]
  n <- length(unique_ids)
  message(sprintf("Lemmatizing %d unique articles via udpipe (batch_size=%d)...", n, batch_size))

  batches <- split(seq_len(n), ceiling(seq_len(n) / batch_size))
  acc <- if (!is.null(cached)) list(cached) else list()
  t0 <- Sys.time()

  for (b in seq_along(batches)) {
    idx <- batches[[b]]
    annotated <- udpipe_annotate(udpipe_model, x = unique_texts[idx], doc_id = unique_ids[idx])
    batch_tokens <- as.data.frame(annotated, stringsAsFactors = FALSE) |>
      filter(!is.na(.data$lemma), .data$lemma != "") |>
      transmute(
        article_id = .data$doc_id,
        sentence_id = paste0(.data$doc_id, "_s", .data$sentence_id),
        token_id = as.integer(.data$token_id),
        token = .data$token,
        lemma = tolower(.data$lemma),
        pos = .data$upos
      )
    acc[[length(acc) + 1L]] <- batch_tokens

    done <- b * batch_size
    elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
    rate <- min(done, n) / elapsed
    eta <- (n - min(done, n)) / max(rate, 0.01)
    message(sprintf("  batch %d/%d  articles=%d/%d  %.1fs elapsed  %.1f art/s  ETA %.0fs",
                    b, length(batches), min(done, n), n, elapsed, rate, eta))

    # Save partial cache every 5 batches (1000 articles) for crash resume.
    if (!is.null(cache_path) && b %% 5 == 0) {
      if (!dir.exists(dirname(cache_path))) dir.create(dirname(cache_path), recursive = TRUE)
      saveRDS(bind_rows(acc), cache_path)
    }
  }

  result <- bind_rows(acc)
  if (!is.null(cache_path)) {
    if (!dir.exists(dirname(cache_path))) dir.create(dirname(cache_path), recursive = TRUE)
    saveRDS(result, cache_path)
    message(sprintf("Saved lemmatize cache: %s (%d tokens)", cache_path, nrow(result)))
  }
  result |> filter(.data$article_id %in% needed_ids)
}

load_stopwords_pl <- function(custom_path = constants$stopwords_custom) {
  base <- stopwords::stopwords("pl", source = "stopwords-iso")
  custom <- character(0)
  if (file.exists(custom_path)) {
    df <- read.csv(custom_path, stringsAsFactors = FALSE, encoding = "UTF-8")
    if ("lemma" %in% names(df)) custom <- df$lemma
  }
  unique(c(tolower(base), tolower(custom)))
}

load_sentiment_lexicon <- function(
  plwn_path = constants$sentiment_lexicon_general,
  lm_pl_path = constants$sentiment_lm_pl,
  custom_path = constants$sentiment_pl_custom
) {
  lex_list <- list()

  if (file.exists(plwn_path)) {
    plwn <- read.csv(plwn_path, stringsAsFactors = FALSE, encoding = "UTF-8")
    if (!"category" %in% names(plwn)) plwn$category <- plwn$sentiment
    lex_list$plwn <- plwn |>
      select(any_of(c("lemma", "pos", "sentiment", "category"))) |>
      mutate(source = "plwn", priority = 1L)
  }

  if (file.exists(lm_pl_path)) {
    lm_pl <- read.csv(lm_pl_path, stringsAsFactors = FALSE, encoding = "UTF-8")
    lex_list$lm_pl <- lm_pl |>
      select(any_of(c("lemma", "pos", "sentiment", "category"))) |>
      mutate(source = "lm_pl", priority = 2L)
  }

  if (file.exists(custom_path)) {
    cust <- read.csv(custom_path, stringsAsFactors = FALSE, encoding = "UTF-8")
    lex_list$custom <- cust |>
      select(any_of(c("lemma", "pos", "sentiment", "category"))) |>
      mutate(source = "pl_custom", priority = 3L)
  }

  if (length(lex_list) == 0) {
    warning("No sentiment lexicons found. Returning empty tibble.")
    return(tibble::tibble(
      lemma = character(),
      pos = character(),
      sentiment = character(),
      category = character(),
      source = character(),
      priority = integer()
    ))
  }

  bind_rows(lex_list) |>
    mutate(
      lemma = tolower(.data$lemma),
      pos = ifelse(is.na(.data$pos) | .data$pos == "", "ANY", .data$pos)
    ) |>
    group_by(.data$lemma, .data$pos) |>
    slice_max(.data$priority, n = 1, with_ties = FALSE) |>
    ungroup() |>
    filter(.data$sentiment %in% c("positive", "negative", "uncertainty", "litigious", "constraining")) |>
    # Safety net: only open-class POS can carry sentiment. Function words (ADP, DET,
    # PRON, CCONJ, SCONJ, AUX, PART, INTJ) leaked from DeepL translations of legal
    # English ("wherein"→"w", "thereof"→"on") and would flood matches in any text.
    filter(.data$pos %in% c("NOUN", "VERB", "ADJ", "ADV", "PROPN", "ANY"))
}

`%||%` <- function(x, y) if (is.null(x) || (length(x) == 1 && is.na(x))) y else x

load_udpipe_model <- function(model_path = constants$udpipe_model_pl) {
  if (!file.exists(model_path)) {
    stop(sprintf("udpipe model not found: %s", model_path))
  }
  udpipe_load_model(file = model_path)
}
