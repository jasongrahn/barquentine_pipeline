# 00_preprocess_vtt.R
# Converts raw VTT into clean, chunked text ready for LLM extraction.
# No LLM needed — pure text processing.

library(tidyverse)
library(glue)

preprocess_vtt <- function(vtt_path, chunk_size = 50) {
  # chunk_size = number of dialogue lines per chunk (~800-1000 words)
  
  raw <- read_lines(vtt_path)
  
  # --- Extract session date from filename ---
  session_date <- str_extract(basename(vtt_path), "\\d{8}") |>
    as.Date(format = "%Y%m%d")
  
  # --- Strip VTT formatting ---
  # Remove: WEBVTT header, blank lines, numeric cue IDs, timestamp lines
  dialogue <- tibble(raw_line = seq_along(raw), text = raw) |>
    filter(
      text != "WEBVTT",
      text != "",
      !str_detect(text, "^\\d+$"),
      !str_detect(text, "^\\d{2}:\\d{2}:\\d{2}")
    ) |>
    mutate(text = str_trim(text))
  
  # --- Normalize speaker labels ---
  # The Admiral = DM, Lumi has variable capitalization/punctuation
  dialogue <- dialogue |>
    mutate(
      speaker = case_when(
        str_detect(text, "^The Admiral:") ~ "DM",
        str_detect(text, "^The Captain:") ~ "Captain",
        str_detect(text, "^Room:") ~ "Room",
        str_detect(text, regex("^L[Uu][Mm][Ii][!]?:", ignore_case = FALSE)) ~ "Lumi",
        str_detect(text, "^Audio shared by") ~ "SYSTEM",
        TRUE ~ "CONTINUATION"
      ),
      # Clean speaker prefix from text for downstream use
      clean_text = str_remove(text, "^(The Admiral|The Captain|Room|[Ll][Uu][Mm][Ii][!]?):\\s*")
    )
  
  # --- Detect section boundaries ---
  recap_start <- which(str_detect(dialogue$text, regex("Previously on", ignore_case = TRUE)))
  recap_start <- if (length(recap_start) > 0) min(recap_start) else 1
  
  # Session start: "Find out this time" / "Welcome to Barq/Bark" / first non-recap DM line
  session_markers <- which(str_detect(
    dialogue$text,
    regex("Find out this time|Welcome to Barq|I'm Barq|Hue music", ignore_case = TRUE)
  ))
  # Take the first marker that appears near the top of the file (within first 200 lines)
  session_start <- session_markers[session_markers < 200]
  session_start <- if (length(session_start) > 0) max(session_start) + 1 else recap_start + 20
  
  # Session end: "end today's session" / "end the session"
  session_end_markers <- which(str_detect(
    dialogue$text,
    regex("end today.s session|end the session|where we will end", ignore_case = TRUE)
  ))
  session_end <- if (length(session_end_markers) > 0) max(session_end_markers) else nrow(dialogue)
  
  # --- Segment ---
  recap_section <- dialogue |>
    slice(recap_start:min(session_start - 1, nrow(dialogue)))
  
  play_section <- dialogue |>
    slice(session_start:session_end)
  
  # --- Chunk the play section ---
  play_section <- play_section |>
    mutate(chunk_id = (row_number() - 1) %/% chunk_size + 1)
  
  chunks <- play_section |>
    group_by(chunk_id) |>
    summarize(
      start_line = min(raw_line),
      end_line = max(raw_line),
      text = paste(text, collapse = "\n"),
      n_lines = n(),
      word_count = sum(str_count(clean_text, "\\S+")),
      .groups = "drop"
    )
  
  # --- Build recap context string ---
  recap_context <- recap_section |>
    filter(speaker == "DM") |>
    pull(text) |>
    paste(collapse = " ") |>
    str_remove("The Admiral:\\s*")
  
  list(
    session_date = session_date,
    filename = basename(vtt_path),
    recap_context = recap_context,
    chunks = chunks,
    play_section = play_section,
    n_chunks = nrow(chunks),
    total_words = sum(chunks$word_count)
  )
}

# --- Usage ---
# vtt <- preprocess_vtt("path/to/session.vtt", chunk_size = 50)
# vtt$chunks         # tibble of chunks ready for LLM
# vtt$recap_context   # "Previously on" text for context injection
# vtt$session_date    # extracted date
