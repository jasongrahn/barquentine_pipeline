# Agentic entity-note markdown assembly (Phase 4.2).
#
# Pure R string assembly — no LLM calls. Mirrors the R-frontloaded approach of
# agentic_extract.R::assemble_session_markdown(). One public entry point
# dispatches to per-type private assemblers.
#
# Reuses .fmt_yaml_list() from agentic_extract.R.

suppressPackageStartupMessages({
  library(readr)
})

if (!exists(".fmt_yaml_list", mode = "function")) {
  src_dir <- tryCatch(dirname(normalizePath(sys.frame(1L)$ofile)),
                      error = function(e) "R")
  source(file.path(src_dir, "agentic_extract.R"), local = FALSE)
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

.load_played_by <- function(entity_id,
                             protected_path = PROTECTED_ENTITIES_PATH) {
  if (!file.exists(protected_path)) return(NA_character_)
  df <- tryCatch(read_csv(protected_path, show_col_types = FALSE),
                 error = function(e) NULL)
  if (is.null(df)) return(NA_character_)
  row <- df[!is.na(df$slug) & df$slug == entity_id, ]
  if (nrow(row) == 0L || !"played_by" %in% names(row)) return(NA_character_)
  val <- row$played_by[[1L]]
  if (is.na(val) || !nzchar(trimws(val))) NA_character_ else trimws(val)
}

# Returns the string value of a {value, line} field, or NULL if value is null/NA.
.get_value <- function(field) {
  if (is.null(field)) return(NULL)
  v <- if (is.list(field)) field$value else NULL
  if (is.null(v) || is.na(v) || !nzchar(trimws(v))) NULL else trimws(v)
}

# Format an array of {name, line} or {value, line} or {feature, line} items
# as a markdown bulleted list. Returns NULL if the array is empty/null.
.fmt_item_list <- function(items, value_col = "name") {
  if (is.null(items)) return(NULL)
  if (is.data.frame(items)) {
    if (nrow(items) == 0L || !value_col %in% names(items)) return(NULL)
    vals <- items[[value_col]]
    vals <- vals[!is.na(vals) & nzchar(trimws(vals))]
    if (length(vals) == 0L) return(NULL)
    return(paste0("- ", vals, collapse = "\n"))
  }
  if (is.list(items) && length(items) > 0L) {
    vals <- vapply(items, function(x) {
      v <- if (is.list(x)) x[[value_col]] else NA_character_
      if (is.null(v) || is.na(v) || !nzchar(trimws(v))) NA_character_ else trimws(v)
    }, character(1L))
    vals <- vals[!is.na(vals)]
    if (length(vals) == 0L) return(NULL)
    return(paste0("- ", vals, collapse = "\n"))
  }
  NULL
}

# Build the YAML frontmatter block.
.entity_frontmatter <- function(entity_id, note_type, aliases, source_episodes,
                                 played_by = NA_character_) {
  tag <- if (note_type == "pc") "pc" else note_type  # npc/location/faction as-is
  lines <- c(
    "---",
    sprintf("tags: [%s]", tag),
    sprintf("slug: %s", entity_id)
  )

  if (length(aliases) > 0L && any(nzchar(aliases))) {
    lines <- c(lines, "aliases:", paste0("  - ", aliases[nzchar(aliases)]))
  } else {
    lines <- c(lines, "aliases: []")
  }

  if (!is.na(played_by) && nzchar(played_by))
    lines <- c(lines, sprintf("played_by: %s", played_by))

  lines <- c(lines, "review_required: true")

  if (length(source_episodes) > 0L)
    lines <- c(lines, "source:", paste0("  - ", source_episodes))

  c(lines, "---")
}

# ---------------------------------------------------------------------------
# Per-type assemblers (private)
# ---------------------------------------------------------------------------

.assemble_pc_markdown <- function(extraction, entity_record, vtt_meta) {
  entity_id  <- entity_record$entity_id
  note_type  <- entity_record$note_type
  episodes   <- unique(entity_record$source_episode_ids)
  played_by  <- .load_played_by(entity_id)

  aliases <- if (!is.null(extraction$aliases) && length(extraction$aliases) > 0L)
    as.character(extraction$aliases) else character(0)

  fm <- .entity_frontmatter(entity_id, note_type, aliases, episodes, played_by)
  body <- character(0)

  # Overview — bio + description
  bio  <- .get_value(extraction$bio)
  desc <- .get_value(extraction$description)
  if (!is.null(bio) || !is.null(desc)) {
    body <- c(body, "## Overview", "")
    if (!is.null(bio))  body <- c(body, bio,  "")
    if (!is.null(desc)) body <- c(body, desc, "")
  }

  # Personality
  pers <- .get_value(extraction$exhibited_personality)
  if (!is.null(pers))
    body <- c(body, "## Personality", "", pers, "")

  # Role in Story
  role <- .get_value(extraction$role_in_story)
  if (!is.null(role))
    body <- c(body, "## Role in Story", "", role, "")

  # Relationships
  rel_list  <- .fmt_item_list(extraction$relatives, "name")
  affl_list <- .fmt_item_list(extraction$affiliations, "name")
  if (!is.null(rel_list) || !is.null(affl_list)) {
    body <- c(body, "## Relationships", "")
    if (!is.null(rel_list))  body <- c(body, rel_list,  "")
    if (!is.null(affl_list)) body <- c(body, affl_list, "")
  }

  # Alignment
  aln <- .get_value(extraction$alignment)
  if (!is.null(aln))
    body <- c(body, "## Alignment", "", aln, "")

  paste(c(fm, "", body), collapse = "\n")
}

.assemble_npc_markdown <- function(extraction, entity_record, vtt_meta) {
  entity_id <- entity_record$entity_id
  note_type <- entity_record$note_type
  episodes  <- unique(entity_record$source_episode_ids)

  aliases <- if (!is.null(extraction$aliases) && length(extraction$aliases) > 0L)
    as.character(extraction$aliases) else character(0)

  fm   <- .entity_frontmatter(entity_id, note_type, aliases, episodes)
  body <- character(0)

  desc <- .get_value(extraction$description)
  role <- .get_value(extraction$role_in_story)
  if (!is.null(desc) || !is.null(role)) {
    body <- c(body, "## Overview", "")
    if (!is.null(desc)) body <- c(body, desc, "")
    if (!is.null(role)) body <- c(body, role, "")
  }

  pers <- .get_value(extraction$exhibited_personality)
  if (!is.null(pers))
    body <- c(body, "## Personality", "", pers, "")

  affl_list <- .fmt_item_list(extraction$affiliations, "name")
  if (!is.null(affl_list))
    body <- c(body, "## Affiliations", "", affl_list, "")

  paste(c(fm, "", body), collapse = "\n")
}

.assemble_location_markdown <- function(extraction, entity_record, vtt_meta) {
  entity_id <- entity_record$entity_id
  note_type <- entity_record$note_type
  episodes  <- unique(entity_record$source_episode_ids)

  fm   <- .entity_frontmatter(entity_id, note_type, character(0), episodes)
  body <- character(0)

  desc <- .get_value(extraction$description)
  if (!is.null(desc))
    body <- c(body, "## Description", "", desc, "")

  region <- .get_value(extraction$region)
  if (!is.null(region))
    body <- c(body, "## Region", "", region, "")

  feat_list <- .fmt_item_list(extraction$notable_features, "feature")
  if (!is.null(feat_list))
    body <- c(body, "## Notable Features", "", feat_list, "")

  event_list <- .fmt_item_list(extraction$events_witnessed, "event")
  if (!is.null(event_list))
    body <- c(body, "## Events", "", event_list, "")

  if (!is.null(extraction$connections) && length(extraction$connections) > 0L) {
    conns <- as.character(extraction$connections)
    conns <- conns[!is.na(conns) & nzchar(conns)]
    if (length(conns) > 0L)
      body <- c(body, "## Connections", "", paste0("- ", conns, collapse = "\n"), "")
  }

  paste(c(fm, "", body), collapse = "\n")
}

.assemble_faction_markdown <- function(extraction, entity_record, vtt_meta) {
  entity_id <- entity_record$entity_id
  note_type <- entity_record$note_type
  episodes  <- unique(entity_record$source_episode_ids)

  fm   <- .entity_frontmatter(entity_id, note_type, character(0), episodes)
  body <- character(0)

  desc <- .get_value(extraction$description)
  if (!is.null(desc))
    body <- c(body, "## Overview", "", desc, "")

  goals_list <- .fmt_item_list(extraction$goals, "value")
  if (!is.null(goals_list))
    body <- c(body, "## Goals", "", goals_list, "")

  members_list <- .fmt_item_list(extraction$known_members, "name")
  if (!is.null(members_list))
    body <- c(body, "## Known Members", "", members_list, "")

  for (grp in list(list(field = "allies", heading = "## Allies"),
                   list(field = "enemies", heading = "## Enemies"))) {
    vals <- extraction[[grp$field]]
    if (!is.null(vals) && length(vals) > 0L) {
      vals <- as.character(vals)
      vals <- vals[!is.na(vals) & nzchar(vals)]
      if (length(vals) > 0L)
        body <- c(body, grp$heading, "", paste0("- ", vals, collapse = "\n"), "")
    }
  }

  paste(c(fm, "", body), collapse = "\n")
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

#' Assemble entity wiki markdown from a schema-extraction result.
#'
#' @param extraction   Parsed R list from extract_entity()$extraction.
#' @param entity_record  Named list with entity_id, note_type, source_episode_ids.
#' @param vtt_meta     Optional VTT metadata (unused in Phase 0; reserved for
#'   future escalation context).
#'
#' @return Character string — the full markdown content for the entity wiki page.
assemble_entity_markdown <- function(extraction, entity_record, vtt_meta = NULL) {
  if (is.null(extraction))
    return(sprintf("---\nslug: %s\nreview_required: true\n---\n\n_(extraction failed)_\n",
                   entity_record$entity_id))

  switch(entity_record$note_type,
    pc       = .assemble_pc_markdown(extraction, entity_record, vtt_meta),
    npc      = .assemble_npc_markdown(extraction, entity_record, vtt_meta),
    location = .assemble_location_markdown(extraction, entity_record, vtt_meta),
    faction  = .assemble_faction_markdown(extraction, entity_record, vtt_meta),
    stop("Unknown note_type for entity assembly: ", entity_record$note_type)
  )
}
