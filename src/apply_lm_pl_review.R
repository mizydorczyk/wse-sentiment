#!/usr/bin/env Rscript
# Apply manual review corrections from lm_pl_top50.csv to sentiment_lm_pl.csv.
# Rules:
#   action == "drop"  → remove the (lemma, pos) entry from sentiment_lm_pl.csv
#   action == "fix"   → update sentiment/category from *_corrected columns; set verified="manual"
#   action == "keep"  → set verified="manual" (signal that human reviewed and accepts auto)
#   action empty      → no change (skipped silently)

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

source("src/common/constants.R")

review_csv <- file.path(constants$workspace_review, "lm_pl_top50.csv")

main <- function() {
  if (!file.exists(review_csv)) {
    stop(sprintf("Review CSV not found: %s\n  Run src/build_lm_pl_topfreq.R first.", review_csv))
  }

  review <- read_csv(review_csv, show_col_types = FALSE) |>
    mutate(action = tolower(trimws(.data$action %||% "")))
  lm_pl <- read_csv(constants$sentiment_lm_pl, show_col_types = FALSE)

  message(sprintf("Loaded %d review rows, %d LM_PL entries", nrow(review), nrow(lm_pl)))

  drops <- review |>
    filter(.data$action == "drop") |>
    select("lemma", "pos")
  fixes <- review |>
    filter(.data$action == "fix") |>
    transmute(
      lemma = .data$lemma,
      pos = .data$pos,
      new_sentiment = ifelse(nzchar(.data$sentiment_corrected), .data$sentiment_corrected, .data$sentiment),
      new_category = ifelse(nzchar(.data$category_corrected), .data$category_corrected, .data$category)
    )
  keeps <- review |> filter(.data$action == "keep") |> select("lemma", "pos")

  message(sprintf("Drops: %d  Fixes: %d  Keeps: %d  Unflagged: %d",
                  nrow(drops), nrow(fixes), nrow(keeps),
                  sum(!review$action %in% c("drop", "fix", "keep"))))

  out <- lm_pl |>
    anti_join(drops, by = c("lemma", "pos")) |>
    left_join(fixes, by = c("lemma", "pos")) |>
    mutate(
      sentiment = ifelse(!is.na(.data$new_sentiment), .data$new_sentiment, .data$sentiment),
      category = ifelse(!is.na(.data$new_category), .data$new_category, .data$category),
      verified = case_when(
        !is.na(.data$new_sentiment) | !is.na(.data$new_category) ~ "manual",
        TRUE ~ .data$verified
      )
    ) |>
    select(-"new_sentiment", -"new_category")

  keeps_flag <- keeps |> mutate(keep = TRUE)
  out <- out |>
    left_join(keeps_flag, by = c("lemma", "pos")) |>
    mutate(verified = ifelse(!is.na(.data$keep), "manual", .data$verified)) |>
    select(-"keep")

  backup <- sub("\\.csv$", "_pre_review.csv", constants$sentiment_lm_pl)
  file.copy(constants$sentiment_lm_pl, backup, overwrite = TRUE)
  message(sprintf("Backed up original to: %s", backup))

  write_csv(out, constants$sentiment_lm_pl)
  message(sprintf("Wrote updated LM_PL: %s (%d entries, was %d)",
                  constants$sentiment_lm_pl, nrow(out), nrow(lm_pl)))

  invisible(out)
}

`%||%` <- function(x, y) if (is.null(x)) y else x

if (sys.nframe() == 0) main()
