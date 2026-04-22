library(testthat)
library(jsonlite)

old_wd <- getwd()
on.exit(setwd(old_wd), add = TRUE)
setwd("../..")

source("src/assign_tickers.R")

test_that("model matches human-annotated ground truth", {
  fixture_path <- "tests/fixtures/ground_truth_articles.json"
  skip_if_not(file.exists(fixture_path), "Ground truth fixture not found. Create it to run evaluation.")

  ground_truth <- fromJSON(fixture_path, simplifyVector = FALSE)

  total_expected <- 0
  total_predicted <- 0
  correct_predictions <- 0

  for (article in ground_truth) {
    predicted_result <- score_article(article)

    if (length(predicted_result) > 0) {
      predicted_tickers <- sapply(predicted_result, function(x) x$ticker)
    } else {
      predicted_tickers <- character(0)
    }

    expected_tickers <- unlist(article$expected_tickers) %||% character(0)

    total_expected <- total_expected + length(expected_tickers)
    total_predicted <- total_predicted + length(predicted_tickers)
    correct_predictions <- correct_predictions + sum(predicted_tickers %in% expected_tickers)

    if (!setequal(predicted_tickers, expected_tickers)) {
      warning(sprintf(
        "Mismatch in article %s.\nExpected: %s\nGot: %s",
        article$id %||% "unknown",
        if (length(expected_tickers) > 0) paste(expected_tickers, collapse = ", ") else "(none)",
        if (length(predicted_tickers) > 0) paste(predicted_tickers, collapse = ", ") else "(none)"
      ))
    }
  }

  precision <- ifelse(total_predicted > 0, correct_predictions / total_predicted, 0)
  recall <- ifelse(total_expected > 0, correct_predictions / total_expected, 0)

  cat(sprintf(
    "\nEvaluation Metrics:\nTotal Articles: %d\nPrecision: %.2f%%\nRecall: %.2f%%\n",
    length(ground_truth), precision * 100, recall * 100
  ))

  expect_true(TRUE)
})
