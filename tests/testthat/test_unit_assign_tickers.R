library(testthat)

old_wd <- getwd()
on.exit(setwd(old_wd), add = TRUE)
setwd("../..")

source("src/assign_tickers.R")

test_that("regex escaping works correctly", {
  expect_equal(escape_regex("CD Projekt"), "CD Projekt")
  expect_equal(escape_regex("PlayWay S.A."), "PlayWay S\\.A\\.")
  expect_equal(escape_regex("11 bit studios (11B)"), "11 bit studios \\(11B\\)")
})

test_that("dictionary compilation produces valid regexes", {
  expect_true(is.list(compiled_dictionary))

  # Pick a known company to verify its compiled regex (assuming CDR exists in your dictionary)
  cdr <- purrr::detect(compiled_dictionary, ~ .$ticker == "CDR")
  if (!is.null(cdr)) {
    expect_true(is.character(cdr$regex) || is.na(cdr$regex))
  }
})

test_that("score_article handles empty inputs gracefully", {
  empty_article <- list(
    metadata = list(title = ""),
    content = list(lead = "", paragraphs = list())
  )

  result <- score_article(empty_article)
  expect_equal(length(result), 0)
})

test_that("score_article skips if no content exists", {
  empty_article_null <- list(
    metadata = list(),
    content = list()
  )

  result <- score_article(empty_article_null)
  expect_equal(length(result), 0)
})
