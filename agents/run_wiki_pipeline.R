# run_wiki_pipeline.R
# Orchestrates the VTT → Wiki pipeline using narrow single-task skills.
# Chains: preprocess → extract (per chunk) → merge → synthesize.
#
# This is a prototype. Run from the project root:
#   source("agents/run_wiki_pipeline.R")
#   result <- run_wiki_pipeline("/Volumes/share/videos/<file>.vtt")

library(tidyverse)
library(glue)
library(jsonlite)

# --- Project-level config + Ollama wrapper -----------------------------------
# Loaded once when this file is sourced. config.R defines OLLAMA_MODEL,
# OLLAMA_BASE_URL, OLLAMA_TIMEOUT etc. ollama.R defines ollama_generate().
.this_dir <- dirname(sys.frame(1)$ofile %||% "agents/run_wiki_pipeline.R")
.project_root <- normalizePath(file.path(.this_dir, ".."))
source(file.path(.project_root, "config.R"))
source(file.path(.project_root, "R/ollama.R"))
source(file.path(.this_dir, "preprocess_vtt.R"))

# --- Configuration -----------------------------------------------------------
# Model is read from config.R (OLLAMA_MODEL) so the prototype tracks any
# pipeline-wide model swap automatically.
SKILLS_DIR <- file.path(.this_dir, "wiki_skills")
CHUNK_SIZE <- 50  # dialogue lines per chunk (~800-1000 words)

# --- Load skill prompts ------------------------------------------------------
.read_text_file <- function(path) {
  paste(readLines(path, warn = FALSE), collapse = "\n")
}

load_skill <- function(skill_name, type = "system") {
  path <- file.path(SKILLS_DIR, skill_name, glue("{type}.md"))
  if (!file.exists(path)) stop("Missing skill file: ", path)
  .read_text_file(path)
}

# --- Ollama wrapper ----------------------------------------------------------
# Thin shim over R/ollama.R::ollama_generate(). Returns either the raw model
# text (success), NULL (empty content), or list(timed_out = TRUE) on timeout.
# The caller is responsible for parsing JSON; we do not enforce schemas here
# so each skill can choose whether to use Ollama's `format` constraint.
call_ollama <- function(model, system, user, think = FALSE, format = NULL) {
  ollama_generate(
    prompt        = user,
    system_prompt = system,
    model         = model,
    base_url      = OLLAMA_BASE_URL,
    format        = format,
    think         = think
  )
}

# --- JSON parsing with chunk-failure tolerance -------------------------------
# Extraction skills return JSON. Local models occasionally emit prose
# preambles or stray fences; strip those before parsing. On unrecoverable
# parse failure, log and return NULL so the chunk is dropped from the merge
# rather than crashing the run.
.strip_json_fences <- function(raw) {
  if (is.null(raw) || !nzchar(raw)) return(raw)
  raw <- str_replace_all(raw, "(?s)```json\\s*", "")
  raw <- str_replace_all(raw, "(?s)```\\s*",   "")
  trimws(raw)
}

.parse_skill_json <- function(raw, skill_label, chunk_id) {
  if (is.null(raw)) {
    cli::cli_warn("[{skill_label} chunk {chunk_id}] empty response — dropping")
    return(NULL)
  }
  if (is.list(raw) && isTRUE(raw$timed_out)) {
    cli::cli_warn("[{skill_label} chunk {chunk_id}] Ollama timeout — dropping")
    return(NULL)
  }
  cleaned <- .strip_json_fences(raw)
  parsed  <- tryCatch(fromJSON(cleaned, simplifyVector = TRUE),
                      error = function(e) {
                        cli::cli_warn(
                          "[{skill_label} chunk {chunk_id}] JSON parse failed: {e$message}"
                        )
                        NULL
                      })
  parsed
}

# --- Pipeline ----------------------------------------------------------------
run_wiki_pipeline <- function(vtt_path,
                              output_dir = "/tmp/barquentine-agentic",
                              model      = OLLAMA_MODEL) {
  if (!file.exists(vtt_path)) stop("VTT not found: ", vtt_path)
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  cli::cli_h1("Processing: {basename(vtt_path)}")

  # --- Preprocess ---
  cli::cli_h2("Step 0: Preprocessing VTT")
  vtt <- preprocess_vtt(vtt_path, chunk_size = CHUNK_SIZE)
  cli::cli_alert_success("{vtt$n_chunks} chunks, {vtt$total_words} words")

  # Sidecar: dump the preprocessed view so we can inspect chunking quality.
  saveRDS(vtt, file.path(output_dir, "preprocessed.rds"))

  # --- Extract per chunk ---
  all_events    <- list()
  all_npcs      <- list()
  all_locations <- list()
  all_dialogue  <- list()

  t_start <- Sys.time()
  for (i in seq_len(vtt$n_chunks)) {
    chunk <- vtt$chunks[i, ]
    cli::cli_h2("Chunk {i}/{vtt$n_chunks} (lines {chunk$start_line}-{chunk$end_line}, {chunk$word_count} words)")

    # -- Events --
    events_raw <- call_ollama(
      model  = model,
      system = load_skill("01_extract_events", "system"),
      user   = glue(load_skill("01_extract_events", "user_template"),
                    recap_context = vtt$recap_context,
                    start_line    = chunk$start_line,
                    end_line      = chunk$end_line,
                    chunk_text    = chunk$text,
                    .open = "{", .close = "}"),
      think = FALSE
    )
    parsed_events <- .parse_skill_json(events_raw, "events", i)
    if (!is.null(parsed_events) && length(parsed_events) > 0 &&
        is.data.frame(parsed_events)) {
      all_events[[i]] <- parsed_events
    }

    # -- Entities --
    entities_raw <- call_ollama(
      model  = model,
      system = load_skill("02_extract_entities", "system"),
      user   = glue(load_skill("02_extract_entities", "user_template"),
                    start_line = chunk$start_line,
                    end_line   = chunk$end_line,
                    chunk_text = chunk$text,
                    .open = "{", .close = "}"),
      think = FALSE
    )
    parsed_entities <- .parse_skill_json(entities_raw, "entities", i)
    if (!is.null(parsed_entities)) {
      if (!is.null(parsed_entities$npcs) && is.data.frame(parsed_entities$npcs)) {
        all_npcs[[i]] <- parsed_entities$npcs
      }
      if (!is.null(parsed_entities$locations) && is.data.frame(parsed_entities$locations)) {
        all_locations[[i]] <- parsed_entities$locations
      }
    }

    # -- Dialogue --
    dialogue_raw <- call_ollama(
      model  = model,
      system = load_skill("03_extract_dialogue", "system"),
      user   = glue(load_skill("03_extract_dialogue", "user_template"),
                    start_line = chunk$start_line,
                    end_line   = chunk$end_line,
                    chunk_text = chunk$text,
                    .open = "{", .close = "}"),
      think = FALSE
    )
    parsed_dialogue <- .parse_skill_json(dialogue_raw, "dialogue", i)
    if (!is.null(parsed_dialogue) && length(parsed_dialogue) > 0 &&
        is.data.frame(parsed_dialogue)) {
      all_dialogue[[i]] <- parsed_dialogue
    }
  }
  t_extract <- difftime(Sys.time(), t_start, units = "mins")

  # Checkpoint raw per-chunk results before merging. Extraction is the
  # expensive step; a merge or coercion failure should not waste 25 minutes.
  saveRDS(list(events    = all_events,    npcs     = all_npcs,
               locations = all_locations, dialogue = all_dialogue),
          file.path(output_dir, "raw_extracted.rds"))

  # --- Merge and deduplicate ----------------------------------------------
  # Coerce `line` to integer defensively: local models sometimes emit
  # numeric strings, and bind_rows() refuses to combine mixed types.
  cli::cli_h2("Merging chunk outputs")

  .coerce_line <- function(df) {
    if (is.null(df) || !is.data.frame(df) || nrow(df) == 0) return(df)
    if ("line" %in% names(df)) df$line <- suppressWarnings(as.integer(df$line))
    df
  }

  merged_events <- if (length(all_events) > 0) {
    bind_rows(lapply(all_events, .coerce_line)) |>
      distinct(event, .keep_all = TRUE) |>
      arrange(line)
  } else tibble()

  merged_npcs <- if (length(all_npcs) > 0) {
    bind_rows(lapply(all_npcs, .coerce_line)) |>
      group_by(name) |>
      summarize(
        description = first(description),
        appeared    = any(as.logical(appeared)),
        line        = suppressWarnings(min(line, na.rm = TRUE)),
        .groups = "drop"
      )
  } else tibble()

  merged_locations <- if (length(all_locations) > 0) {
    bind_rows(lapply(all_locations, .coerce_line)) |>
      group_by(name) |>
      summarize(
        description = first(description),
        line        = suppressWarnings(min(line, na.rm = TRUE)),
        .groups = "drop"
      )
  } else tibble()

  merged_dialogue <- if (length(all_dialogue) > 0) {
    bind_rows(lapply(all_dialogue, .coerce_line)) |>
      distinct(dialogue, .keep_all = TRUE) |>
      arrange(line) |>
      slice_head(n = 8)
  } else tibble()

  cli::cli_alert_info(
    "{nrow(merged_events)} events, {nrow(merged_npcs)} NPCs, {nrow(merged_locations)} locations, {nrow(merged_dialogue)} dialogue lines"
  )

  # Persist intermediates so a synthesis failure doesn't waste the extraction work.
  saveRDS(list(events = merged_events, npcs = merged_npcs,
               locations = merged_locations, dialogue = merged_dialogue),
          file.path(output_dir, "extracted.rds"))

  # --- Synthesize -----------------------------------------------------------
  cli::cli_h2("Synthesizing wiki entry")
  t_synth_start <- Sys.time()

  wiki_entry <- call_ollama(
    model  = model,
    system = load_skill("04_synthesize_recap", "system"),
    user   = glue(load_skill("04_synthesize_recap", "user_template"),
                  session_date   = vtt$session_date,
                  recap_context  = vtt$recap_context,
                  events_json    = toJSON(merged_events,    pretty = TRUE, auto_unbox = TRUE),
                  npcs_json      = toJSON(merged_npcs,      pretty = TRUE, auto_unbox = TRUE),
                  locations_json = toJSON(merged_locations, pretty = TRUE, auto_unbox = TRUE),
                  dialogue_json  = toJSON(merged_dialogue,  pretty = TRUE, auto_unbox = TRUE),
                  .open = "{", .close = "}"),
    think = FALSE
  )
  t_synth <- difftime(Sys.time(), t_synth_start, units = "mins")

  if (is.null(wiki_entry) || (is.list(wiki_entry) && isTRUE(wiki_entry$timed_out))) {
    cli::cli_alert_danger("Synthesis failed (empty or timeout) — extraction data saved to {output_dir}/extracted.rds")
    wiki_entry <- "(synthesis failed — see extracted.rds for raw data)"
  }

  output_filename <- file.path(output_dir, glue("session_{vtt$session_date}.md"))
  writeLines(wiki_entry, output_filename)
  cli::cli_alert_success("Written to {output_filename}")
  cli::cli_alert_info("Extraction time: {round(as.numeric(t_extract), 2)} min, synthesis: {round(as.numeric(t_synth), 2)} min")

  invisible(list(
    session_date     = vtt$session_date,
    wiki_entry       = wiki_entry,
    merged_events    = merged_events,
    merged_npcs      = merged_npcs,
    merged_locations = merged_locations,
    merged_dialogue  = merged_dialogue,
    output_file      = output_filename,
    extract_minutes  = as.numeric(t_extract),
    synth_minutes    = as.numeric(t_synth)
  ))
}

`%||%` <- function(x, y) if (is.null(x)) y else x
