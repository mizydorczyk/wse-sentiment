#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
start_page_arg <- if (length(args) >= 1) {
  suppressWarnings(as.integer(args[1]))
} else {
  NA_integer_
}
end_page_arg <- if (length(args) >= 2) {
  suppressWarnings(as.integer(args[2]))
} else {
  NA_integer_
}

start_page <- if (is.na(start_page_arg) || start_page_arg < 1L) 1L else start_page_arg
end_page <- if (is.na(end_page_arg) || end_page_arg < start_page) start_page else end_page_arg

suppressPackageStartupMessages({
  library(xml2)
  library(rvest)
  library(readr)
  library(dplyr)
  library(lubridate)
  library(stringr)
  library(purrr)
  library(httr)
})

archive_sections <- tibble::tibble(
  archive_section = c(
    "gielda_wiadomosci",
    "gielda_wywiady_ze_spolek",
    "rynki_wiadomosci",
    "gospodarka_wiadomosci",
    "surowce_wiadomosci"
  ),
  section_base_url = c(
    "https://www.bankier.pl/gielda/wiadomosci",
    "https://www.bankier.pl/gielda/wiadomosci/wywiady-ze-spolek",
    "https://www.bankier.pl/rynki/wiadomosci",
    "https://www.bankier.pl/gospodarka/wiadomosci",
    "https://www.bankier.pl/surowce/wiadomosci"
  )
)

source("src/common/constants.R")

output_directory <- constants$raw_directory
output_path <- constants$archive_feed_path

user_agents <- constants$user_agents
referers <- constants$referers

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

parse_publication_date <- function(date_string) {
  date_string <- trimws(as.character(date_string))
  if (identical(date_string, "") || is.na(date_string)) {
    return(as.POSIXct(NA, tz = "UTC"))
  }

  normalized <- stringr::str_to_lower(date_string)
  normalized <- gsub("\\s+", " ", normalized)
  normalized <- trimws(normalized)

  now_utc <- as.POSIXct(Sys.time(), tz = "UTC")

  extract_hm <- function(x) {
    m <- stringr::str_match(x, "(\\d{1,2}):(\\d{2})")
    if (is.na(m[1, 1])) {
      return(c(0L, 0L))
    }
    h <- as.integer(m[1, 2])
    mi <- as.integer(m[1, 3])
    if (is.na(h)) h <- 0L
    if (is.na(mi)) mi <- 0L
    c(h, mi)
  }

  if (stringr::str_detect(normalized, "\\bdzis(iaj|́)?\\b|\\bdziś\\b")) {
    hm <- extract_hm(normalized)
    base <- as.POSIXct(format(now_utc, "%Y-%m-%d 00:00:00"), tz = "UTC")
    return(base + hm[1] * 3600 + hm[2] * 60)
  }

  if (stringr::str_detect(normalized, "\\bwczoraj\\b")) {
    hm <- extract_hm(normalized)
    base <- as.POSIXct(format(now_utc - 86400, "%Y-%m-%d 00:00:00"), tz = "UTC")
    return(base + hm[1] * 3600 + hm[2] * 60)
  }

  dt <- tryCatch(
    suppressWarnings(
      lubridate::parse_date_time(
        normalized,
        orders = c(
          "Y-m-d H:M:S",
          "Y-m-d H:M",
          "d.m.Y H:M:S",
          "d.m.Y H:M",
          "d.m H:M:S",
          "d.m H:M",
          "d b Y H:M:S",
          "d b Y H:M",
          "a, d b Y H:M:S z",
          "a, d b Y H:M z",
          "Y-m-d\\TH:M:S",
          "Y-m-d\\TH:M:S z",
          "Y-m-d\\TH:M:S%z"
        ),
        tz = "UTC",
        locale = "C"
      )
    ),
    error = function(e) {
      NA
    }
  )

  if (length(dt) == 0 || all(is.na(dt))) {
    return(as.POSIXct(NA, tz = "UTC"))
  }

  out <- as.POSIXct(dt[[1]], tz = "UTC")

  if (stringr::str_detect(normalized, "^\\d{1,2}\\.\\d{1,2}(\\s+\\d{1,2}:\\d{2}(:\\d{2})?)?$")) {
    year_now <- format(now_utc, "%Y")
    enriched <- paste0(normalized, ".", year_now)
    dt2 <- tryCatch(
      suppressWarnings(
        lubridate::parse_date_time(
          enriched,
          orders = c("d.m.Y H:M:S", "d.m.Y H:M", "d.m.Y"),
          tz = "UTC",
          locale = "C"
        )
      ),
      error = function(e) {
        NA
      }
    )
    if (!(length(dt2) == 0 || all(is.na(dt2)))) {
      out <- as.POSIXct(dt2[[1]], tz = "UTC")
    }
  }

  out
}

safe_html_text <- function(node) {
  if (length(node) == 0 || is.na(node)) {
    return(NA_character_)
  }

  val <- trimws(xml2::xml_text(node))
  if (identical(val, "")) {
    return(NA_character_)
  }

  val
}

normalize_bankier_link <- function(href) {
  href <- trimws(as.character(href))
  if (is.na(href) || identical(href, "")) {
    return(NA_character_)
  }

  full <- tryCatch(
    xml2::url_absolute(href, "https://www.bankier.pl"),
    error = function(e) NA_character_
  )

  if (is.na(full)) {
    return(NA_character_)
  }

  full <- sub("^http://", "https://", full)

  if (!grepl("^https://www\\.bankier\\.pl/wiadomosc/", full)) {
    return(NA_character_)
  }

  full
}

extract_from_listing_anchor <- function(anchor, archive_section, archive_page, archive_url, collected_at_utc) {
  href <- rvest::html_attr(anchor, "href")
  link <- normalize_bankier_link(href)

  if (is.na(link)) {
    return(NULL)
  }

  title <- safe_html_text(rvest::html_element(anchor, ".m-listing-article-list__title"))
  if (is.na(title)) {
    title <- safe_html_text(rvest::html_element(anchor, "h3"))
  }
  if (is.na(title)) {
    title <- safe_html_text(anchor)
  }

  description <- safe_html_text(rvest::html_element(anchor, ".m-listing-article-list__lead"))
  if (is.na(description)) {
    description <- safe_html_text(rvest::html_element(anchor, "p"))
  }

  time_node <- rvest::html_element(anchor, ".m-listing-article-list__time")
  if (length(time_node) == 0) {
    time_node <- rvest::html_element(anchor, "time")
  }

  publication_text <- safe_html_text(time_node)
  publication_attr <- rvest::html_attr(time_node, "datetime")
  publication_raw <- ifelse(is.na(publication_attr), publication_text, publication_attr)
  publication_date <- parse_publication_date(publication_raw)

  if (is.na(description)) {
    all_divs <- rvest::html_elements(anchor, "div")
    div_texts <- trimws(rvest::html_text(all_divs))
    div_texts <- div_texts[nzchar(div_texts)]

    if (length(div_texts) > 0) {
      candidates <- unique(div_texts)

      if (!is.na(title) && nzchar(title)) {
        candidates <- candidates[candidates != trimws(title)]
      }

      if (!is.na(publication_text) && nzchar(publication_text)) {
        candidates <- candidates[candidates != trimws(publication_text)]
      }

      if (!is.na(publication_raw) && nzchar(publication_raw)) {
        candidates <- candidates[candidates != trimws(publication_raw)]
      }

      if (length(candidates) > 0) {
        description <- candidates[length(candidates)]
      }
    }
  }

  tibble::tibble(
    title = parse_html(title),
    link = link,
    description = parse_html(description),
    publication_date = publication_date,
    collected_at_utc = collected_at_utc,
    archive_section = archive_section,
    archive_page = as.integer(archive_page),
    archive_url = archive_url
  )
}

fetch_archive_page <- function(archive_section, section_base_url, page_number, collected_at_utc) {
  archive_url <- paste0(section_base_url, "/", page_number)

  user_agent <- get_random_user_agent()
  referer <- get_random_referer()

  message("Fetching page ", page_number, ": ", archive_url)

  document <- tryCatch(
    xml2::read_html(
      archive_url,
      options = c("RECOVER", "NOERROR", "NOWARNING"),
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
    ),
    error = function(e) {
      message("Fetching page ", page_number, " failed")
      message("Section: ", archive_section)
      message("Url: ", archive_url)
      message("Details: ", conditionMessage(e))
      NULL
    }
  )

  if (!is.null(document)) {
    message("Fetching page ", page_number, " succeeded")
  }

  if (is.null(document)) {
    return(list(status = "error", data = tibble::tibble(), url = archive_url))
  }

  listing <- rvest::html_element(document, "section#listing-article-list-box")
  if (length(listing) == 0) {
    message("Section listing not found for: ", archive_url)
    return(list(status = "empty", data = tibble::tibble(), url = archive_url))
  }

  anchors <- rvest::html_elements(listing, "a.m-listing-article-list__anchor")
  if (length(anchors) == 0) {
    message("No article anchors found on: ", archive_url)
    return(list(status = "empty", data = tibble::tibble(), url = archive_url))
  }

  page_data <- lapply(anchors, function(anchor) {
    extract_from_listing_anchor(
      anchor = anchor,
      archive_section = archive_section,
      archive_page = page_number,
      archive_url = archive_url,
      collected_at_utc = collected_at_utc
    )
  }) |>
    bind_rows() |>
    distinct(.data$link, .keep_all = TRUE)

  if (nrow(page_data) == 0) {
    return(list(status = "empty", data = tibble::tibble(), url = archive_url))
  }

  list(status = "ok", data = page_data, url = archive_url)
}

collect_archive_section <- function(archive_section, section_base_url, collected_at_utc, start_page, end_page) {
  results <- list()
  seen_links <- character(0)

  for (page_number in seq(from = start_page, to = end_page)) {
    add_random_delay(min_seconds = 1, max_seconds = 5)

    fetched <- fetch_archive_page(
      archive_section = archive_section,
      section_base_url = section_base_url,
      page_number = page_number,
      collected_at_utc = collected_at_utc
    )

    if (identical(fetched$status, "error") || identical(fetched$status, "empty")) {
      break
    }

    page_data <- fetched$data
    page_links <- unique(page_data$link)

    results[[length(results) + 1]] <- page_data

    seen_links <- unique(c(seen_links, page_links))
  }

  if (length(results) == 0) {
    return(tibble::tibble())
  }

  bind_rows(results)
}

dir.create(output_directory, recursive = TRUE, showWarnings = FALSE)
collection_time <- as.POSIXct(Sys.time(), tz = "UTC")

new_items <- lapply(seq_len(nrow(archive_sections)), function(i) {
  collect_archive_section(
    archive_section = archive_sections$archive_section[i],
    section_base_url = archive_sections$section_base_url[i],
    collected_at_utc = collection_time,
    start_page = start_page,
    end_page = end_page
  )
}) |>
  bind_rows()

if (nrow(new_items) == 0) {
  message("No archive items collected from any section. Exiting without writing file.")
  quit(status = 0)
}

existing_items <- if (file.exists(output_path)) {
  readr::read_csv(output_path, show_col_types = FALSE, progress = FALSE) |>
    mutate(
      id = as.integer(.data$id),
      title = as.character(.data$title),
      link = as.character(.data$link),
      description = as.character(.data$description),
      publication_date = as.POSIXct(.data$publication_date, tz = "UTC"),
      collected_at_utc = as.POSIXct(.data$collected_at_utc, tz = "UTC"),
      archive_section = as.character(.data$archive_section),
      archive_page = as.integer(.data$archive_page),
      archive_url = as.character(.data$archive_url)
    )
} else {
  tibble::tibble(
    id = integer(),
    title = character(),
    link = character(),
    description = character(),
    publication_date = as.POSIXct(character(), tz = "UTC"),
    collected_at_utc = as.POSIXct(character(), tz = "UTC"),
    archive_section = character(),
    archive_page = integer(),
    archive_url = character()
  )
}

fetched_counts <- new_items |>
  count(.data$archive_section, name = "fetched")

archive <- bind_rows(
  existing_items |> select(-"id"),
  new_items
) |>
  distinct(.data$link, .keep_all = TRUE) |>
  arrange(.data$publication_date, .data$link) |>
  mutate(id = row_number()) |>
  select(
    "id",
    "title",
    "link",
    "description",
    "publication_date",
    "collected_at_utc",
    "archive_section",
    "archive_page",
    "archive_url"
  )

appended_items <- anti_join(
  archive |> select(-"id"),
  existing_items |> select(-"id"),
  by = "link"
)

new_counts <- appended_items |>
  count(.data$archive_section, name = "new")

section_counts <- full_join(fetched_counts, new_counts, by = "archive_section") |>
  mutate(
    fetched = coalesce(.data$fetched, 0L),
    new = coalesce(.data$new, 0L)
  ) |>
  arrange(.data$archive_section)

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
message("Collected by section:")
for (i in seq_len(nrow(section_counts))) {
  message(
    "> ", section_counts$archive_section[i], ": ", section_counts$fetched[i], " (new: ", section_counts$new[i], ")"
  )
}
