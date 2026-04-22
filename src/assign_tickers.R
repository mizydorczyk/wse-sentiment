#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(stringr)
  library(dplyr)
  library(purrr)
  library(udpipe)
})

source("src/company_dictionary.R")
source("src/common/constants.R")

raw_articles_dir <- constants$articles_directory
processed_manifest_file <- file.path("dataset", "processed", "articles_manifest.json")

if (!dir.exists(dirname(processed_manifest_file))) {
  dir.create(dirname(processed_manifest_file), recursive = TRUE)
}

model_file <- file.path("assets", "polish-pdb-ud-2.5-191206.udpipe")
if (!file.exists(model_file)) {
  message(sprintf("UDPipe model file not found at '%s'", model_file))
  quit(status = 1)
}
ud_model <- udpipe_load_model(file = model_file)

escape_regex <- function(values) {
  str_replace_all(values, "([\\.\\|\\(\\)\\[\\]\\{\\}\\+\\*\\?\\^\\$\\\\])", "\\\\\\1")
}

compiled_dictionary <- map(company_dictionary, function(company) {
  if (!is.null(company$stems)) {
    company$stems_lower <- tolower(company$stems)
  } else {
    company$stems_lower <- character(0)
  }

  patterns <- c()
  if (!is.null(company$acronyms)) {
    safe_acronyms <- escape_regex(company$acronyms)
    acronym_patterns <- paste0("\\b", safe_acronyms, "(?:-[a-ząćęłńóśźż]{1,3})?\\b")
    patterns <- c(patterns, acronym_patterns)
  }

  if (!is.null(company$exact_phrases)) {
    safe_phrases <- escape_regex(company$exact_phrases)
    phrase_patterns <- paste0("\\b", safe_phrases, "\\b")
    patterns <- c(patterns, phrase_patterns)
  }

  if (length(patterns) > 0) {
    full_pattern <- paste0("(", paste(patterns, collapse = "|"), ")")
    company$regex <- regex(full_pattern, ignore_case = !isTRUE(company$strict_case))
  } else {
    company$regex <- NA
  }

  company
})

score_article <- function(article_content) {
  title <- article_content$metadata$title %||% ""
  lead <- article_content$content$lead %||% ""
  paragraphs <- unlist(article_content$content$paragraphs) %||% character(0)
  paragraphs_text <- paste(paragraphs, collapse = "\n")

  ticker_scores <- list()

  score_text_block <- function(text, weight) {
    if (is.null(text) || nchar(trimws(text)) == 0) {
      return()
    }

    annotated <- udpipe_annotate(ud_model, x = text)
    lemmas_df <- as.data.frame(annotated)
    valid_lemmas_df <- lemmas_df[!is.na(lemmas_df$lemma), ]
    lemmas <- tolower(valid_lemmas_df$lemma)

    for (company in compiled_dictionary) {
      score <- 0

      if (length(company$stems_lower) > 0) {
        if (isTRUE(company$strict_case)) {
          is_capitalized <- grepl("^[A-ZŚĆŹŻĄĘŁÓŃ]", valid_lemmas_df$token)
          matches <- sum((lemmas %in% company$stems_lower) & is_capitalized)
        } else {
          matches <- sum(lemmas %in% company$stems_lower)
        }
        score <- score + (matches * weight)
      }

      if (!identical(company$regex, NA)) {
        matches <- sum(str_count(text, company$regex))
        score <- score + (matches * weight)
      }

      if (score > 0) {
        if (is.null(ticker_scores[[company$ticker]])) ticker_scores[[company$ticker]] <<- 0
        ticker_scores[[company$ticker]] <<- ticker_scores[[company$ticker]] + score
      }
    }
  }

  score_text_block(title, 5)
  score_text_block(lead, 3)
  score_text_block(paragraphs_text, 1)

  filtered_scores <- list()
  for (t in names(ticker_scores)) {
    if (ticker_scores[[t]] >= 2) {
      filtered_scores[[t]] <- ticker_scores[[t]]
    }
  }

  if (length(filtered_scores) > 0) {
    df <- data.frame(
      ticker = names(filtered_scores),
      relevance_score = unlist(filtered_scores, use.names = FALSE),
      stringsAsFactors = FALSE
    ) |>
      arrange(desc(.data$relevance_score))

    lapply(seq_len(nrow(df)), function(i) list(ticker = df$ticker[i], relevance_score = df$relevance_score[i]))
  } else {
    list()
  }
}

process_all_articles <- function() {
  json_files <- list.files(raw_articles_dir, pattern = "\\.json$", full.names = TRUE)
  if (length(json_files) == 0) {
    return()
  }

  manifest <- list()
  if (file.exists(processed_manifest_file)) {
    message("Loading existing manifest to resume progress...")
    tryCatch(
      {
        loaded <- fromJSON(processed_manifest_file, simplifyVector = FALSE)
        if (is.null(names(loaded)) && length(loaded) > 0) {
          for (item in loaded) manifest[[item$id]] <- item
        } else {
          manifest <- loaded
        }
      },
      error = function(e) message("Starting fresh.")
    )
  }

  new_processed <- 0
  processed_count <- length(manifest)
  assigned_count <- 0
  if (length(manifest) > 0) {
    assigned_count <- sum(sapply(manifest, function(x) is.list(x$tickers) && length(x$tickers) > 0), na.rm = TRUE)
  }

  for (i in seq_along(json_files)) {
    file_path <- json_files[i]
    file_name <- basename(file_path)
    article_id <- tools::file_path_sans_ext(file_name)

    if (!is.null(manifest[[article_id]])) next

    article_data <- tryCatch(fromJSON(file_path, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(article_data) || !is.null(article_data$error)) next

    assigned_tickers <- score_article(article_data)

    manifest[[article_id]] <- list(
      id = article_id,
      file = file_name,
      url = article_data$metadata$url,
      tickers = assigned_tickers
    )

    if (length(assigned_tickers) > 0) assigned_count <- assigned_count + 1
    new_processed <- new_processed + 1
    processed_count <- processed_count + 1

    if (new_processed %% 10 == 0) {
      message(sprintf(
        "Newly processed %d articles... (Total %d/%d)", new_processed, processed_count, length(json_files)
      ))
      write_json(unname(manifest), processed_manifest_file, pretty = TRUE, auto_unbox = TRUE)
    }
  }

  write_json(unname(manifest), processed_manifest_file, pretty = TRUE, auto_unbox = TRUE)
  message(sprintf(
    "Done! Total processed: %d. Total articles with assigned tickers: %d.", processed_count, assigned_count
  ))
}

if (sys.nframe() == 0) {
  process_all_articles()
}
