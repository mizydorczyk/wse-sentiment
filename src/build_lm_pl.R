#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
  library(readr)
  library(stringr)
  library(udpipe)
  library(deeplr)
})

source("src/common/constants.R")
source("src/common/text_pipeline.R")

loughran_path <- file.path(
  Sys.getenv("HOME"),
  "repo", "Projektowanie_systemow_informatycznych_2026",
  "04.Zajecia", "_Slowniki_w_CSV", "loughran.csv"
)

lm_cache_path <- file.path(constants$workspace_cache, "lm_translations_raw.csv")
lm_out_csv <- constants$sentiment_lm_pl

lm_excluded_categories <- c("superfluous", "modal_strong", "modal_weak")

lm_category_map <- list(
  positive     = list(sentiment = "positive", category = "positive"),
  negative     = list(sentiment = "negative", category = "negative"),
  uncertainty  = list(sentiment = "negative", category = "uncertainty"),
  litigious    = list(sentiment = "negative", category = "litigious"),
  constraining = list(sentiment = "negative", category = "constraining")
)

load_lm_source <- function(path = loughran_path) {
  if (!file.exists(path)) {
    stop(sprintf("Loughran-McDonald source CSV not found: %s", path))
  }
  df <- read_csv(path, show_col_types = FALSE)
  required <- c("word", "sentiment")
  missing <- setdiff(required, names(df))
  if (length(missing) > 0) {
    stop(sprintf("loughran.csv missing columns: %s", paste(missing, collapse = ", ")))
  }
  df |>
    mutate(
      word = str_trim(.data$word),
      sentiment = str_trim(tolower(.data$sentiment))
    ) |>
    filter(!is.na(.data$word), .data$word != "") |>
    filter(!.data$sentiment %in% lm_excluded_categories) |>
    distinct(.data$word, .data$sentiment)
}

load_cache <- function(cache_path = lm_cache_path) {
  if (file.exists(cache_path)) {
    suppressWarnings(read_csv(cache_path, show_col_types = FALSE))
  } else {
    tibble(
      word_en = character(),
      sentiment_en = character(),
      translation_pl = character(),
      status = character()
    )
  }
}

save_cache <- function(cache_df, cache_path = lm_cache_path) {
  if (!dir.exists(dirname(cache_path))) {
    dir.create(dirname(cache_path), recursive = TRUE)
  }
  write_csv(cache_df, cache_path)
}

translate_word <- function(word, auth_key) {
  tryCatch(
    {
      out <- deeplr::translate2(
        text = word,
        target_lang = "PL",
        source_lang = "EN",
        auth_key = auth_key
      )
      list(translation = as.character(out), status = "ok")
    },
    error = function(e) {
      list(translation = NA_character_, status = paste0("error_", substr(conditionMessage(e), 1, 200)))
    }
  )
}

translate_all <- function(lm_df, auth_key, cache_path = lm_cache_path, save_every = 100L, sleep_s = 0.05) {
  cache <- load_cache(cache_path)
  already_done <- cache$word_en

  todo <- lm_df |> filter(!.data$word %in% already_done)
  message(sprintf("Cache hits: %d, to translate: %d", length(already_done), nrow(todo)))

  if (nrow(todo) == 0) return(cache)

  acc <- vector("list", nrow(todo))
  n_since_save <- 0L

  for (i in seq_len(nrow(todo))) {
    w <- todo$word[i]
    s <- todo$sentiment[i]
    res <- translate_word(w, auth_key)
    acc[[i]] <- tibble(
      word_en = w,
      sentiment_en = s,
      translation_pl = res$translation,
      status = res$status
    )
    n_since_save <- n_since_save + 1L

    if (sleep_s > 0) Sys.sleep(sleep_s)

    if (n_since_save >= save_every) {
      new_chunk <- bind_rows(acc[seq_len(i)])
      combined <- bind_rows(cache, new_chunk) |>
        distinct(.data$word_en, .keep_all = TRUE)
      save_cache(combined, cache_path)
      message(sprintf("  saved cache at %d / %d", i, nrow(todo)))
      n_since_save <- 0L
    }
  }

  new_rows <- bind_rows(acc)
  combined <- bind_rows(cache, new_rows) |>
    distinct(.data$word_en, .keep_all = TRUE)
  save_cache(combined, cache_path)
  combined
}

# Pick a representative lemma from a multi-token udpipe annotation. Priority:
# NOUN > VERB > ADJ > ADV > first non-empty token. Returns list(lemma, pos).
select_main_token <- function(tokens_df) {
  if (is.null(tokens_df) || nrow(tokens_df) == 0) {
    return(list(lemma = NA_character_, pos = NA_character_))
  }
  clean <- tokens_df |>
    filter(!is.na(.data$lemma), .data$lemma != "", !is.na(.data$upos))
  if (nrow(clean) == 0) {
    return(list(lemma = NA_character_, pos = NA_character_))
  }
  for (target in c("NOUN", "VERB", "ADJ", "ADV")) {
    hit <- clean |> filter(.data$upos == target)
    if (nrow(hit) > 0) {
      return(list(lemma = tolower(hit$lemma[1]), pos = hit$upos[1]))
    }
  }
  list(lemma = tolower(clean$lemma[1]), pos = clean$upos[1])
}

lemmatize_translations <- function(translations_df, ud_model) {
  ok <- translations_df |>
    filter(.data$status == "ok", !is.na(.data$translation_pl), .data$translation_pl != "")

  if (nrow(ok) == 0) {
    return(tibble(
      word_en = character(), sentiment_en = character(),
      translation_pl = character(), lemma = character(), pos = character()
    ))
  }

  texts <- tolower(str_trim(ok$translation_pl))
  ids <- as.character(seq_len(nrow(ok)))

  annotated <- udpipe_annotate(ud_model, x = texts, doc_id = ids)
  tokens <- as.data.frame(annotated, stringsAsFactors = FALSE)

  picked <- lapply(ids, function(doc) {
    sub <- tokens[tokens$doc_id == doc, , drop = FALSE]
    select_main_token(tibble(lemma = sub$lemma, upos = sub$upos))
  })

  ok |>
    mutate(
      lemma = vapply(picked, function(p) p$lemma, character(1)),
      pos = vapply(picked, function(p) p$pos, character(1))
    ) |>
    filter(!is.na(.data$lemma), .data$lemma != "", !is.na(.data$pos))
}

map_lm_sentiment <- function(df) {
  df |>
    rowwise() |>
    mutate(
      sentiment = lm_category_map[[.data$sentiment_en]]$sentiment %||% NA_character_,
      category = lm_category_map[[.data$sentiment_en]]$category %||% NA_character_
    ) |>
    ungroup() |>
    filter(!is.na(.data$sentiment))
}

dedupe_lemmas <- function(df) {
  df |>
    group_by(.data$lemma, .data$pos) |>
    summarise(
      sentiment = {
        tab <- sort(table(.data$sentiment), decreasing = TRUE)
        names(tab)[1]
      },
      category = {
        tab <- sort(table(.data$category), decreasing = TRUE)
        names(tab)[1]
      },
      source_en = paste(unique(.data$word_en), collapse = ";"),
      .groups = "drop"
    ) |>
    mutate(verified = "auto") |>
    select(.data$lemma, .data$pos, .data$sentiment, .data$category, .data$source_en, .data$verified) |>
    arrange(.data$lemma, .data$pos)
}

dry_run <- function(n = 10) {
  auth_key <- Sys.getenv("DEEPL_API_KEY")
  if (!nzchar(auth_key)) {
    stop("DEEPL_API_KEY env var not set. Register at https://www.deepl.com/pro-api and add `DEEPL_API_KEY=xxx:fx` to ~/.Renviron")
  }
  lm_df <- load_lm_source() |> head(n)
  message(sprintf("Dry run on %d words", nrow(lm_df)))

  results <- lapply(seq_len(nrow(lm_df)), function(i) {
    w <- lm_df$word[i]
    res <- translate_word(w, auth_key)
    Sys.sleep(0.05)
    tibble(
      word_en = w,
      sentiment_en = lm_df$sentiment[i],
      translation_pl = res$translation,
      status = res$status
    )
  })
  translations <- bind_rows(results)

  ud_model <- load_udpipe_model()
  lemmatized <- lemmatize_translations(translations, ud_model)
  mapped <- map_lm_sentiment(lemmatized)
  mapped
}

build_lm_pl <- function() {
  auth_key <- Sys.getenv("DEEPL_API_KEY")
  if (!nzchar(auth_key)) {
    stop(paste0(
      "DEEPL_API_KEY env var not set.\n",
      "  Register a free account at https://www.deepl.com/pro-api (DeepL API Free)\n",
      "  Add `DEEPL_API_KEY=xxx:fx` to ~/.Renviron and restart R."
    ))
  }

  if (!dir.exists(constants$workspace_cache)) {
    dir.create(constants$workspace_cache, recursive = TRUE)
  }
  if (!dir.exists(constants$dictionaries_directory)) {
    dir.create(constants$dictionaries_directory, recursive = TRUE)
  }

  lm_df <- load_lm_source()
  message(sprintf("Loughran-McDonald source: %d words (after excluding %s)",
                  nrow(lm_df), paste(lm_excluded_categories, collapse = ", ")))

  translations <- translate_all(lm_df, auth_key)
  n_total <- nrow(translations)
  n_ok <- sum(translations$status == "ok", na.rm = TRUE)
  n_err <- n_total - n_ok
  message(sprintf("Translations total: %d (ok: %d, err: %d)", n_total, n_ok, n_err))

  message("Loading udpipe model...")
  ud_model <- load_udpipe_model()

  message("Lemmatizing translations...")
  lemmatized <- lemmatize_translations(translations, ud_model)
  message(sprintf("Lemmatized rows: %d", nrow(lemmatized)))

  mapped <- map_lm_sentiment(lemmatized)
  message(sprintf("After sentiment mapping: %d", nrow(mapped)))

  final <- dedupe_lemmas(mapped)
  message(sprintf("After dedupe (lemma, pos): %d", nrow(final)))

  write_csv(final, lm_out_csv)
  message(sprintf("Wrote %s", lm_out_csv))

  message("--- Summary ---")
  message(sprintf("EN source words:  %d", nrow(lm_df)))
  message(sprintf("Translated ok:    %d", n_ok))
  message(sprintf("Translation err:  %d", n_err))
  message(sprintf("After lemmatize:  %d", nrow(lemmatized)))
  message(sprintf("After dedupe:     %d", nrow(final)))
  by_cat <- final |> count(.data$category)
  for (i in seq_len(nrow(by_cat))) {
    message(sprintf("  %s: %d", by_cat$category[i], by_cat$n[i]))
  }
  by_sent <- final |> count(.data$sentiment)
  for (i in seq_len(nrow(by_sent))) {
    message(sprintf("  %s: %d", by_sent$sentiment[i], by_sent$n[i]))
  }

  invisible(final)
}

if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  if ("--dry-run" %in% args) {
    message("Running dry-run on 10 words (no save).")
    result <- dry_run(10)
    print(result)
  } else {
    message("Running full LM_PL build. Use --dry-run flag for testing without burning DeepL quota.")
    build_lm_pl()
  }
}
