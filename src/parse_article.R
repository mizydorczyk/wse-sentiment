#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(rvest)
  library(dplyr)
  library(purrr)
  library(stringr)
  library(xml2)
})

parse_article <- function(article) {
  xml2::xml_remove(xml_find_all(article, "//style | //script"))

  label <- article |>
    html_element("span.a-heading__label") |>
    html_text2() |>
    str_squish()

  title <- article |>
    html_element("h1.a-heading") |>
    xml_find_all("./text()") |>
    xml_text(trim = TRUE) |>
    paste(collapse = " ") |>
    str_squish()

  if (is.na(title) || nchar(title) == 0) title <- NA_character_

  author <- article |>
    html_element("a[href*='/autor/']") |>
    html_text2() |>
    str_squish()

  publication_date <- article |>
    html_elements("span.a-span, .m-article-attributes__item span") |>
    html_text2() |>
    str_squish() |>
    keep(~ str_detect(.x, "\\d{4}-\\d{2}-\\d{2}")) |>
    first()

  if (is.null(publication_date)) publication_date <- NA_character_

  lead <- article |>
    html_element("section.o-article-content .lead") |>
    html_text2() |>
    str_squish()

  paragraphs <- article |>
    html_elements("section.o-article-content > p") |>
    # Skip the paragraph that contains the lead
    discard(~ !is.na(html_element(.x, ".lead"))) |>
    html_text2() |>
    str_squish() |>
    keep(~ nchar(.x) > 20)

  if (length(paragraphs) == 0) {
    emitent <- html_element(article, "section.o-article-content #emitent")
    if (!is.na(emitent)) {
      xml_remove(html_elements(emitent, "style"))

      xml_add_sibling(xml_find_all(emitent, ".//br"), "text", "\n")
      xml_add_sibling(xml_find_all(emitent, ".//p"), "text", "\n")

      espi_content <- html_text(emitent) |>
        str_split("\n") |>
        unlist() |>
        str_squish() |>
        keep(~ nchar(.x) > 0)

      if (length(espi_content) > 0) {
        paragraphs <- espi_content
      }
    }
  }

  headings <- article |>
    html_elements("section.o-article-content > h2") |>
    html_text2() |>
    str_squish() |>
    keep(~ nchar(.x) > 0)

  links_nodes <- article |>
    html_elements("section.o-article-content > p a[href]")

  if (length(links_nodes) > 0) {
    links <- data.frame(
      link_text = html_text2(links_nodes),
      link_url = html_attr(links_nodes, "href"),
      stringsAsFactors = FALSE
    ) |>
      filter(nchar(.data$link_text) > 0) |>
      distinct()
  } else {
    links <- data.frame(link_text = character(), link_url = character(), stringsAsFactors = FALSE)
  }

  image_captions <- article |>
    html_elements("figcaption span.o-graphics-multiobject__caption-wrapper") |>
    html_text2() |>
    str_squish() |>
    keep(~ nchar(.x) > 0)

  image_alts <- article |>
    html_elements("section.o-article-content img") |>
    html_attr("alt") |>
    discard(is.na) |>
    str_squish() |>
    keep(~ nchar(.x) > 0)

  components <- c(lead, paragraphs, headings)
  components <- components[!is.na(components) & nchar(components) > 0]

  list(
    title = title,
    label = label,
    author = author,
    publication_date = publication_date,
    lead = lead,
    paragraphs = paragraphs,
    headings = headings,
    links = links,
    image_captions = image_captions,
    image_alts = image_alts
  )
}
