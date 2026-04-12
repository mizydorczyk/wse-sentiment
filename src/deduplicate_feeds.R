#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(lubridate)
  library(readr)
  library(stringr)
  library(tibble)
})

source("src/common/constants.R")

rss_path <- constants$rss_feeds_path
archive_path <- constants$archive_feeds_path
output_path <- constants$combined_feeds_path

normalize_link <- function(link) {
  link <- trimws(as.character(link))
  if (length(link) == 0 || is.na(link) || identical(link, "")) {
    return(NA_character_)
  }

  link <- sub("^http://", "https://", link)
  link <- sub("\\?.*$", "", link)
  link <- sub("#.*$", "", link)
  link <- trimws(link)

  if (identical(link, "")) {
    NA_character_
  } else {
    link
  }
}

pick_value <- function(rss_value, archive_value) {
  rss_value <- rss_value[!is.na(rss_value) & nzchar(trimws(as.character(rss_value)))]
  if (length(rss_value) > 0) {
    return(rss_value[[1]])
  }

  archive_value <- archive_value[!is.na(archive_value) & nzchar(trimws(as.character(archive_value)))]
  if (length(archive_value) > 0) {
    return(archive_value[[1]])
  }

  NA_character_
}

pick_date <- function(rss_value, archive_value) {
  rss_value <- rss_value[!is.na(rss_value)]
  if (length(rss_value) > 0) {
    return(rss_value[[1]])
  }

  archive_value <- archive_value[!is.na(archive_value)]
  if (length(archive_value) > 0) {
    return(archive_value[[1]])
  }

  as.POSIXct(NA, tz = "UTC")
}

standardize_feed <- function(data, source_name) {
  if (nrow(data) == 0) {
    return(tibble(
      title = character(),
      link = character(),
      publication_date = as.POSIXct(character(), tz = "UTC"),
      collected_at_utc = as.POSIXct(character(), tz = "UTC"),
      from_rss = logical(),
      from_archive = logical()
    ))
  }

  data |>
    dplyr::mutate(
      title = if ("title" %in% names(data)) as.character(.data$title) else NA_character_,
      link = if ("link" %in% names(data)) as.character(.data$link) else NA_character_,
      publication_date = if ("publication_date" %in% names(data)) {
        as.POSIXct(.data$publication_date, tz = "UTC")
      } else {
        as.POSIXct(rep(NA_character_, nrow(data)), tz = "UTC")
      },
      collected_at_utc = if ("collected_at_utc" %in% names(data)) {
        as.POSIXct(.data$collected_at_utc, tz = "UTC")
      } else {
        as.POSIXct(rep(NA_character_, nrow(data)), tz = "UTC")
      },
      link = vapply(.data$link, normalize_link, character(1)),
      from_rss = source_name == "rss",
      from_archive = source_name == "archive"
    ) |>
    dplyr::select(
      .data$title,
      .data$link,
      .data$publication_date,
      .data$collected_at_utc,
      .data$from_rss,
      .data$from_archive
    )
}

read_feed_file <- function(path) {
  if (!file.exists(path)) {
    return(tibble())
  }

  readr::read_csv(
    path,
    show_col_types = FALSE,
    progress = FALSE
  )
}

rss <- standardize_feed(read_feed_file(rss_path), "rss")
archive <- standardize_feed(read_feed_file(archive_path), "archive")

rss_rows <- nrow(rss)
archive_rows <- nrow(archive)

combined <- bind_rows(rss, archive)

if (nrow(combined) == 0) {
  dir.create(constants$raw_directory, recursive = TRUE, showWarnings = FALSE)
  write_csv(
    tibble(
      id = integer(),
      title = character(),
      link = character(),
      publication_date = character(),
      collected_at_utc = character(),
      from_rss = integer(),
      from_archive = integer()
    ),
    output_path
  )

  message("Rows read from RSS: ", rss_rows)
  message("Rows read from archive: ", archive_rows)
  message("Rows after merge: 0")
  message("Rows after deduplication: 0")
  message("Duplicates removed: 0")
  message("Output file: ", output_path)
  quit(status = 0)
}

deduped <- combined |>
  filter(!is.na(.data$link)) |>
  group_by(.data$link) |>
  summarise(
    title = pick_value(.data$title[.data$from_rss], .data$title[.data$from_archive]),
    publication_date = pick_date(.data$publication_date[.data$from_rss], .data$publication_date[.data$from_archive]),
    collected_at_utc = pick_date(.data$collected_at_utc[.data$from_rss], .data$collected_at_utc[.data$from_archive]),
    from_rss = as.integer(any(.data$from_rss, na.rm = TRUE)),
    from_archive = as.integer(any(.data$from_archive, na.rm = TRUE)),
    .groups = "drop"
  ) |>
  arrange(.data$publication_date, .data$link) |>
  mutate(id = row_number()) |>
  select(
    id,
    title,
    link,
    publication_date,
    collected_at_utc,
    from_rss,
    from_archive
  )

dir.create(constants$raw_directory, recursive = TRUE, showWarnings = FALSE)

readr::write_csv(
  deduped |>
    mutate(
      publication_date = if_else(
        is.na(.data$publication_date),
        NA_character_,
        format(.data$publication_date, "%Y-%m-%dT%H:%M:%SZ")
      ),
      collected_at_utc = if_else(
        is.na(.data$collected_at_utc),
        NA_character_,
        format(.data$collected_at_utc, "%Y-%m-%dT%H:%M:%SZ")
      )
    ),
  output_path
)

message("Rows read from RSS: ", rss_rows)
message("Rows read from archive: ", archive_rows)
message("Rows after merge: ", nrow(combined))
message("Rows after deduplication: ", nrow(deduped))
message("Duplicates removed: ", nrow(combined) - nrow(deduped))
message("Output file: ", output_path)
