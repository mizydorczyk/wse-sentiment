constants <- list(
  raw_directory = file.path("dataset", "raw"),
  rss_feeds_path = file.path("dataset", "raw", "rss.csv"),
  archive_feeds_path = file.path("dataset", "raw", "archive.csv"),
  combined_feeds_path = file.path("dataset", "raw", "feeds.csv"),
  articles_directory = file.path("dataset", "raw", "articles"),
  articles_manifest_path = file.path("dataset", "raw", "articles_manifest.json"),
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
