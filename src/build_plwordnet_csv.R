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

pos_int_to_upos <- c("1" = "NOUN", "2" = "VERB", "3" = "ADJ", "4" = "ADV")

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
      "plWordNet ZIP not found at: %s\n  Download from: https://clarin-pl.eu/dspace/handle/11321/535 (or https://clarin-pl.eu/wordnet/)\n  Place the file `wordnet_work_4_5.zip` into: %s",
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

# Track which table the current INSERT block belongs to. Closure-based state.
make_chunk_callback <- function() {
  state <- new.env(parent = emptyenv())
  state$current_table <- NA_character_
  state$lex_rows <- list()
  state$emo_rows <- list()
  state$drops <- list()
  state$n_lex_lines <- 0L
  state$n_emo_lines <- 0L
  state$n_lex_drop <- 0L
  state$n_emo_drop <- 0L

  cb <- function(lines, pos) {
    for (ln in lines) {
      if (startsWith(ln, "INSERT INTO `lexicalunit`")) {
        state$current_table <- "lexicalunit"
        # The first tuple is on the same line right after VALUES. awk splits inter-tuple
        # `),(` but the very first `(` follows ` VALUES `. Re-anchor by stripping prefix.
        m <- regexpr("VALUES \\(", ln)
        if (m > 0) {
          rest <- substring(ln, m + nchar("VALUES "))
          parse_lex(rest, state)
        }
        next
      }
      if (startsWith(ln, "INSERT INTO `emotion`")) {
        state$current_table <- "emotion"
        m <- regexpr("VALUES \\(", ln)
        if (m > 0) {
          rest <- substring(ln, m + nchar("VALUES "))
          parse_emo(rest, state)
        }
        next
      }
      if (!startsWith(ln, "(")) next

      if (identical(state$current_table, "lexicalunit")) {
        parse_lex(ln, state)
      } else if (identical(state$current_table, "emotion")) {
        parse_emo(ln, state)
      }
    }
    TRUE
  }

  list(callback = cb, state = state)
}

parse_lex <- function(line, state) {
  state$n_lex_lines <- state$n_lex_lines + 1L
  m <- tryCatch(
    regmatches(line, regexec(lex_rx, line, perl = TRUE)),
    error = function(e) list(character(0))
  )
  if (length(m[[1]]) == 0L) {
    state$n_lex_drop <- state$n_lex_drop + 1L
    state$drops[[length(state$drops) + 1L]] <- data.frame(
      table = "lexicalunit", reason = "regex_no_match",
      snippet = substr(line, 1, 200), stringsAsFactors = FALSE
    )
    return(invisible())
  }
  parts <- m[[1]]
  # parts: [full, id, lemma, domain, pos]
  state$lex_rows[[length(state$lex_rows) + 1L]] <- list(
    ID = suppressWarnings(as.integer(parts[2])),
    lemma = parts[3],
    domain = suppressWarnings(as.integer(parts[4])),
    pos_int = suppressWarnings(as.integer(parts[5]))
  )
  invisible()
}

parse_emo <- function(line, state) {
  state$n_emo_lines <- state$n_emo_lines + 1L
  m <- tryCatch(
    regmatches(line, regexec(emo_rx, line, perl = TRUE)),
    error = function(e) list(character(0))
  )
  if (length(m[[1]]) == 0L) {
    state$n_emo_drop <- state$n_emo_drop + 1L
    state$drops[[length(state$drops) + 1L]] <- data.frame(
      table = "emotion", reason = "regex_no_match",
      snippet = substr(line, 1, 200), stringsAsFactors = FALSE
    )
    return(invisible())
  }
  parts <- m[[1]]
  # parts: [full, id, lexicalunit_id, emotions, valuations, markedness]
  state$emo_rows[[length(state$emo_rows) + 1L]] <- list(
    id = suppressWarnings(as.integer(parts[2])),
    lexicalunit_id = suppressWarnings(as.integer(parts[3])),
    emotions = parts[4],
    valuations = parts[5],
    markedness = parts[6]
  )
  invisible()
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

  extract_filtered_dump(plwn_zip_path, plwn_inner_sql, plwn_filtered_txt)

  message("Parsing filtered dump in chunks...")
  cb_pack <- make_chunk_callback()
  read_lines_chunked(
    plwn_filtered_txt,
    callback = SideEffectChunkCallback$new(cb_pack$callback),
    chunk_size = 50000L,
    progress = FALSE
  )

  st <- cb_pack$state

  lex_df <- if (length(st$lex_rows) > 0) {
    bind_rows(lapply(st$lex_rows, as_tibble))
  } else {
    tibble(ID = integer(), lemma = character(), domain = integer(), pos_int = integer())
  }

  emo_df <- if (length(st$emo_rows) > 0) {
    bind_rows(lapply(st$emo_rows, as_tibble))
  } else {
    tibble(
      id = integer(), lexicalunit_id = integer(),
      emotions = character(), valuations = character(), markedness = character()
    )
  }

  drops_df <- if (length(st$drops) > 0) bind_rows(st$drops) else tibble(table = character(), reason = character(), snippet = character())

  message(sprintf("Parsed lex rows: %d (drops: %d)", nrow(lex_df), st$n_lex_drop))
  message(sprintf("Parsed emo rows: %d (drops: %d)", nrow(emo_df), st$n_emo_drop))

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
  message(sprintf("lex parsed: %d (drops %d)", nrow(lex_df), st$n_lex_drop))
  message(sprintf("emo parsed: %d (drops %d)", nrow(emo_df), st$n_emo_drop))
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
