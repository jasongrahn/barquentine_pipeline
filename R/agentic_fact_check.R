# Mechanical line-citation verification for agentic extraction output.
# No LLM. Each extracted item carries a `line` field; this checker confirms
# the cited line falls inside the VTT range and (for dialogue) that the
# quoted substring is present at the cited line.
#
# `verify_line_citations()` does NOT block dispatch. A row with low
# fact-check confidence still flows to the reviewer; the score is surfaced
# in the queue row's verdict / confidence fields, and Shiny renders the
# per-row supported flag.

suppressPackageStartupMessages({
  library(dplyr); library(stringr); library(tibble)
})

.dialogue_line_text <- function(line_no, raw_lines) {
  if (is.na(line_no) || line_no < 1L || line_no > length(raw_lines))
    return(NA_character_)
  raw_lines[[line_no]]
}

# Check one row of an extracted frame. line must be in [1, max_line]. For
# dialogue, the quoted substring (case-insensitive, whitespace-collapsed)
# must appear in the cited line's text. Other frames only need a valid line.
.supported_row <- function(line_no, max_line, quoted = NA_character_,
                           raw_lines = NULL) {
  if (is.na(line_no)) return(FALSE)
  if (line_no < 1L || line_no > max_line) return(FALSE)
  if (is.na(quoted) || !nzchar(quoted)) return(TRUE)
  text <- .dialogue_line_text(line_no, raw_lines)
  if (is.na(text) || !nzchar(text)) return(FALSE)
  # Tolerant containment: collapse internal whitespace and lowercase both sides
  # so that whitespace normalization between source/extractor doesn't tank the
  # confidence score. The cited line is the anchor; we only require the
  # extracted quote to be a contiguous substring after normalization.
  needle <- str_squish(tolower(quoted))
  hay    <- str_squish(tolower(text))
  str_detect(hay, fixed(needle))
}

.frame_results <- function(df, kind, max_line, raw_lines) {
  if (is.null(df) || nrow(df) == 0L) return(tibble())
  line_vec  <- if ("line" %in% names(df)) suppressWarnings(as.integer(df$line))
               else rep(NA_integer_, nrow(df))
  quote_vec <- if (kind == "dialogue" && "dialogue" %in% names(df))
                 as.character(df$dialogue) else rep(NA_character_, nrow(df))
  supported <- vapply(seq_len(nrow(df)), function(i) {
    .supported_row(line_vec[[i]], max_line, quote_vec[[i]], raw_lines)
  }, logical(1))
  tibble(kind = kind, line = line_vec, supported = supported)
}

# Public API. Returns a list with:
#   n_checked  — total rows across all frames
#   n_unsupported  — rows whose line is out of range OR (dialogue) quote not
#                    present at the cited line
#   confidence — n_supported / n_checked (NA if n_checked == 0)
#   results    — long-form per-row data frame (kind, line, supported)
verify_line_citations <- function(merged, vtt) {
  raw_lines <- if (!is.null(vtt$raw_lines)) vtt$raw_lines
               else if (!is.null(vtt$play_section) &&
                        "raw_line" %in% names(vtt$play_section) &&
                        "text" %in% names(vtt$play_section)) {
                 # Reconstruct a sparse index: position == raw_line. Out-of-range
                 # rows still verify against max(raw_line), they just can't
                 # substring-match.
                 max_rl <- max(vtt$play_section$raw_line, na.rm = TRUE)
                 vec <- rep(NA_character_, max_rl)
                 vec[vtt$play_section$raw_line] <- vtt$play_section$text
                 vec
               } else character(0)

  max_line <- if (length(raw_lines) > 0L) length(raw_lines)
              else if (!is.null(vtt$play_section) && "raw_line" %in% names(vtt$play_section))
                max(vtt$play_section$raw_line, na.rm = TRUE)
              else .Machine$integer.max

  per_frame <- list(
    .frame_results(merged$events,    "event",    max_line, raw_lines),
    .frame_results(merged$npcs,      "npc",      max_line, raw_lines),
    .frame_results(merged$locations, "location", max_line, raw_lines),
    .frame_results(merged$dialogue,  "dialogue", max_line, raw_lines)
  )
  results <- bind_rows(per_frame)

  n_checked     <- nrow(results)
  n_supported   <- sum(results$supported, na.rm = TRUE)
  n_unsupported <- n_checked - n_supported
  confidence    <- if (n_checked == 0L) NA_real_ else n_supported / n_checked

  list(
    n_checked     = as.integer(n_checked),
    n_unsupported = as.integer(n_unsupported),
    confidence    = confidence,
    results       = results
  )
}
