#!/usr/bin/env Rscript
# Lemmatize the full corpus (cache to RDS for sentiment.R / clustering.R reuse),
# then produce a top-N review CSV: most frequent (lemma, pos) pairs that exist
# in sentiment_lm_pl.csv. User reviews this small set (~50) for mistranslations,
# apply_lm_pl_review.R applies the corrections.

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
  library(readr)
})

source("src/common/constants.R")
source("src/common/text_pipeline.R")

top_n <- 50L
review_dir <- constants$workspace_review
review_csv <- file.path(review_dir, "lm_pl_top50.csv")

main <- function() {
  if (!dir.exists(review_dir)) dir.create(review_dir, recursive = TRUE)

  message("=== Step 1: load articles ===")
  articles <- load_articles_with_tickers(min_relevance = 0)
  n_articles <- length(unique(articles$article_id))
  message(sprintf("  %d unique articles, %d (article, ticker) rows", n_articles, nrow(articles)))

  message("=== Step 2: lemmatize (cache to RDS) ===")
  model <- load_udpipe_model()
  tokens <- lemmatize_tokens(articles, model, cache_path = constants$lemmatized_tokens_cache)
  message(sprintf("  %d tokens total", nrow(tokens)))

  message("=== Step 3: load LM_PL lexicon ===")
  lm_pl <- read_csv(constants$sentiment_lm_pl, show_col_types = FALSE)
  message(sprintf("  %d LM_PL entries", nrow(lm_pl)))

  message("=== Step 4: count token frequency, join with LM_PL ===")
  freq <- tokens |>
    count(.data$lemma, .data$pos, name = "freq_in_corpus") |>
    filter(.data$freq_in_corpus > 0)
  message(sprintf("  %d unique (lemma, pos) pairs in corpus", nrow(freq)))

  joined <- lm_pl |>
    inner_join(freq, by = c("lemma", "pos")) |>
    arrange(desc(.data$freq_in_corpus))
  message(sprintf("  %d LM_PL entries present in corpus", nrow(joined)))

  top <- joined |> head(top_n)

  # Add columns for user review.
  review <- top |>
    transmute(
      lemma = .data$lemma,
      pos = .data$pos,
      freq_in_corpus = .data$freq_in_corpus,
      sentiment = .data$sentiment,
      category = .data$category,
      source_en = .data$source_en,
      # Edit these two if translation/category is wrong; leave empty to accept auto.
      sentiment_corrected = "",
      category_corrected = "",
      action = "",  # "keep" | "drop" | "fix" (set when sentiment_corrected/category_corrected filled)
      notes = ""
    )

  write_csv(review, review_csv)
  message(sprintf("\nWrote review CSV: %s", review_csv))
  message(sprintf("Open it, edit `sentiment_corrected` / `category_corrected` / `action` columns,"))
  message(sprintf("then run: Rscript src/apply_lm_pl_review.R\n"))

  message("=== Quick preview (top 20) ===")
  print(top |> head(20))

  invisible(review)
}

if (sys.nframe() == 0) main()
