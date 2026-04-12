#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(xml2)
  library(readr)
  library(dplyr)
  library(lubridate)
})

source("src/common/constants.R")

feeds <- tibble::tibble(
  source_feed = c("finanse", "firma", "gielda", "waluty", "espi"),
  source_url = c(
    "https://www.bankier.pl/rss/finanse.xml",
    "https://www.bankier.pl/rss/firma.xml",
    "https://www.bankier.pl/rss/gielda.xml",
    "https://www.bankier.pl/rss/waluty.xml",
    "https://www.bankier.pl/rss/espi.xml"
  )
)

output_directory <- constants$raw_directory
output_path <- constants$rss_feed_path

parse_html <- function(x) {
  x <- trimws(as.character(x))
  if (identical(x, "") || is.na(x)) {
    return("")
  }

  txt <- tryCatch(
    {
      fragment <- xml2::read_html(
        paste0("<div>", x, "</div>"),
        options = c("RECOVER", "NOERROR", "NOWARNING")
      )
      xml2::xml_text(xml2::xml_find_first(fragment, ".//body/div"), trim = TRUE)
    },
    error = function(e) {
      x
    }
  )

  gsub("[[:space:]]+", " ", trimws(txt))
}

text_or_na <- function(item, xpath) {
  result <- trimws(xml2::xml_text(xml2::xml_find_first(item, xpath)))
  if (identical(result, "") || is.na(result)) NA_character_ else result
}

parse_publication_date <- function(date_string) {
  date_string <- trimws(as.character(date_string))
  if (identical(date_string, "") || is.na(date_string)) {
    return(as.POSIXct(NA, tz = "UTC"))
  }

  dt <- tryCatch(
    lubridate::parse_date_time(
      date_string,
      orders = "a, d b Y H:M:S z",
      tz = "UTC",
      locale = "C"
    ),
    error = function(e) {
      message("Failed to parse date: ", date_string)
      NA
    }
  )

  if (length(dt) == 0 || is.na(dt)) {
    return(as.POSIXct(NA, tz = "UTC"))
  }

  as.POSIXct(dt, tz = "UTC")
}

load_existing_archive <- function(file_path) {
  if (!file.exists(file_path)) {
    return(
      tibble::tibble(
        id = integer(),
        title = character(),
        link = character(),
        description = character(),
        publication_date = as.POSIXct(character(), tz = "UTC"),
        collected_at_utc = as.POSIXct(character(), tz = "UTC"),
        source_feed = character(),
        source_url = character()
      )
    )
  }

  archive <- readr::read_csv(
    file_path,
    show_col_types = FALSE,
    progress = FALSE
  )

  archive |>
    mutate(
      id = as.integer(.data$id),
      title = as.character(.data$title),
      link = as.character(.data$link),
      description = as.character(.data$description),
      publication_date = lubridate::ymd_hms(.data$publication_date, tz = "UTC"),
      collected_at_utc = lubridate::ymd_hms(.data$collected_at_utc, tz = "UTC"),
      source_feed = as.character(.data$source_feed),
      source_url = as.character(.data$source_url)
    )
}

fetch_rss_feed <- function(source_feed, source_url, collected_at) {
  document <- tryCatch(
    xml2::read_xml(source_url),
    error = function(e) {
      message("Failed to fetch feed '", source_feed, "'")
      message("Url: ", source_url)
      message("Details: ", conditionMessage(e))
      NULL
    }
  )

  if (is.null(document)) {
    return(tibble::tibble())
  }

  items <- xml2::xml_find_all(document, ".//item")

  if (length(items) == 0) {
    message("Feed '", source_feed, "' contains 0 items")
    return(tibble::tibble())
  }

  lapply(items, function(item) {
    title <- text_or_na(item, "./title")
    link <- text_or_na(item, "./link")
    description <- text_or_na(item, "./description")
    date <- text_or_na(item, "./pubDate")

    tibble::tibble(
      title = parse_html(title),
      link = link,
      description = parse_html(description),
      publication_date = parse_publication_date(date),
      collected_at_utc = collected_at,
      source_feed = source_feed,
      source_url = source_url
    )
  }) |>
    bind_rows() |>
    filter(!is.na(.data$link)) |>
    distinct(.data$link, .keep_all = TRUE)
}

dir.create(output_directory, recursive = TRUE, showWarnings = FALSE)
collection_time <- as.POSIXct(Sys.time(), tz = "UTC")

new_items <- lapply(seq_len(nrow(feeds)), function(i) {
  fetch_rss_feed(
    source_feed = feeds$source_feed[i],
    source_url = feeds$source_url[i],
    collected_at = collection_time
  )
}) |>
  bind_rows()

if (nrow(new_items) == 0) {
  message("No items collected from any feed. Exiting without writing archive.")
  quit(status = 0)
}

existing_items <- load_existing_archive(output_path)

archive <- bind_rows(
  existing_items |> select(-"id"),
  new_items
) |>
  distinct(.data$link, .keep_all = TRUE) |>
  arrange(.data$publication_date, .data$link) |>
  mutate(id = row_number()) |>
  select("id", "title", "link", "description", "publication_date", "collected_at_utc", "source_feed", "source_url")

feed_fetched <- new_items |>
  count(.data$source_feed, name = "fetched") |>
  arrange(.data$source_feed)

feed_new_added <- new_items |>
  anti_join(existing_items, by = "link") |>
  count(.data$source_feed, name = "added") |>
  arrange(.data$source_feed)

feed_details <- feed_fetched |>
  full_join(feed_new_added, by = "source_feed") |>
  mutate(
    fetched = coalesce(.data$fetched, 0L),
    added = coalesce(.data$added, 0L)
  )

readr::write_csv(
  archive |>
    mutate(
      publication_date = if_else(
        is.na(.data$publication_date),
        NA_character_,
        format(.data$publication_date, "%Y-%m-%dT%H:%M:%SZ")
      ),
      collected_at_utc = format(.data$collected_at_utc, "%Y-%m-%dT%H:%M:%SZ")
    ),
  output_path
)

message("Output file: ", output_path)
message("Fetched by feed:")
for (i in seq_len(nrow(feed_details))) {
  message(
    "> ",
    feed_details$source_feed[i], ": ", feed_details$fetched[i], " fetched (new: ", feed_details$added[i], ")"
  )
}
