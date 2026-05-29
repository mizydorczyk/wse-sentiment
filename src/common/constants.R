constants <- list(
  raw_directory = file.path("dataset", "raw"),
  rss_feeds_path = file.path("dataset", "raw", "rss.csv"),
  archive_feeds_path = file.path("dataset", "raw", "archive.csv"),
  combined_feeds_path = file.path("dataset", "raw", "feeds.csv"),
  wig20_weekly_path = file.path("dataset", "raw", "wig20_w.csv"),
  articles_directory = file.path("dataset", "raw", "articles"),
  articles_manifest_path = file.path("dataset", "raw", "articles_manifest.json"),
  processed_manifest_file = file.path("dataset", "processed", "articles_manifest.json"),

  dictionaries_directory = file.path("dataset", "dictionaries"),
  sentiment_lexicon_general = file.path("dataset", "dictionaries", "plwordnet_emo.csv"),
  sentiment_lm_pl = file.path("dataset", "dictionaries", "sentiment_lm_pl.csv"),
  sentiment_pl_custom = file.path("dataset", "dictionaries", "sentiment_pl_custom.csv"),
  stopwords_custom = file.path("dataset", "dictionaries", "stopwords_custom_pl.csv"),

  processed_directory = file.path("dataset", "processed"),
  lemmatized_tokens_cache = file.path("dataset", "processed", "lemmatized_tokens.rds"),
  sentiment_per_article = file.path("dataset", "processed", "sentiment_per_article.csv"),
  sentiment_per_ticker = file.path("dataset", "processed", "sentiment_per_ticker.csv"),
  sentiment_timeline = file.path("dataset", "processed", "sentiment_timeline.csv"),
  topics_lda = file.path("dataset", "processed", "topics_lda.csv"),
  article_topic_gamma = file.path("dataset", "processed", "article_topic_gamma.csv"),
  tfidf_per_ticker = file.path("dataset", "processed", "tfidf_per_ticker.csv"),
  tfidf_global = file.path("dataset", "processed", "tfidf_global.csv"),
  article_dates = file.path("dataset", "processed", "article_dates.csv"),
  word_freq = file.path("dataset", "processed", "word_freq.csv"),
  kmeans_assignments = file.path("dataset", "processed", "kmeans_assignments.csv"),
  kmeans_words_per_cluster = file.path("dataset", "processed", "kmeans_words_per_cluster.csv"),

  figures_directory = file.path("assets", "figures"),
  udpipe_model_pl = file.path("assets", "polish-pdb-ud-2.5-191206.udpipe"),

  workspace_directory = Sys.getenv(
    "WSE_WORKSPACE",
    unset = file.path(Sys.getenv("HOME"), "wse_workspace", "wse-sentiment")
  ),

  sentiment_ticker_min_relevance = 5,
  sentiment_negation_window = 3,
  sentiment_lda_k = 5,
  sentiment_kmeans_k = 6,
  sentiment_timeline_granularity = "week",
  sentiment_negators_pl = c("nie", "bez", "brak", "żaden", "żadna", "żadne", "nigdy", "ani", "ni"),

  user_agents = c(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:149.0) Gecko/20100101 Firefox/149.0",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
    "Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0"
  ),
  referers = c(
    "https://www.google.com/",
    "https://www.bing.com/",
    "https://www.bankier.pl/",
    "https://www.bankier.pl/rynek",
    "https://www.bankier.pl/wiadomosci"
  )
)

constants$workspace_raw <- file.path(constants$workspace_directory, "raw")
constants$workspace_cache <- file.path(constants$workspace_directory, "cache")
constants$workspace_review <- file.path(constants$workspace_directory, "review")
