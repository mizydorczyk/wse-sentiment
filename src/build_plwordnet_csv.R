#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
  library(readr)
  library(stringr)
})

source("src/common/constants.R")

plwn_zip_path <- file.path(constants$workspace_raw, "wordnet_work_4_5.zip")
plwn_inner_sql <- "wordnet_work_4_5.sql"
plwn_filtered_txt <- file.path(constants$workspace_raw, "plwn_filtered.txt")
plwn_drops_csv <- file.path(constants$workspace_review, "plwn_parse_drops.csv")
plwn_out_csv <- constants$sentiment_lexicon_general

# Verified against raw plWN 4.5 data 2026-05-29:
#   1=VERB (kupować, biegać), 2=NOUN (kotek, zysk, aborcja), 3=ADV (szybko), 4=ADJ (biały)
# Previous mapping (1=NOUN, 2=VERB, 3=ADJ, 4=ADV) was wrong — caused all
# (lemma, pos) joins in sentiment.R to fail because udpipe POS would never match.
pos_int_to_upos <- c("1" = "VERB", "2" = "NOUN", "3" = "ADV", "4" = "ADJ")

markedness_to_sentiment <- function(m) {
  m_trim <- str_trim(m)
  case_when(
    m_trim == "+ s" ~ "positive",
    m_trim == "+ m" ~ "positive",
    m_trim == "- s" ~ "negative",
    m_trim == "- m" ~ "negative",
    TRUE ~ NA_character_
  )
}

markedness_strength <- function(m) {
  m_trim <- str_trim(m)
  case_when(
    m_trim %in% c("+ s", "- s") ~ 2L,
    m_trim %in% c("+ m", "- m") ~ 1L,
    TRUE ~ 0L
  )
}

extract_filtered_dump <- function(zip_path, inner_sql, out_path) {
  if (!file.exists(zip_path)) {
    stop(sprintf(
      paste0("plWordNet ZIP not found at: %s\n",
             "  Download from: https://clarin-pl.eu/dspace/handle/11321/535\n",
             "  Place the file `wordnet_work_4_5.zip` into: %s"),
      zip_path, constants$workspace_raw
    ))
  }
  if (!dir.exists(dirname(out_path))) {
    dir.create(dirname(out_path), recursive = TRUE)
  }

  awk_prog <- paste0(
    "/^INSERT INTO `lexicalunit`/ || /^INSERT INTO `emotion`/ {",
    "  gsub(/\\),\\(/, \")\\n(\");",
    "  print",
    "}"
  )

  cmd <- sprintf(
    "unzip -p %s %s | awk '%s' > %s",
    shQuote(zip_path), shQuote(inner_sql), awk_prog, shQuote(out_path)
  )

  message(sprintf("Extracting filtered dump: %s -> %s", zip_path, out_path))
  status <- system(cmd)
  if (status != 0) {
    stop(sprintf("unzip|awk pipeline failed with status %d (cmd: %s)", status, cmd))
  }
  invisible(out_path)
}

# Regexes anchored at start of tuple `(`
lex_rx <- "^\\((\\d+),'((?:[^'\\\\]|\\\\.)*)',(\\d+),(\\d+),"
emo_rx <- "^\\((\\d+),(\\d+),'((?:[^'\\\\]|\\\\.)*)','((?:[^'\\\\]|\\\\.)*)','((?:[^'\\\\]|\\\\.)*)',"

# Parse the filtered dump using a state machine with PRE-ALLOCATED vectors
# (original chunked + list-append was O(N^2) on N=709k lines — killed after 49 min
# stuck in memory copying). Single-pass linear scan, ~minutes for full plWN.
parse_filtered_dump <- function(file_path) {
  lines <- readr::read_lines(file_path, progress = FALSE)
  n <- length(lines)
  message(sprintf("Loaded %d lines (%.1f MB in RAM)", n, n * 100 / 1024 / 1024))

  # Pre-allocate. Real counts will be lower; we trim at end.
  lex_id <- integer(n)
  lex_lemma <- character(n)
  lex_domain <- integer(n)
  lex_pos <- integer(n)
  lex_count <- 0L
  lex_drop <- 0L

  emo_id <- integer(n)
  emo_lex_id <- integer(n)
  emo_emotions <- character(n)
  emo_valuations <- character(n)
  emo_markedness <- character(n)
  emo_count <- 0L
  emo_drop <- 0L

  current_table <- 0L  # 0 = none, 1 = lex, 2 = emo

  for (i in seq_len(n)) {
    ln <- lines[i]

    # Switch table on INSERT header. First tuple is appended after VALUES on same line.
    if (startsWith(ln, "INSERT INTO `lexicalunit`")) {
      current_table <- 1L
      m <- regexpr("VALUES \\(", ln, fixed = FALSE)
      if (m > 0) ln <- substring(ln, m + nchar("VALUES ")) else next
    } else if (startsWith(ln, "INSERT INTO `emotion`")) {
      current_table <- 2L
      m <- regexpr("VALUES \\(", ln, fixed = FALSE)
      if (m > 0) ln <- substring(ln, m + nchar("VALUES ")) else next
    } else if (!startsWith(ln, "(")) {
      next
    }

    if (current_table == 1L) {
      parts <- regmatches(ln, regexec(lex_rx, ln, perl = TRUE))[[1]]
      if (length(parts) < 5L) {
        lex_drop <- lex_drop + 1L
        next
      }
      lex_count <- lex_count + 1L
      lex_id[lex_count] <- suppressWarnings(as.integer(parts[2]))
      lex_lemma[lex_count] <- parts[3]
      lex_domain[lex_count] <- suppressWarnings(as.integer(parts[4]))
      lex_pos[lex_count] <- suppressWarnings(as.integer(parts[5]))
    } else if (current_table == 2L) {
      parts <- regmatches(ln, regexec(emo_rx, ln, perl = TRUE))[[1]]
      if (length(parts) < 6L) {
        emo_drop <- emo_drop + 1L
        next
      }
      emo_count <- emo_count + 1L
      emo_id[emo_count] <- suppressWarnings(as.integer(parts[2]))
      emo_lex_id[emo_count] <- suppressWarnings(as.integer(parts[3]))
      emo_emotions[emo_count] <- parts[4]
      emo_valuations[emo_count] <- parts[5]
      emo_markedness[emo_count] <- parts[6]
    }

    if (i %% 100000L == 0L) {
      message(sprintf("  %d/%d lines, lex=%d emo=%d", i, n, lex_count, emo_count))
    }
  }

  list(
    lex_df = tibble(
      ID = lex_id[seq_len(lex_count)],
      lemma = lex_lemma[seq_len(lex_count)],
      domain = lex_domain[seq_len(lex_count)],
      pos_int = lex_pos[seq_len(lex_count)]
    ),
    emo_df = tibble(
      id = emo_id[seq_len(emo_count)],
      lexicalunit_id = emo_lex_id[seq_len(emo_count)],
      emotions = emo_emotions[seq_len(emo_count)],
      valuations = emo_valuations[seq_len(emo_count)],
      markedness = emo_markedness[seq_len(emo_count)]
    ),
    n_lex_drop = lex_drop,
    n_emo_drop = emo_drop
  )
}

build_plwordnet_csv <- function() {
  if (!dir.exists(constants$workspace_raw)) {
    dir.create(constants$workspace_raw, recursive = TRUE)
  }
  if (!dir.exists(constants$workspace_review)) {
    dir.create(constants$workspace_review, recursive = TRUE)
  }
  if (!dir.exists(constants$dictionaries_directory)) {
    dir.create(constants$dictionaries_directory, recursive = TRUE)
  }

  # Skip re-extract if filtered.txt already exists (idempotent re-runs).
  if (!file.exists(plwn_filtered_txt) || file.info(plwn_filtered_txt)$size < 10 * 1024 * 1024) {
    extract_filtered_dump(plwn_zip_path, plwn_inner_sql, plwn_filtered_txt)
  } else {
    message(sprintf("Reusing existing filtered dump: %s (%.0f MB)",
                    plwn_filtered_txt, file.info(plwn_filtered_txt)$size / 1024 / 1024))
  }

  message("Parsing filtered dump (single-pass, pre-allocated vectors)...")
  parsed <- parse_filtered_dump(plwn_filtered_txt)
  lex_df <- parsed$lex_df
  emo_df <- parsed$emo_df

  drops_df <- tibble(table = character(), reason = character(), snippet = character())

  message(sprintf("Parsed lex rows: %d (drops: %d)", nrow(lex_df), parsed$n_lex_drop))
  message(sprintf("Parsed emo rows: %d (drops: %d)", nrow(emo_df), parsed$n_emo_drop))

  joined <- lex_df |>
    inner_join(emo_df, by = c("ID" = "lexicalunit_id"))
  message(sprintf("Joined rows (lex x emo): %d", nrow(joined)))

  enriched <- joined |>
    mutate(
      sentiment = markedness_to_sentiment(.data$markedness),
      strength = markedness_strength(.data$markedness),
      pos = pos_int_to_upos[as.character(.data$pos_int)]
    ) |>
    filter(!is.na(.data$sentiment), !is.na(.data$pos)) |>
    mutate(
      lemma = tolower(str_trim(.data$lemma))
    ) |>
    filter(.data$lemma != "", !str_detect(.data$lemma, "'"))

  message(sprintf("After sentiment/pos filter: %d", nrow(enriched)))

  deduped <- enriched |>
    group_by(.data$lemma, .data$pos) |>
    arrange(desc(.data$strength), .by_group = TRUE) |>
    summarise(
      sentiment = first(.data$sentiment),
      markedness = first(str_trim(.data$markedness)),
      n_synsets = n(),
      .groups = "drop"
    ) |>
    arrange(.data$lemma, .data$pos)

  message(sprintf("After dedupe (lemma, pos): %d", nrow(deduped)))

  write_csv(deduped, plwn_out_csv)
  message(sprintf("Wrote %s", plwn_out_csv))

  if (nrow(drops_df) > 0) {
    write_csv(drops_df, plwn_drops_csv)
    message(sprintf("Wrote drop samples to %s (%d rows)", plwn_drops_csv, nrow(drops_df)))
  }

  message("--- Summary ---")
  message(sprintf("lex parsed: %d (drops %d)", nrow(lex_df), parsed$n_lex_drop))
  message(sprintf("emo parsed: %d (drops %d)", nrow(emo_df), parsed$n_emo_drop))
  message(sprintf("joined:     %d", nrow(joined)))
  message(sprintf("after filt: %d", nrow(enriched)))
  message(sprintf("final:      %d", nrow(deduped)))
  by_sent <- deduped |> count(.data$sentiment)
  for (i in seq_len(nrow(by_sent))) {
    message(sprintf("  %s: %d", by_sent$sentiment[i], by_sent$n[i]))
  }

  invisible(deduped)
}

if (sys.nframe() == 0) {
  build_plwordnet_csv()
}
