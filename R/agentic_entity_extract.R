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

.vault_subdir <- function(note_type) {
  switch(note_type, pc = "npcs", npc = "npcs", location = "locations", faction = "factions", "npcs")
}

# Read existing vault note for identity anchoring (F2). Returns "" when absent or empty.
.read_vault_note <- function(entity_id, note_type, vault_path = VAULT_PATH) {
  path <- file.path(vault_path, .vault_subdir(note_type), paste0(entity_id, ".md"))
  if (!file.exists(path)) return("")
  content <- tryCatch(paste(readLines(path, warn = FALSE), collapse = "\n"),
                      error = function(e) "")
  if (nchar(trimws(content)) == 0L) "" else content
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

# R-side parse for format=NULL responses: fence-strip → JSON parse → schema validate.
# Returns NULL if parsing or validation fails (F0.5).
.validate_entity_extraction <- function(parsed, note_type) {
  if (is.null(parsed) || !is.list(parsed) || length(parsed) == 0L) return(FALSE)
  expected <- names(entity_schema(note_type)$properties)
  any(expected %in% names(parsed))
}

.parse_entity_json <- function(raw, note_type, entity_id) {
  if (is.null(raw)) return(NULL)
  if (is.list(raw) && isTRUE(raw$timed_out)) return(NULL)
  stripped <- .strip_json_fences(as.character(raw))
  parsed <- tryCatch(
    fromJSON(stripped, simplifyVector = FALSE),
    error = function(e) {
      cli::cli_warn("[entity {entity_id}] JSON parse failed: {e$message}")
      NULL
    }
  )
  if (!.validate_entity_extraction(parsed, note_type)) {
    cli::cli_warn("[entity {entity_id}] schema validation failed \u2014 returning NULL")
    return(NULL)
  }
  parsed
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

  existing_note <- .read_vault_note(entity_id, note_type)
  existing_note_block <- if (nchar(existing_note) > 0L) {
    paste0(
      "Here is the current wiki page for ", entity_name, ". Use this as an identity anchor",
      " \u2014 the gender, role, and relationships listed here are established facts. Extract",
      " only new information from the passages below that adds to or contradicts this page.\n\n",
      "EXISTING NOTE:\n", existing_note, "\n\n---\n"
    )
  } else ""

  skill  <- .entity_skill_name(note_type)
  system <- .load_skill(skill, "system", skills_dir)
  user   <- glue(
    .load_skill(skill, "user_template", skills_dir),
    entity_name          = entity_name,
    aliases              = aliases,
    note_type            = note_type,
    recap_context        = recap_context,
    source_passages      = numbered_passages,
    existing_note_block  = existing_note_block,
    .open = "{", .close = "}"
  )

  # format=entity_schema() enforces JSON output — gemma4 reverts to markdown without it.
  # R-side parse kept as a fallback for any residual malformed output.
  # Tool calling retired (F3pre: gemma4 has no tool template in Ollama modelfile).
  raw <- ollama_generate(
    prompt        = user,
    system_prompt = system,
    model         = model,
    base_url      = base_url,
    format        = entity_schema(note_type),
    think         = FALSE
  )
  timed_out  <- is.list(raw) && isTRUE(raw$timed_out)
  extraction <- if (timed_out) NULL else .parse_entity_json(raw, note_type, entity_id)

  list(entity_id     = entity_id,
       note_type     = note_type,
       extraction    = extraction,
       timed_out     = timed_out,
       pipeline_path = "substring_grounding")
}
