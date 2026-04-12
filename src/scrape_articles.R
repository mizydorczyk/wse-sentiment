#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(purrr)
  library(rvest)
  library(stringr)
  library(jsonlite)
})

parse_article <- NULL
source("src/parse_article.R")
source("src/common/constants.R")

input_file <- constants$rss_feed_path
articles_dir <- constants$articles_directory
manifest_file <- constants$articles_manifest_path

user_agents <- constants$user_agents
referers <- constants$referers

if (!dir.exists(articles_dir)) {
  dir.create(articles_dir, recursive = TRUE)
  cat("Created directory:", articles_dir, "\n")
}

if (!file.exists(input_file)) {
  stop("Input file not found: ", input_file)
}

cat("Loading feed data from", input_file, "...\n")
feed_df <- read_csv(input_file, show_col_types = FALSE)

if (!"link" %in% colnames(feed_df)) {
  stop("The feed dataset must contain a 'link' column.")
}

if (!"id" %in% colnames(feed_df)) {
  feed_df <- feed_df |>
    mutate(id = row_number())
}

add_random_delay <- function(min_seconds, max_seconds) {
  delay_seconds <- runif(1, min = min_seconds, max = max_seconds)
  Sys.sleep(delay_seconds)
}

get_random_user_agent <- function() {
  sample(user_agents, 1)
}

get_random_referer <- function() {
  sample(referers, 1)
}

scrape_and_parse_article <- function(article_url, feed_row) {
  cat("Scraping:", article_url, "\n")

  tryCatch(
    {
      add_random_delay(min_seconds = 1, max_seconds = 10)
      user_agent <- get_random_user_agent()
      referer <- get_random_referer()

      page <- read_html(
        article_url,
        config = httr::add_headers(
          "User-Agent" = user_agent,
          "Accept" = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
          "Accept-Language" = "en-US,en;q=0.5",
          "Accept-Encoding" = "gzip, deflate",
          "DNT" = "1",
          "Connection" = "keep-alive",
          "Upgrade-Insecure-Requests" = "1",
          "Referer" = referer,
          "Cache-Control" = "max-age=0",
          "Sec-Fetch-Dest" = "document",
          "Sec-Fetch-Mode" = "navigate",
          "Sec-Fetch-Site" = "none"
        )
      )

      parsed_article <- parse_article(page)

      links_list <- if (nrow(parsed_article$links) > 0) {
        lapply(seq_len(nrow(parsed_article$links)), function(i) {
          list(text = parsed_article$links$link_text[i], url = parsed_article$links$link_url[i])
        })
      } else {
        list()
      }

      article_data <- list(
        metadata = list(
          url = article_url,
          title = ifelse(is.na(parsed_article$title), "", parsed_article$title),
          article_label = ifelse(is.na(parsed_article$label), "", parsed_article$label),
          author = ifelse(is.na(parsed_article$author), "", parsed_article$author),
          publication_date = ifelse(is.na(parsed_article$pub_date), "", parsed_article$pub_date),
          scraped_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ"),
          feed_source = ifelse(is.null(feed_row$source_feed), "", feed_row$source_feed),
          feed_url = ifelse(is.null(feed_row$source_url), "", feed_row$source_url)
        ),
        content = list(
          lead = ifelse(is.na(parsed_article$lead), "", parsed_article$lead),
          paragraphs = if (length(parsed_article$paragraphs) > 0) {
            as.list(parsed_article$paragraphs)
          } else {
            list()
          },
          headings = if (length(parsed_article$headings) > 0) {
            as.list(parsed_article$headings)
          } else {
            list()
          },
          links = links_list,
          images = list(
            captions = if (length(parsed_article$image_captions) > 0) {
              as.list(parsed_article$image_captions)
            } else {
              list()
            },
            alts = if (length(parsed_article$image_alts) > 0) {
              as.list(parsed_article$image_alts)
            } else {
              list()
            }
          )
        )
      )

      cat("  Successfully parsed article\n")
      article_data
    },
    error = function(e) {
      cat("  Error:", e$message, "\n")
      list(
        error = e$message,
        url = article_url,
        scraped_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
      )
    },
    finally = {
      add_random_delay(min_seconds = 0.5, max_seconds = 1.5)
    }
  )
}

cat("Starting to scrape", nrow(feed_df), "article(s)...\n")
cat("Using rotating User-Agents and Referers to avoid detection\n")
cat("Output format: Individual JSON files\n")
cat("Output directory:", articles_dir, "\n\n")

manifest <- list()
if (file.exists(manifest_file)) {
  cat("Loading existing manifest to resume progress...\n")
  existing_manifest <- fromJSON(manifest_file, simplifyVector = FALSE)
  for (entry in existing_manifest) {
    manifest[[as.character(entry$id)]] <- entry
  }
}

for (i in seq_len(nrow(feed_df))) {
  cat("\n[", i, "/", nrow(feed_df), "]\n", sep = "")

  article_id <- as.character(feed_df$id[i])
  article_url <- feed_df$link[i]
  output_file <- file.path(articles_dir, paste0(article_id, ".json"))

  if (!is.null(manifest[[article_id]]) && isTRUE(manifest[[article_id]]$success) && file.exists(output_file)) {
    cat("  Skipping already processed article:", article_id, "\n")
    next
  }

  scrape_result <- scrape_and_parse_article(
    article_url,
    feed_df[i, ]
  )

  json_output <- toJSON(scrape_result, pretty = TRUE, auto_unbox = TRUE)
  writeLines(json_output, output_file)
  cat("  Saved to:", output_file, "\n")

  manifest_entry <- list(
    id = article_id,
    file = file.path(basename(articles_dir), basename(output_file)),
    url = article_url,
    success = is.null(scrape_result$error),
    scraped_at = scrape_result$metadata$scraped_at %||% scrape_result$scraped_at
  )

  if (manifest_entry$success) {
    manifest_entry$title <- scrape_result$metadata$title
    manifest_entry$author <- scrape_result$metadata$author
  } else {
    manifest_entry$error <- scrape_result$error
  }

  manifest[[article_id]] <- manifest_entry

  manifest_json <- toJSON(unname(manifest), pretty = TRUE, auto_unbox = TRUE)
  writeLines(manifest_json, manifest_file)
}

cat("\nFinished scraping process!\n")
cat("Manifest fully updated at:", manifest_file, "\n")
