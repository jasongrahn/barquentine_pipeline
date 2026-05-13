# Agentic VTT → session-note extraction pipeline.
#
# Production lift of agents/run_wiki_pipeline.R. Each exported function is a
# targets-friendly unit: pure-R or single-LLM-call, deterministic inputs and
# outputs, no setwd / no getwd, every path/config value passed in by caller.
#
# Boundary preserved from the prototype: the LLM writes only the Synopsis
# paragraph. R does every other section of the assembled session note.

suppressPackageStartupMessages({
  library(dplyr); library(stringr); library(readr)
  library(jsonlite); library(glue); library(tibble); library(yaml); library(purrr)
})

# Loaded for side-effects so this file is self-sufficient when sourced by tests
# or smoke-test scripts. _targets.R sources these explicitly; the duplicate
# source() is idempotent in R.
.this_file_dir <- function() {
  fp <- tryCatch(sys.frame(1)$ofile, error = function(e) NULL)
  if (is.null(fp)) "R" else dirname(normalizePath(fp))
}

# ---------------------------------------------------------------------------
# preprocess_vtt_for_extraction — thin wrapper over agents/preprocess_vtt.R
# ---------------------------------------------------------------------------
# Returns the same list shape as agents/preprocess_vtt.R::preprocess_vtt():
#   list(session_date, filename, recap_context, chunks, play_section,
#        n_chunks, total_words).
# Kept as a wrapper (rather than copying the body in) so the prototype and
# the production path stay in lock-step on preprocessing changes.
preprocess_vtt_for_extraction <- function(vtt_path,
                                          chunk_size = AGENTIC_CHUNK_SIZE_LINES,
                                          preprocess_script = "agents/preprocess_vtt.R") {
  if (!file.exists(vtt_path)) stop("VTT not found: ", vtt_path)
  if (!exists("preprocess_vtt", mode = "function")) {
    if (!file.exists(preprocess_script))
      stop("preprocess_vtt script not found: ", preprocess_script)
    source(preprocess_script, local = FALSE)
  }
  preprocess_vtt(vtt_path, chunk_size = chunk_size)
}

# ---------------------------------------------------------------------------
# Internal: skill prompt loading and JSON-with-fences tolerance
# ---------------------------------------------------------------------------
.load_skill <- function(skill_name, type, skills_dir) {
  path <- file.path(skills_dir, skill_name, paste0(type, ".md"))
  if (!file.exists(path)) stop("Missing skill file: ", path)
  paste(readLines(path, warn = FALSE), collapse = "\n")
}

.strip_json_fences <- function(raw) {
  if (is.null(raw) || !nzchar(raw)) return(raw)
  raw <- str_replace_all(raw, "(?s)```json\\s*", "")
  raw <- str_replace_all(raw, "(?s)```\\s*",     "")
  trimws(raw)
}

.parse_skill_json <- function(raw, skill_label, chunk_id) {
  if (is.null(raw)) {
    cli::cli_warn("[{skill_label} chunk {chunk_id}] empty response \u2014 dropping")
    return(NULL)
  }
  if (is.list(raw) && isTRUE(raw$timed_out)) {
    cli::cli_warn("[{skill_label} chunk {chunk_id}] Ollama timeout \u2014 dropping")
    return(NULL)
  }
  cleaned <- .strip_json_fences(raw)
  tryCatch(fromJSON(cleaned, simplifyVector = TRUE),
           error = function(e) {
             cli::cli_warn(
               "[{skill_label} chunk {chunk_id}] JSON parse failed: {e$message}"
             )
             NULL
           })
}

.call_ollama_skill <- function(model, system, user, base_url = OLLAMA_BASE_URL,
                               think = FALSE, format = NULL) {
  ollama_generate(
    prompt        = user,
    system_prompt = system,
    model         = model,
    base_url      = base_url,
    format        = format,
    think         = think
  )
}

# ---------------------------------------------------------------------------
# extract_chunk — one chunk, three skills (events / entities / dialogue)
# ---------------------------------------------------------------------------
# Returns a list with `events`, `npcs`, `locations`, `dialogue` data frames.
# Per-skill failure returns an empty tibble for that key only; one bad skill
# call does NOT drop the other extractions for the chunk.
extract_chunk <- function(chunk_row,
                          recap_context,
                          chunk_id   = NA_integer_,
                          model      = OLLAMA_MODEL,
                          base_url   = OLLAMA_BASE_URL,
                          skills_dir = "agents/wiki_skills") {
  events_raw <- .call_ollama_skill(
    model  = model, base_url = base_url,
    system = .load_skill("01_extract_events", "system", skills_dir),
    user   = glue(.load_skill("01_extract_events", "user_template", skills_dir),
                  recap_context = recap_context,
                  start_line    = chunk_row$start_line,
                  end_line      = chunk_row$end_line,
                  chunk_text    = chunk_row$text,
                  .open = "{", .close = "}")
  )
  events <- .parse_skill_json(events_raw, "events", chunk_id)
  events_df <- if (!is.null(events) && is.data.frame(events) && nrow(events) > 0L)
    events else tibble()

  entities_raw <- .call_ollama_skill(
    model  = model, base_url = base_url,
    system = .load_skill("02_extract_entities", "system", skills_dir),
    user   = glue(.load_skill("02_extract_entities", "user_template", skills_dir),
                  start_line = chunk_row$start_line,
                  end_line   = chunk_row$end_line,
                  chunk_text = chunk_row$text,
                  .open = "{", .close = "}")
  )
  entities <- .parse_skill_json(entities_raw, "entities", chunk_id)
  npcs_df      <- if (!is.null(entities) && !is.null(entities$npcs)      &&
                      is.data.frame(entities$npcs)      && nrow(entities$npcs)      > 0L)
                    entities$npcs      else tibble()
  locations_df <- if (!is.null(entities) && !is.null(entities$locations) &&
                      is.data.frame(entities$locations) && nrow(entities$locations) > 0L)
                    entities$locations else tibble()

  dialogue_raw <- .call_ollama_skill(
    model  = model, base_url = base_url,
    system = .load_skill("03_extract_dialogue", "system", skills_dir),
    user   = glue(.load_skill("03_extract_dialogue", "user_template", skills_dir),
                  start_line = chunk_row$start_line,
                  end_line   = chunk_row$end_line,
                  chunk_text = chunk_row$text,
                  .open = "{", .close = "}")
  )
  dialogue <- .parse_skill_json(dialogue_raw, "dialogue", chunk_id)
  dialogue_df <- if (!is.null(dialogue) && is.data.frame(dialogue) && nrow(dialogue) > 0L)
    dialogue else tibble()

  list(events = events_df, npcs = npcs_df,
       locations = locations_df, dialogue = dialogue_df)
}

# ---------------------------------------------------------------------------
# merge_chunk_extractions — union + dedup + line-coerce
# ---------------------------------------------------------------------------
# Local models sometimes emit numeric strings for `line`; coerce to integer
# defensively so bind_rows() does not refuse mixed types. Returns a list of
# four tibbles in the same shape extract_chunk() returns.
.coerce_line <- function(df) {
  if (is.null(df) || !is.data.frame(df) || nrow(df) == 0L) return(df)
  if ("line" %in% names(df)) df$line <- suppressWarnings(as.integer(df$line))
  df
}

merge_chunk_extractions <- function(per_chunk_results,
                                    dialogue_keep_n = AGENTIC_DIALOGUE_KEEP_N) {
  all_events    <- lapply(per_chunk_results, function(r) r$events)
  all_npcs      <- lapply(per_chunk_results, function(r) r$npcs)
  all_locations <- lapply(per_chunk_results, function(r) r$locations)
  all_dialogue  <- lapply(per_chunk_results, function(r) r$dialogue)

  merged_events <- if (any(vapply(all_events, NROW, integer(1)) > 0L)) {
    bind_rows(lapply(all_events, .coerce_line)) |>
      distinct(event, .keep_all = TRUE) |>
      arrange(line)
  } else tibble()

  merged_npcs <- if (any(vapply(all_npcs, NROW, integer(1)) > 0L)) {
    bind_rows(lapply(all_npcs, .coerce_line)) |>
      group_by(name) |>
      summarize(
        description = first(description),
        appeared    = any(as.logical(appeared), na.rm = TRUE),
        line        = suppressWarnings(min(line, na.rm = TRUE)),
        .groups     = "drop"
      )
  } else tibble()

  merged_locations <- if (any(vapply(all_locations, NROW, integer(1)) > 0L)) {
    bind_rows(lapply(all_locations, .coerce_line)) |>
      group_by(name) |>
      summarize(
        description = first(description),
        line        = suppressWarnings(min(line, na.rm = TRUE)),
        .groups     = "drop"
      )
  } else tibble()

  merged_dialogue <- if (any(vapply(all_dialogue, NROW, integer(1)) > 0L)) {
    bind_rows(lapply(all_dialogue, .coerce_line)) |>
      distinct(dialogue, .keep_all = TRUE) |>
      arrange(line) |>
      slice_head(n = dialogue_keep_n)
  } else tibble()

  list(events    = merged_events,
       npcs      = merged_npcs,
       locations = merged_locations,
       dialogue  = merged_dialogue)
}

# ---------------------------------------------------------------------------
# synthesize_session_recap — single LLM call, Synopsis paragraph only
# ---------------------------------------------------------------------------
# Mirrors the prototype's sentinel pattern: on timeout returns
# list(timed_out = TRUE) rather than NULL or an error, so the assembler can
# substitute a placeholder without crashing the targets graph.
synthesize_session_recap <- function(merged,
                                     vtt_meta,
                                     model      = OLLAMA_MODEL,
                                     base_url   = OLLAMA_BASE_URL,
                                     skills_dir = "agents/wiki_skills") {
  raw <- .call_ollama_skill(
    model  = model, base_url = base_url,
    system = .load_skill("04_synthesize_recap", "system", skills_dir),
    user   = glue(.load_skill("04_synthesize_recap", "user_template", skills_dir),
                  session_date   = vtt_meta$session_date,
                  recap_context  = vtt_meta$recap_context %||% "",
                  events_json    = toJSON(merged$events,    pretty = TRUE, auto_unbox = TRUE),
                  npcs_json      = toJSON(merged$npcs,      pretty = TRUE, auto_unbox = TRUE),
                  locations_json = toJSON(merged$locations, pretty = TRUE, auto_unbox = TRUE),
                  dialogue_json  = toJSON(merged$dialogue,  pretty = TRUE, auto_unbox = TRUE),
                  .open = "{", .close = "}")
  )
  if (is.null(raw)) return(list(timed_out = FALSE, text = ""))
  if (is.list(raw) && isTRUE(raw$timed_out)) return(list(timed_out = TRUE, text = ""))
  list(timed_out = FALSE, text = as.character(raw))
}

# ---------------------------------------------------------------------------
# Internal helpers for markdown assembly
# ---------------------------------------------------------------------------
# Extract just the body of "## Synopsis ..." from the LLM output (strip the
# heading itself; the assembler emits its own). Tolerant of stray fences or
# extra blank lines.
.extract_synopsis_body <- function(synth_text) {
  if (is.null(synth_text) || !nzchar(synth_text)) return("")
  body <- str_replace(synth_text, regex("^\\s*##\\s*Synopsis\\s*\\n", ignore_case = TRUE), "")
  # Cut off any spurious follow-on headings — system prompt forbids them but
  # local models sometimes ignore that.
  body <- str_split(body, regex("\\n##\\s+"), n = 2)[[1]][1]
  trimws(body)
}

.pcs_present <- function(vtt_meta) {
  ps <- vtt_meta$play_section
  if (is.null(ps) || !is.data.frame(ps) || nrow(ps) == 0L) return(character(0))
  speakers <- unique(ps$speaker)
  setdiff(speakers, c("DM", "SYSTEM", "CONTINUATION", NA_character_))
}

.fmt_yaml_list <- function(values) {
  if (length(values) == 0L) return("[]")
  quoted <- vapply(values, function(v) {
    v <- as.character(v)
    paste0('"', str_replace_all(v, '"', '\\\\"'), '"')
  }, character(1), USE.NAMES = FALSE)
  paste0("[", paste(quoted, collapse = ", "), "]")
}

.frontmatter <- function(session_date, pcs, npcs, locations) {
  paste(
    "---",
    paste0("session_date: ", session_date),
    'episode_title: ""',
    paste0("pcs: ",       .fmt_yaml_list(pcs)),
    paste0("npcs: ",      .fmt_yaml_list(npcs)),
    paste0("locations: ", .fmt_yaml_list(locations)),
    "tags: [session-recap, barquentine]",
    "source: vtt",
    "review_required: true",
    "---",
    sep = "\n"
  )
}

.fmt_major_events <- function(events) {
  if (is.null(events) || nrow(events) == 0L)
    return("_(No events extracted from source.)_")
  lines <- mapply(function(line, event) {
    line_tag <- if (is.na(line)) "?" else as.character(line)
    sprintf("- (line %s) %s", line_tag, event)
  }, events$line, events$event, USE.NAMES = FALSE)
  paste(lines, collapse = "\n")
}

.fmt_entity_blocks <- function(df) {
  if (is.null(df) || nrow(df) == 0L) return("_(none)_")
  desc_col <- if ("description" %in% names(df)) df$description else rep("", nrow(df))
  blocks <- mapply(function(name, desc) {
    desc_text <- if (is.na(desc) || !nzchar(trimws(as.character(desc))))
      "_(no description in source)_" else as.character(desc)
    paste0("### ", name, "\n", desc_text)
  }, df$name, desc_col, USE.NAMES = FALSE)
  paste(blocks, collapse = "\n\n")
}

.fmt_dialogue <- function(dialogue) {
  if (is.null(dialogue) || nrow(dialogue) == 0L) return("_(none)_")
  speaker_col <- if ("speaker" %in% names(dialogue)) dialogue$speaker else rep(NA, nrow(dialogue))
  context_col <- if ("context" %in% names(dialogue)) dialogue$context else rep("", nrow(dialogue))
  blocks <- mapply(function(quote, speaker, context) {
    speaker_part <- if (!is.na(speaker) && nzchar(speaker))
      paste0(" \u2014 **", speaker, "**") else ""
    ctx <- if (is.na(context) || !nzchar(trimws(as.character(context)))) ""
           else paste0("\n", context)
    paste0("> \"", quote, "\"", speaker_part, ctx)
  }, dialogue$dialogue, speaker_col, context_col, USE.NAMES = FALSE)
  paste(blocks, collapse = "\n\n")
}

# ---------------------------------------------------------------------------
# assemble_session_markdown — R-frontloaded session-note assembly
# ---------------------------------------------------------------------------
# The synthesis LLM owns only the Synopsis paragraph. Everything else
# (frontmatter, Major Events, NPCs Encountered, Locations Visited, Key
# Dialogue, Unresolved Threads, Session Notes) is assembled by R from the
# `merged` extraction output, so the produced markdown is a deterministic
# function of the line-cited extracted facts.
assemble_session_markdown <- function(synthesis,
                                      merged,
                                      vtt_meta) {
  synopsis_body <- .extract_synopsis_body(synthesis$text %||% "")
  if (!nzchar(synopsis_body))
    synopsis_body <- "_(synthesis failed \u2014 see extracted intermediates)_"

  pcs       <- .pcs_present(vtt_meta)
  npc_names <- if (nrow(merged$npcs) > 0L)      sort(unique(merged$npcs$name))      else character(0)
  loc_names <- if (nrow(merged$locations) > 0L) sort(unique(merged$locations$name)) else character(0)

  paste(
    .frontmatter(vtt_meta$session_date, pcs, npc_names, loc_names),
    "",
    paste0("# Session ", vtt_meta$session_date),
    "",
    "## Synopsis",
    synopsis_body,
    "",
    "## Major Events",
    "",
    .fmt_major_events(merged$events),
    "",
    "## NPCs Encountered",
    "",
    .fmt_entity_blocks(merged$npcs),
    "",
    "## Locations Visited",
    "",
    .fmt_entity_blocks(merged$locations),
    "",
    "## Key Dialogue",
    "",
    .fmt_dialogue(merged$dialogue),
    "",
    "## Unresolved Threads",
    "",
    "_(Reviewer: fill in based on Major Events.)_",
    "",
    "## Session Notes",
    "",
    "None this session.",
    sep = "\n"
  )
}

`%||%` <- function(x, y) if (is.null(x)) y else x
