# Agentic entity-note extraction (Phase 4.2).
#
# One LLM call per entity record, all aggregated passages concatenated as the
# prompt input. Mirrors the per-chunk extraction pattern in agentic_extract.R
# but operates on a single entity at a time.
#
# Reuses private helpers from agentic_extract.R (.load_skill, .call_ollama_skill,
# .parse_skill_json, .strip_json_fences). These are sourced for side-effects so
# this file is self-sufficient when sourced by tests or smoke-test scripts.

suppressPackageStartupMessages({
  library(glue); library(cli); library(jsonlite)
})

.agentic_entity_src_dir <- tryCatch(
  dirname(normalizePath(sys.frame(1L)$ofile)), error = function(e) "R")
if (!exists(".call_ollama_skill", mode = "function"))
  source(file.path(.agentic_entity_src_dir, "agentic_extract.R"), local = FALSE)
if (!exists("parse_tool_calls", mode = "function"))
  source(file.path(.agentic_entity_src_dir, "ollama.R"), local = FALSE)
if (!exists("entity_schema", mode = "function")) {
  src_dir <- tryCatch(dirname(normalizePath(sys.frame(1L)$ofile)),
                      error = function(e) "R")
  source(file.path(src_dir, "agentic_entity_schemas.R"), local = FALSE)
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

`%||%` <- function(x, y) if (is.null(x)) y else x

.entity_skill_name <- function(note_type) {
  switch(note_type,
    pc       = "05_extract_pc",
    npc      = "06_extract_npc",
    location = "07_extract_location",
    faction  = "08_extract_faction",
    stop("Unknown note_type for entity extraction: ", note_type)
  )
}

.count_words <- function(text) {
  length(strsplit(trimws(text), "\\s+")[[1L]])
}

# Number each passage so the extraction model can cite specific entries.
# Returns a single formatted string "PASSAGE [1]:\n<p1>\n\nPASSAGE [2]:\n<p2>\n\n..."
# The PASSAGE [N] label is deliberately distinct from numbers embedded in VTT content.
.number_passages <- function(passages) {
  paste(paste0("PASSAGE [", seq_along(passages), "]:\n", passages), collapse = "\n\n")
}

# Drop trailing passages that push total word count over the limit.
# Always keeps at least one passage. Emits a warning if truncation occurs.
.truncate_passages <- function(passages, word_limit) {
  if (length(passages) == 0L) return(passages)
  running <- ""
  kept    <- 0L
  for (p in passages) {
    candidate <- if (nzchar(running)) paste0(running, "\n\n", p) else p
    if (.count_words(candidate) > word_limit && nzchar(running)) break
    running <- candidate
    kept    <- kept + 1L
  }
  kept <- max(1L, kept)
  if (kept < length(passages))
    cli::cli_warn(c(
      "Entity passages truncated for passage_word_limit.",
      "i" = "Kept {kept}/{length(passages)} passages (limit: {word_limit} words)."
    ))
  passages[seq_len(kept)]
}

# Augments the base system prompt with a tool definition so Gemma4 emits
# a <tool_call> XML block instead of raw JSON under constrained decoding.
# The tool name matches .entity_skill_name() for easy lookup.
.entity_tc_system <- function(note_type, base_system) {
  tool_name <- paste0("extract_", note_type)
  tool_def  <- toJSON(
    list(list(name        = tool_name,
              description = paste("Extract structured", note_type,
                                  "information from D&D session transcript passages."),
              parameters  = entity_schema(note_type))),
    auto_unbox = TRUE, pretty = FALSE
  )
  paste0(
    base_system,
    "\n\nYou have access to this tool:\n", tool_def,
    "\n\nCall the tool to return your answer. Output exactly:\n",
    '<tool_call>{"name":"', tool_name, '","arguments":{...your fields...}}</tool_call>'
  )
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

#' Extract structured information about one entity from its aggregated passages.
#'
#' @param entity_record  Named list with entity_id, entity_name, note_type,
#'   source_passages (character vector), source_episode_ids (character vector).
#' @param recap_context  Brief orientation string (from VTT meta); passed to the
#'   skill but not checked — extraction may cite only source_passages lines.
#' @param model          Ollama model name; defaults to AGENTIC_ENTITY_MODEL.
#' @param base_url       Ollama base URL.
#' @param skills_dir     Root directory for skill subdirectories.
#'
#' @return Named list: entity_id, note_type, extraction (parsed R list or NULL),
#'   timed_out (logical).
extract_entity <- function(entity_record,
                           recap_context = "",
                           model         = AGENTIC_ENTITY_MODEL,
                           base_url      = OLLAMA_BASE_URL,
                           skills_dir    = "agents/wiki_skills") {
  entity_id   <- entity_record$entity_id
  entity_name <- entity_record$entity_name
  note_type   <- entity_record$note_type
  passages    <- entity_record$source_passages

  passages <- .truncate_passages(passages, AGENTIC_ENTITY_PASSAGE_WORD_LIMIT)
  numbered_passages <- .number_passages(passages)

  aliases <- if (!is.null(entity_record$entity_aliases) &&
                  length(entity_record$entity_aliases) > 0L)
    paste(entity_record$entity_aliases, collapse = ", ") else ""

  skill  <- .entity_skill_name(note_type)
  system <- .load_skill(skill, "system", skills_dir)
  user   <- glue(
    .load_skill(skill, "user_template", skills_dir),
    entity_name     = entity_name,
    aliases         = aliases,
    note_type       = note_type,
    recap_context   = recap_context,
    source_passages = numbered_passages,
    .open = "{", .close = "}"
  )

  # --- D2: tool-calling loop (3 turns) ----------------------------------------
  # Try to elicit a <tool_call> block from Gemma4 without constrained decoding.
  # Falls back to the original format= path if all turns fail or produce no call.
  tc_system <- .entity_tc_system(note_type, system)
  tool_name <- paste0("extract_", note_type)
  timed_out <- FALSE

  for (turn in seq_len(3L)) {
    raw <- ollama_generate(
      prompt        = user,
      system_prompt = tc_system,
      model         = model,
      base_url      = base_url,
      format        = NULL,
      think         = FALSE
    )
    timed_out <- is.list(raw) && isTRUE(raw$timed_out)
    if (timed_out) break

    calls <- parse_tool_calls(raw %||% "")
    if (!is.null(calls)) {
      matched <- Filter(function(c) identical(c[["name"]], tool_name), calls)
      if (length(matched) > 0L) {
        return(list(entity_id     = entity_id,
                    note_type     = note_type,
                    extraction    = matched[[1L]][["arguments"]],
                    timed_out     = FALSE,
                    pipeline_path = "tool_calling"))
      }
    }
    cli_warn("Tool call turn {turn}/3 produced no valid {tool_name} call for {entity_id}.")
  }

  if (timed_out) {
    return(list(entity_id     = entity_id,
                note_type     = note_type,
                extraction    = NULL,
                timed_out     = TRUE,
                pipeline_path = "tool_call_timeout"))
  }

  # --- Fallback: original format= constrained-decoding path ------------------
  cli_warn("Tool calling failed for {entity_id}; falling back to format= path.")
  raw_fb    <- ollama_generate(
    prompt        = user,
    system_prompt = system,
    model         = model,
    base_url      = base_url,
    format        = entity_schema(note_type),
    think         = FALSE
  )
  timed_fb  <- is.list(raw_fb) && isTRUE(raw_fb$timed_out)
  extr_fb   <- if (timed_fb) NULL
               else .parse_skill_json(raw_fb, paste0("entity_", note_type), entity_id)

  list(entity_id     = entity_id,
       note_type     = note_type,
       extraction    = extr_fb,
       timed_out     = timed_fb,
       pipeline_path = "tool_call_fallback")
}
