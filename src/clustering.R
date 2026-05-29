#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(dplyr)
  library(tidyr)
  library(stringr)
  library(tm)
  library(tidytext)
  library(topicmodels)
  library(ggplot2)
  library(wordcloud)
  library(RColorBrewer)
})

source("src/common/constants.R")
source("src/common/text_pipeline.R")

content_pos_filter <- c("PUNCT", "NUM", "SYM", "X")

filter_content_tokens <- function(tokens_df, stopwords_vec) {
  tokens_df |>
    filter(
      !is.na(.data$lemma),
      .data$lemma != "",
      nchar(.data$lemma) >= 3,
      !.data$lemma %in% stopwords_vec,
      !.data$pos %in% content_pos_filter
    )
}

build_dtm <- function(tokens_df, stopwords_vec, sparse_threshold = 0.99) {
  filtered <- filter_content_tokens(tokens_df, stopwords_vec)

  counts <- filtered |>
    count(.data$article_id, .data$lemma, name = "n") |>
    filter(.data$n > 0)

  if (nrow(counts) == 0) {
    stop("No tokens left after filtering — cannot build DTM.")
  }

  dtm <- counts |>
    cast_dtm(document = .data$article_id, term = .data$lemma, value = .data$n)

  if (sparse_threshold < 1 && ncol(dtm) > 1) {
    pruned <- tryCatch(
      tm::removeSparseTerms(dtm, sparse_threshold),
      error = function(e) dtm
    )
    if (ncol(pruned) > 0) dtm <- pruned
  }

  dtm
}

run_lda <- function(dtm, k, seed = 1234) {
  non_empty_rows <- unique(dtm$i)
  if (length(non_empty_rows) == 0) {
    stop("DTM has no non-empty documents.")
  }
  dtm <- dtm[non_empty_rows, ]

  n_docs <- nrow(dtm)
  k_eff <- min(k, n_docs)
  if (k_eff < 2) k_eff <- max(2, min(2, n_docs))
  if (k_eff > n_docs) k_eff <- n_docs

  set.seed(seed)
  topicmodels::LDA(dtm, k = k_eff, control = list(seed = seed))
}

extract_topics_beta <- function(lda, top_n_per_topic = 15) {
  tidytext::tidy(lda, matrix = "beta") |>
    group_by(.data$topic) |>
    slice_max(.data$beta, n = top_n_per_topic, with_ties = FALSE) |>
    ungroup() |>
    arrange(.data$topic, desc(.data$beta))
}

extract_article_gamma <- function(lda) {
  tidytext::tidy(lda, matrix = "gamma") |>
    rename(article_id = "document") |>
    arrange(.data$article_id, .data$topic)
}

compute_tfidf_per_ticker <- function(tokens_df, articles_df, stopwords_vec) {
  filtered <- filter_content_tokens(tokens_df, stopwords_vec)

  ticker_map <- articles_df |>
    select(any_of(c("article_id", "ticker"))) |>
    filter(!is.na(.data$ticker), .data$ticker != "") |>
    distinct()

  joined <- filtered |>
    inner_join(ticker_map, by = "article_id", relationship = "many-to-many")

  if (nrow(joined) == 0) {
    return(tibble::tibble(
      ticker = character(),
      word = character(),
      n = integer(),
      tf = numeric(),
      idf = numeric(),
      tf_idf = numeric()
    ))
  }

  joined |>
    count(.data$ticker, .data$lemma, name = "n") |>
    bind_tf_idf(.data$lemma, .data$ticker, .data$n) |>
    rename(word = "lemma") |>
    arrange(.data$ticker, desc(.data$tf_idf))
}

compute_word_freq <- function(tokens_df, stopwords_vec, top_n = 100) {
  filter_content_tokens(tokens_df, stopwords_vec) |>
    count(.data$lemma, name = "freq") |>
    rename(word = "lemma") |>
    arrange(desc(.data$freq)) |>
    slice_head(n = top_n)
}

ensure_figures_dir <- function() {
  if (!dir.exists(constants$figures_directory)) {
    dir.create(constants$figures_directory, recursive = TRUE)
  }
}

plot_topics_facet <- function(beta_df, top_n = 10, filename = "topics_lda.png") {
  ensure_figures_dir()
  plot_df <- beta_df |>
    group_by(.data$topic) |>
    slice_max(.data$beta, n = top_n, with_ties = FALSE) |>
    ungroup() |>
    mutate(
      topic = factor(.data$topic),
      term = tidytext::reorder_within(.data$term, .data$beta, .data$topic)
    )

  p <- ggplot(plot_df, aes(x = .data$beta, y = .data$term, fill = .data$topic)) +
    geom_col(show.legend = FALSE) +
    facet_wrap(~ .data$topic, scales = "free") +
    tidytext::scale_y_reordered() +
    scale_fill_brewer(palette = "Set2") +
    labs(
      title = "LDA — top slowa per topic",
      x = "beta (prawdopodobienstwo slowa w temacie)",
      y = NULL
    ) +
    theme_minimal(base_size = 11)

  outpath <- file.path(constants$figures_directory, filename)
  ggsave(outpath, p, width = 10, height = 8, dpi = 150, units = "in")
  invisible(outpath)
}

plot_tfidf_facet <- function(tfidf_df, top_n = 10, top_tickers = 10,
                             filename = "tfidf_per_ticker.png") {
  ensure_figures_dir()

  if (nrow(tfidf_df) == 0) {
    message("TF-IDF per ticker is empty — skipping plot.")
    return(invisible(NULL))
  }

  ticker_rank <- tfidf_df |>
    group_by(.data$ticker) |>
    summarise(score = sum(.data$tf_idf, na.rm = TRUE), .groups = "drop") |>
    arrange(desc(.data$score)) |>
    slice_head(n = top_tickers) |>
    pull(.data$ticker)

  plot_df <- tfidf_df |>
    filter(.data$ticker %in% ticker_rank) |>
    group_by(.data$ticker) |>
    slice_max(.data$tf_idf, n = top_n, with_ties = FALSE) |>
    ungroup() |>
    mutate(
      ticker = factor(.data$ticker, levels = ticker_rank),
      word = tidytext::reorder_within(.data$word, .data$tf_idf, .data$ticker)
    )

  p <- ggplot(plot_df, aes(x = .data$tf_idf, y = .data$word, fill = .data$ticker)) +
    geom_col(show.legend = FALSE) +
    facet_wrap(~ .data$ticker, scales = "free") +
    tidytext::scale_y_reordered() +
    scale_fill_brewer(palette = "Set3") +
    labs(
      title = "TF-IDF — najbardziej charakterystyczne slowa per ticker",
      x = "tf-idf",
      y = NULL
    ) +
    theme_minimal(base_size = 11)

  outpath <- file.path(constants$figures_directory, filename)
  ggsave(outpath, p, width = 10, height = 8, dpi = 150, units = "in")
  invisible(outpath)
}

plot_wordcloud_global <- function(freq_df, filename = "wordcloud_global.png",
                                  max_words = 100) {
  ensure_figures_dir()
  if (nrow(freq_df) == 0) {
    message("Word frequency is empty — skipping global wordcloud.")
    return(invisible(NULL))
  }

  outpath <- file.path(constants$figures_directory, filename)
  res <- tryCatch({
    png(outpath, width = 10, height = 8, units = "in", res = 150)
    on.exit(dev.off(), add = TRUE)
    wordcloud(
      words = freq_df$word,
      freq = freq_df$freq,
      max.words = max_words,
      min.freq = 1,
      random.order = FALSE,
      rot.per = 0.2,
      colors = brewer.pal(8, "Dark2"),
      scale = c(4, 0.6)
    )
    TRUE
  }, error = function(e) {
    message(sprintf("Global wordcloud failed: %s", conditionMessage(e)))
    FALSE
  })

  if (!isTRUE(res)) return(invisible(NULL))
  invisible(outpath)
}

plot_wordcloud_per_topic <- function(beta_df, k, filename_prefix = "wordcloud_topic") {
  ensure_figures_dir()
  topics <- sort(unique(beta_df$topic))
  outpaths <- character(0)

  for (t in topics) {
    sub <- beta_df |>
      filter(.data$topic == t) |>
      arrange(desc(.data$beta))

    if (nrow(sub) == 0) next

    outpath <- file.path(
      constants$figures_directory,
      sprintf("%s_%d.png", filename_prefix, t)
    )

    ok <- tryCatch({
      png(outpath, width = 10, height = 8, units = "in", res = 150)
      on.exit(dev.off(), add = TRUE)
      wordcloud(
        words = sub$term,
        freq = sub$beta,
        max.words = nrow(sub),
        min.freq = 0,
        random.order = FALSE,
        rot.per = 0.2,
        colors = brewer.pal(8, "Set1"),
        scale = c(4, 0.6)
      )
      TRUE
    }, error = function(e) {
      message(sprintf("Wordcloud for topic %d failed: %s", t, conditionMessage(e)))
      FALSE
    })

    if (isTRUE(ok)) outpaths <- c(outpaths, outpath)
  }

  invisible(outpaths)
}

save_outputs <- function(beta, gamma, tfidf, freq) {
  if (!dir.exists(constants$processed_directory)) {
    dir.create(constants$processed_directory, recursive = TRUE)
  }

  write.csv(beta, constants$topics_lda, row.names = FALSE, fileEncoding = "UTF-8")
  write.csv(gamma, constants$article_topic_gamma, row.names = FALSE, fileEncoding = "UTF-8")
  write.csv(tfidf, constants$tfidf_per_ticker, row.names = FALSE, fileEncoding = "UTF-8")
  write.csv(freq, constants$word_freq, row.names = FALSE, fileEncoding = "UTF-8")

  invisible(list(
    topics_lda = constants$topics_lda,
    article_topic_gamma = constants$article_topic_gamma,
    tfidf_per_ticker = constants$tfidf_per_ticker,
    word_freq = constants$word_freq
  ))
}

run_clustering_pipeline <- function() {
  message("Loading articles + tickers...")
  articles_df <- load_articles_with_tickers(min_relevance = 0)
  n_articles <- length(unique(articles_df$article_id))

  message(sprintf("Loaded %d unique articles. Lemmatizing...", n_articles))
  ud_model <- load_udpipe_model()
  tokens_df <- lemmatize_tokens(articles_df, ud_model)
  stopwords_vec <- load_stopwords_pl()

  message("Building DTM...")
  dtm <- build_dtm(tokens_df, stopwords_vec, sparse_threshold = 0.99)
  vocab_size <- ncol(dtm)
  message(sprintf("DTM: %d docs x %d terms.", nrow(dtm), vocab_size))

  k_target <- constants$sentiment_lda_k
  k_used <- min(k_target, nrow(dtm))
  message(sprintf("Running LDA with k = %d (target %d)...", k_used, k_target))
  lda <- run_lda(dtm, k_target)
  k_used <- lda@k

  beta <- extract_topics_beta(lda, top_n_per_topic = 15)
  gamma <- extract_article_gamma(lda)
  tfidf <- compute_tfidf_per_ticker(tokens_df, articles_df, stopwords_vec)
  freq <- compute_word_freq(tokens_df, stopwords_vec, top_n = 100)

  message("Saving CSV outputs...")
  save_outputs(beta, gamma, tfidf, freq)

  message("Generating plots...")
  plot_topics_facet(beta)
  plot_tfidf_facet(tfidf)
  plot_wordcloud_global(freq)
  plot_wordcloud_per_topic(beta, k_used)

  top_per_topic <- beta |>
    group_by(.data$topic) |>
    slice_max(.data$beta, n = 1, with_ties = FALSE) |>
    ungroup() |>
    arrange(.data$topic)

  message("=== Clustering summary ===")
  message(sprintf("Articles (unique):    %d", n_articles))
  message(sprintf("Vocab size (DTM):     %d", vocab_size))
  message(sprintf("LDA topics used (k):  %d", k_used))
  message("Top word per topic:")
  for (i in seq_len(nrow(top_per_topic))) {
    message(sprintf("  topic %d: %s (beta=%.4f)",
                    top_per_topic$topic[i],
                    top_per_topic$term[i],
                    top_per_topic$beta[i]))
  }

  invisible(list(
    n_articles = n_articles,
    vocab_size = vocab_size,
    k = k_used,
    beta = beta,
    gamma = gamma,
    tfidf = tfidf,
    freq = freq
  ))
}

if (sys.nframe() == 0) {
  run_clustering_pipeline()
}
