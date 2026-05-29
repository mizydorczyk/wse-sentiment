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

lemmatize_tokens <- function(articles_df, udpipe_model, doc_id_col = "article_id") {
  texts <- clean_text(articles_df$text)
  ids <- articles_df[[doc_id_col]]
  unique_idx <- !duplicated(ids)
  unique_texts <- texts[unique_idx]
  unique_ids <- ids[unique_idx]

  annotated <- udpipe_annotate(udpipe_model, x = unique_texts, doc_id = unique_ids)
  tokens <- as.data.frame(annotated, stringsAsFactors = FALSE)

  tokens |>
    filter(!is.na(.data$lemma), .data$lemma != "") |>
    transmute(
      article_id = .data$doc_id,
      sentence_id = paste0(.data$doc_id, "_s", .data$sentence_id),
      token_id = as.integer(.data$token_id),
      token = .data$token,
      lemma = tolower(.data$lemma),
      pos = .data$upos
    )
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
    filter(.data$sentiment %in% c("positive", "negative", "uncertainty", "litigious", "constraining"))
}

`%||%` <- function(x, y) if (is.null(x) || (length(x) == 1 && is.na(x))) y else x

load_udpipe_model <- function(model_path = constants$udpipe_model_pl) {
  if (!file.exists(model_path)) {
    stop(sprintf("udpipe model not found: %s", model_path))
  }
  udpipe_load_model(file = model_path)
}
