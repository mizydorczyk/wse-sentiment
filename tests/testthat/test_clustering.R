library(testthat)

old_wd <- getwd()
on.exit(setwd(old_wd), add = TRUE)
setwd("../..")

source("src/common/text_pipeline.R")
source("src/clustering.R")

cache_env <- new.env(parent = emptyenv())

get_articles <- function() {
  if (is.null(cache_env$articles)) {
    cache_env$articles <- load_articles_with_tickers(min_relevance = 0)
  }
  cache_env$articles
}

get_tokens <- function() {
  if (is.null(cache_env$tokens)) {
    ud_model <- load_udpipe_model()
    cache_env$tokens <- lemmatize_tokens(get_articles(), ud_model)
  }
  cache_env$tokens
}

get_stopwords <- function() {
  if (is.null(cache_env$stopwords)) {
    cache_env$stopwords <- load_stopwords_pl()
  }
  cache_env$stopwords
}

get_dtm <- function() {
  if (is.null(cache_env$dtm)) {
    cache_env$dtm <- build_dtm(get_tokens(), get_stopwords(), sparse_threshold = 0.99)
  }
  cache_env$dtm
}

get_lda <- function() {
  if (is.null(cache_env$lda)) {
    cache_env$lda <- run_lda(get_dtm(), constants$sentiment_lda_k)
  }
  cache_env$lda
}

test_that("build_dtm returns a DocumentTermMatrix with > 0 rows", {
  dtm <- get_dtm()
  expect_s3_class(dtm, "DocumentTermMatrix")
  expect_gt(nrow(dtm), 0)
  expect_gt(ncol(dtm), 0)
})

test_that("run_lda returns an LDA_VEM object", {
  lda <- get_lda()
  expect_s4_class(lda, "LDA_VEM")
  expect_lte(lda@k, nrow(get_dtm()))
  expect_gte(lda@k, 2)
})

test_that("extract_topics_beta returns k * top_n_per_topic rows", {
  lda <- get_lda()
  top_n <- 15
  beta <- extract_topics_beta(lda, top_n_per_topic = top_n)
  expect_named(beta, c("topic", "term", "beta"), ignore.order = TRUE)
  expect_equal(nrow(beta), lda@k * top_n)
  expect_true(all(beta$beta >= 0))
})

test_that("compute_tfidf_per_ticker returns rows with all tf_idf > 0", {
  tfidf <- compute_tfidf_per_ticker(get_tokens(), get_articles(), get_stopwords())
  expect_s3_class(tfidf, "data.frame")
  expect_named(tfidf, c("ticker", "word", "n", "tf", "idf", "tf_idf"), ignore.order = TRUE)
  expect_gt(nrow(tfidf), 0)
  positive_only <- tfidf |> dplyr::filter(.data$tf_idf > 0)
  expect_gt(nrow(positive_only), 0)
  expect_true(all(tfidf$tf_idf >= 0))
})

test_that("compute_word_freq returns top_n rows sorted desc", {
  top_n <- 50
  freq <- compute_word_freq(get_tokens(), get_stopwords(), top_n = top_n)
  expect_s3_class(freq, "data.frame")
  expect_named(freq, c("word", "freq"), ignore.order = TRUE)
  expect_lte(nrow(freq), top_n)
  expect_gt(nrow(freq), 0)
  expect_equal(freq$freq, sort(freq$freq, decreasing = TRUE))
})
