#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(dplyr)
  library(tidyr)
  library(stringr)
  library(tibble)
  library(ggplot2)
  library(wordcloud)
  library(RColorBrewer)
  library(lubridate)
  library(scales)
})

source("src/common/constants.R")
source("src/common/text_pipeline.R")

apply_negation_flip <- function(tokens_with_sentiment, all_tokens, window = constants$sentiment_negation_window) {
  negators <- tolower(constants$sentiment_negators_pl)

  context <- all_tokens |>
    select("article_id", "sentence_id", "token_id", "lemma") |>
    rename(neg_lemma = "lemma", neg_token_id = "token_id")

  flipped <- tokens_with_sentiment |>
    rowwise() |>
    mutate(
      has_negator = {
        prev_tokens <- context |>
          filter(
            .data$article_id == .env$article_id,
            .data$sentence_id == .env$sentence_id,
            .data$neg_token_id < .env$token_id,
            .data$neg_token_id >= .env$token_id - window
          )
        any(prev_tokens$neg_lemma %in% negators)
      }
    ) |>
    ungroup() |>
    mutate(
      sentiment = if_else(
        .data$has_negator & .data$sentiment %in% c("positive", "negative"),
        if_else(.data$sentiment == "positive", "negative", "positive"),
        .data$sentiment
      )
    ) |>
    select(-"has_negator")

  flipped
}

compute_sentiment <- function(tokens, lexicon) {
  if (nrow(lexicon) == 0) {
    warning("Empty lexicon — returning empty result")
    return(tibble(
      article_id = character(),
      sentence_id = character(),
      token_id = integer(),
      lemma = character(),
      pos = character(),
      sentiment = character(),
      category = character()
    ))
  }

  matched_pos <- tokens |>
    inner_join(lexicon |> filter(.data$pos != "ANY"), by = c("lemma", "pos"))

  matched_any <- tokens |>
    inner_join(lexicon |> filter(.data$pos == "ANY") |> select(-"pos"), by = "lemma") |>
    anti_join(matched_pos, by = c("article_id", "sentence_id", "token_id"))

  matched <- bind_rows(matched_pos, matched_any) |>
    select("article_id", "sentence_id", "token_id", "lemma", "pos", "sentiment", "category")

  if (nrow(matched) == 0) return(matched)

  apply_negation_flip(matched, tokens)
}

summarize_per_article <- function(sentiment_df, all_article_ids) {
  if (nrow(sentiment_df) == 0) {
    per_article_empty <- tibble(
      article_id = all_article_ids,
      score = NA_real_,
      n_pos = 0L,
      n_neg = 0L,
      n_uncertainty = 0L,
      n_litigious = 0L,
      n_constraining = 0L,
      top_pos_words = NA_character_,
      top_neg_words = NA_character_
    )
    return(per_article_empty)
  }

  per_cat <- sentiment_df |>
    count(.data$article_id, .data$category, name = "n") |>
    pivot_wider(names_from = "category", values_from = "n", values_fill = 0)

  for (col in c("positive", "negative", "uncertainty", "litigious", "constraining")) {
    if (!col %in% names(per_cat)) per_cat[[col]] <- 0L
  }

  top_words <- sentiment_df |>
    filter(.data$sentiment %in% c("positive", "negative")) |>
    count(.data$article_id, .data$sentiment, .data$lemma, sort = TRUE) |>
    group_by(.data$article_id, .data$sentiment) |>
    slice_max(.data$n, n = 5, with_ties = FALSE) |>
    summarise(words = paste(.data$lemma, collapse = ";"), .groups = "drop") |>
    pivot_wider(names_from = "sentiment", values_from = "words", values_fill = "")

  if (!"positive" %in% names(top_words)) top_words$positive <- ""
  if (!"negative" %in% names(top_words)) top_words$negative <- ""

  result <- per_cat |>
    transmute(
      article_id = .data$article_id,
      score = .data$positive - .data$negative,
      n_pos = .data$positive,
      n_neg = .data$negative,
      n_uncertainty = .data$uncertainty,
      n_litigious = .data$litigious,
      n_constraining = .data$constraining
    ) |>
    left_join(
      top_words |> transmute(
        article_id = .data$article_id,
        top_pos_words = .data$positive,
        top_neg_words = .data$negative
      ),
      by = "article_id"
    )

  missing_ids <- setdiff(all_article_ids, result$article_id)
  if (length(missing_ids) > 0) {
    no_signal <- tibble(
      article_id = missing_ids,
      score = NA_real_,
      n_pos = 0L,
      n_neg = 0L,
      n_uncertainty = 0L,
      n_litigious = 0L,
      n_constraining = 0L,
      top_pos_words = NA_character_,
      top_neg_words = NA_character_
    )
    result <- bind_rows(result, no_signal)
  }

  result
}

summarize_per_ticker <- function(per_article, articles_with_tickers, min_relevance = constants$sentiment_ticker_min_relevance) {
  joined <- articles_with_tickers |>
    filter(!is.na(.data$ticker), .data$relevance_score >= min_relevance) |>
    select("article_id", "ticker", "relevance_score") |>
    distinct() |>
    inner_join(per_article, by = "article_id")

  if (nrow(joined) == 0) {
    return(tibble(
      ticker = character(),
      mean_score = numeric(),
      n_articles = integer(),
      n_articles_with_signal = integer(),
      articles_pos = integer(),
      articles_neg = integer()
    ))
  }

  joined |>
    group_by(.data$ticker) |>
    summarise(
      mean_score = mean(.data$score, na.rm = TRUE),
      n_articles = dplyr::n(),
      n_articles_with_signal = sum(!is.na(.data$score)),
      articles_pos = sum(.data$score > 0, na.rm = TRUE),
      articles_neg = sum(.data$score < 0, na.rm = TRUE),
      .groups = "drop"
    ) |>
    mutate(mean_score = if_else(is.nan(.data$mean_score), NA_real_, .data$mean_score)) |>
    arrange(desc(.data$mean_score))
}

summarize_timeline <- function(per_article, articles_with_tickers, granularity = constants$sentiment_timeline_granularity) {
  date_floor <- switch(granularity,
    "day" = function(x) lubridate::floor_date(x, "day"),
    "week" = function(x) lubridate::floor_date(x, "week"),
    "month" = function(x) lubridate::floor_date(x, "month"),
    function(x) lubridate::floor_date(x, "week")
  )

  unique_articles <- articles_with_tickers |>
    select("article_id", "publication_date") |>
    distinct() |>
    mutate(
      date_str = str_extract(.data$publication_date, "^\\d{4}-\\d{2}-\\d{2}(?:[ T]\\d{2}:\\d{2})?"),
      parsed_date = suppressWarnings(lubridate::ymd_hm(.data$date_str, quiet = TRUE))
    )

  unique_articles$parsed_date[is.na(unique_articles$parsed_date)] <- suppressWarnings(
    lubridate::ymd(unique_articles$date_str[is.na(unique_articles$parsed_date)], quiet = TRUE)
  )

  unique_articles |>
    filter(!is.na(.data$parsed_date)) |>
    mutate(period = date_floor(.data$parsed_date)) |>
    inner_join(per_article, by = "article_id") |>
    group_by(.data$period) |>
    summarise(
      mean_score = mean(.data$score, na.rm = TRUE),
      n_articles = dplyr::n(),
      n_articles_with_signal = sum(!is.na(.data$score)),
      .groups = "drop"
    ) |>
    arrange(.data$period)
}

plot_top_sentiment_words <- function(sentiment_df, filename = "sentiment_top_words.png", top_n = 15) {
  if (nrow(sentiment_df) == 0) {
    message("No sentiment matches — skipping top words plot")
    return(invisible(NULL))
  }

  words <- sentiment_df |>
    filter(.data$sentiment %in% c("positive", "negative")) |>
    count(.data$sentiment, .data$lemma, sort = TRUE) |>
    group_by(.data$sentiment) |>
    slice_max(.data$n, n = top_n, with_ties = FALSE) |>
    ungroup()

  if (nrow(words) == 0) return(invisible(NULL))

  p <- ggplot(words, aes(x = reorder(.data$lemma, .data$n), y = .data$n, fill = .data$sentiment)) +
    geom_col(show.legend = FALSE) +
    facet_wrap(~ .data$sentiment, scales = "free") +
    coord_flip() +
    scale_fill_manual(values = c(positive = "darkolivegreen4", negative = "firebrick")) +
    labs(x = NULL, y = "Liczba wystąpień", title = "Top słowa sentymentu (pozytywne vs negatywne)") +
    theme_minimal(base_size = 12)

  ggsave(file.path(constants$figures_directory, filename),
         plot = p, width = 10, height = 6, dpi = 150, units = "in")
  invisible(p)
}

plot_sentiment_per_ticker <- function(per_ticker, filename = "sentiment_per_ticker.png") {
  if (nrow(per_ticker) == 0) {
    message("No ticker sentiment data — skipping ticker plot")
    return(invisible(NULL))
  }

  data <- per_ticker |>
    filter(!is.na(.data$mean_score)) |>
    mutate(sign = if_else(.data$mean_score >= 0, "positive", "negative"))

  if (nrow(data) == 0) return(invisible(NULL))

  p <- ggplot(data, aes(x = reorder(.data$ticker, .data$mean_score),
                        y = .data$mean_score, fill = .data$sign)) +
    geom_col(show.legend = FALSE) +
    coord_flip() +
    scale_fill_manual(values = c(positive = "darkolivegreen4", negative = "firebrick")) +
    labs(x = "Ticker", y = "Średni score sentymentu",
         title = "Ranking spółek GPW wg sentymentu medialnego",
         subtitle = sprintf("Próg relevance ≥ %d", constants$sentiment_ticker_min_relevance)) +
    theme_minimal(base_size = 12)

  ggsave(file.path(constants$figures_directory, filename),
         plot = p, width = 10, height = 6, dpi = 150, units = "in")
  invisible(p)
}

plot_wordcloud_pos_neg <- function(sentiment_df, filename = "wordcloud_sentiment.png") {
  if (nrow(sentiment_df) == 0) {
    message("No sentiment matches — skipping wordcloud")
    return(invisible(NULL))
  }

  freq <- sentiment_df |>
    filter(.data$sentiment %in% c("positive", "negative")) |>
    count(.data$sentiment, .data$lemma, sort = TRUE)

  if (nrow(freq) == 0) return(invisible(NULL))

  png(file.path(constants$figures_directory, filename),
      width = 1200, height = 600, res = 100)
  par(mfrow = c(1, 2), mar = c(1, 1, 2, 1))
  tryCatch({
    pos <- freq |> filter(.data$sentiment == "positive")
    if (nrow(pos) > 0) {
      wordcloud(pos$lemma, pos$n, min.freq = 1, max.words = 50,
                colors = brewer.pal(8, "Greens")[4:8], scale = c(3, 0.5))
      title("Pozytywne")
    }
    neg <- freq |> filter(.data$sentiment == "negative")
    if (nrow(neg) > 0) {
      wordcloud(neg$lemma, neg$n, min.freq = 1, max.words = 50,
                colors = brewer.pal(8, "Reds")[4:8], scale = c(3, 0.5))
      title("Negatywne")
    }
  }, error = function(e) message("Wordcloud error: ", conditionMessage(e)))
  dev.off()
  invisible(NULL)
}

plot_sentiment_timeline <- function(timeline_df, filename = "sentiment_timeline.png") {
  if (nrow(timeline_df) == 0) {
    message("No timeline data — skipping timeline plot")
    return(invisible(NULL))
  }

  p <- ggplot(timeline_df, aes(x = .data$period, y = .data$mean_score)) +
    geom_line(color = "steelblue", linewidth = 1) +
    geom_point(color = "steelblue", size = 2) +
    geom_smooth(method = "loess", se = TRUE, color = "darkorange",
                fill = "darkorange", alpha = 0.2, formula = y ~ x) +
    geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
    labs(x = "Okres", y = "Średni sentyment",
         title = "Indeks sentymentu GPW w czasie",
         subtitle = sprintf("Granularność: %s", constants$sentiment_timeline_granularity)) +
    theme_minimal(base_size = 12)

  ggsave(file.path(constants$figures_directory, filename),
         plot = p, width = 10, height = 6, dpi = 150, units = "in")
  invisible(p)
}

save_sentiment_outputs <- function(per_article, per_ticker, timeline) {
  if (!dir.exists(constants$processed_directory)) {
    dir.create(constants$processed_directory, recursive = TRUE)
  }
  write.csv(per_article, constants$sentiment_per_article, row.names = FALSE, fileEncoding = "UTF-8")
  write.csv(per_ticker, constants$sentiment_per_ticker, row.names = FALSE, fileEncoding = "UTF-8")
  write.csv(timeline, constants$sentiment_timeline, row.names = FALSE, fileEncoding = "UTF-8")
}

run_sentiment_pipeline <- function() {
  message("Loading articles + tickers...")
  articles <- load_articles_with_tickers(min_relevance = 0)
  unique_article_ids <- unique(articles$article_id)
  message(sprintf("  %d article-ticker pairs, %d unique articles", nrow(articles), length(unique_article_ids)))

  message("Loading udpipe model + lemmatizing...")
  model <- load_udpipe_model()
  tokens <- lemmatize_tokens(articles, model)
  message(sprintf("  %d tokens lemmatized", nrow(tokens)))

  message("Loading sentiment lexicon...")
  lexicon <- load_sentiment_lexicon()
  message(sprintf("  %d entries (sources: %s)",
                  nrow(lexicon),
                  paste(unique(lexicon$source), collapse = ", ")))

  message("Computing sentiment...")
  sentiment_df <- compute_sentiment(tokens, lexicon)
  message(sprintf("  %d sentiment-bearing tokens matched", nrow(sentiment_df)))

  message("Summarizing per article / ticker / timeline...")
  per_article <- summarize_per_article(sentiment_df, unique_article_ids)
  per_ticker <- summarize_per_ticker(per_article, articles)
  timeline <- summarize_timeline(per_article, articles)

  message(sprintf("  Articles with signal: %d / %d",
                  sum(!is.na(per_article$score)), nrow(per_article)))
  message(sprintf("  Tickers in ranking (relevance >= %d): %d",
                  constants$sentiment_ticker_min_relevance, nrow(per_ticker)))
  message(sprintf("  Timeline periods: %d", nrow(timeline)))

  save_sentiment_outputs(per_article, per_ticker, timeline)

  if (!dir.exists(constants$figures_directory)) {
    dir.create(constants$figures_directory, recursive = TRUE)
  }
  plot_top_sentiment_words(sentiment_df)
  plot_sentiment_per_ticker(per_ticker)
  plot_wordcloud_pos_neg(sentiment_df)
  plot_sentiment_timeline(timeline)

  message("\n=== Per-ticker ranking ===")
  print(per_ticker, n = Inf)
  message("\n=== Per-article scores ===")
  print(per_article |> select("article_id", "score", "n_pos", "n_neg"), n = Inf)

  invisible(list(per_article = per_article, per_ticker = per_ticker, timeline = timeline))
}

if (sys.nframe() == 0) {
  run_sentiment_pipeline()
}
