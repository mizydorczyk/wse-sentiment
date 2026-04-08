#!/usr/bin/env Rscript

library(xml2)

url <- "https://www.bankier.pl/rss/gielda.xml"
now_utc <- as.POSIXct(Sys.time(), tz = "UTC")

directory <- file.path("dataset", "raw")
dir.create(directory, recursive = TRUE, showWarnings = FALSE)

path <- file.path(
  directory,
  sprintf("bankier_gielda_rss_%s.txt", format(now_utc, "%Y%m%d_%H%M%S"))
)

document <- read_xml(url)
items <- xml_find_all(document, ".//item")

item_lines <- unlist(lapply(seq_along(items), function(i) {
  title_node <- xml_find_first(items[[i]], "./title")
  link_node <- xml_find_first(items[[i]], "./link")

  title <- if (length(title_node) == 0 || is.na(title_node)) {
    ""
  } else {
    trimws(xml_text(title_node))
  }

  link <- if (length(link_node) == 0 || is.na(link_node)) {
    ""
  } else {
    trimws(xml_text(link_node))
  }

  c(
    sprintf("%d. %s", i, title),
    sprintf("   %s", link),
    ""
  )
}), use.names = FALSE)

lines <- c(
  sprintf("source: %s", url),
  sprintf("collected_at_utc: %s", format(now_utc, "%Y-%m-%dT%H:%M:%SZ")),
  sprintf("items: %d", length(items)),
  "",
  item_lines
)

writeLines(enc2utf8(lines), path, useBytes = TRUE)
message(sprintf("Saved %d items to: %s", length(items), path))
