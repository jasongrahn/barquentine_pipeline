library(glue)

# --- PC alias table (hardcoded from protected_entities.csv) -------------------

.PC_ALIASES <- list(
  "Room"        = list(slug = "Room",  display = NULL),
  "Lumi"        = list(slug = "Lumi",  display = NULL),
  "The Admiral" = list(slug = "The Admiral", display = NULL),
  "the Admiral" = list(slug = "The Admiral", display = "the Admiral"),
  "Basil"       = list(slug = "Basil", display = "the Captain"),
  "Captain"     = list(slug = "Basil", display = "the Captain"),
  "the Captain" = list(slug = "Basil", display = "the Captain"),
  "The Captain" = list(slug = "Basil", display = "the Captain")
)

# --- Helpers ------------------------------------------------------------------

.wikify_name <- function(name) {
  if (is.null(name) || length(name) == 0) return("")
  if (is.na(name) || !nzchar(trimws(name))) return("")
  if (grepl("[[", name, fixed = TRUE)) return(name)

  entry <- .PC_ALIASES[[name]]
  if (!is.null(entry)) {
    if (is.null(entry$display)) {
      return(paste0("[[", entry$slug, "]]"))
    }
    return(paste0("[[", entry$slug, "|", entry$display, "]]"))
  }

  paste0("[[", name, "]]")
}

.format_event_line <- function(event) {
  desc <- event$description %||% ""
  chars <- event$characters_involved
  loc <- event$location

  char_part <- ""
  if (!is.null(chars) && length(chars) > 0) {
    wikified <- vapply(chars, .wikify_name, character(1))
    wikified <- wikified[nzchar(wikified)]
    if (length(wikified) > 0) {
      char_part <- paste0(" (", paste(wikified, collapse = ", "), ")")
    }
  }

  loc_part <- ""
  if (!is.null(loc) && !is.na(loc) && nzchar(trimws(loc))) {
    loc_part <- paste0(" — ", .wikify_name(loc))
  }

  paste0("- ", desc, char_part, loc_part)
}

.build_summary <- function(events) {
  if (is.null(events) || length(events) == 0) return("")

  n <- min(3, length(events))
  descs <- vapply(events[seq_len(n)], function(e) e$description %||% "", character(1))
  descs <- descs[nzchar(descs)]
  if (length(descs) == 0) return("")

  summary <- paste(descs, collapse = ". ")
  if (!grepl("\\.$", summary)) summary <- paste0(summary, ".")
  summary
}

`%||%` <- function(x, y) if (!is.null(x)) x else y

# --- Session note assembly ----------------------------------------------------

assemble_session_note <- function(episode_id, facts, story_so_far = NULL) {
  has_events <- !is.null(facts$events) && length(facts$events) > 0
  review_required <- if (has_events) "false" else "true"

  frontmatter <- glue(
    "---",
    "tags: [session]",
    "episode: {episode_id}",
    "title: ",
    "date_played: ",
    "source: prep_notes",
    "review_required: {review_required}",
    "---",
    .sep = "\n"
  )

  summary_text <- .build_summary(facts$events)

  if (has_events) {
    event_lines <- vapply(facts$events, .format_event_line, character(1))
    events_section <- paste(event_lines, collapse = "\n")
  } else {
    events_section <- "-"
  }

  has_npcs <- !is.null(facts$npcs) && length(facts$npcs) > 0
  if (has_npcs) {
    npc_lines <- vapply(facts$npcs, function(npc) {
      name <- .wikify_name(npc$name %||% "")
      action <- if (!is.null(npc$actions) && length(npc$actions) > 0) npc$actions[[1]] else ""
      if (nzchar(action)) {
        paste0("- ", name, " — ", action)
      } else {
        paste0("- ", name)
      }
    }, character(1))
    npcs_section <- paste(npc_lines, collapse = "\n")
  } else {
    npcs_section <- "-"
  }

  has_locations <- !is.null(facts$locations) && length(facts$locations) > 0
  if (has_locations) {
    loc_lines <- vapply(facts$locations, function(loc) {
      name <- .wikify_name(loc$name %||% "")
      desc <- loc$description %||% ""
      if (nzchar(desc)) {
        paste0("- ", name, " — ", desc)
      } else {
        paste0("- ", name)
      }
    }, character(1))
    locations_section <- paste(loc_lines, collapse = "\n")
  } else {
    locations_section <- "-"
  }

  has_threads <- !is.null(facts$threads) && length(facts$threads) > 0
  if (has_threads) {
    thread_lines <- vapply(facts$threads, function(th) {
      desc <- th$description %||% ""
      chars <- th$related_characters
      if (!is.null(chars) && length(chars) > 0) {
        wikified <- vapply(chars, .wikify_name, character(1))
        wikified <- wikified[nzchar(wikified)]
        if (length(wikified) > 0) {
          return(paste0("- ", desc, " (", paste(wikified, collapse = ", "), ")"))
        }
      }
      paste0("- ", desc)
    }, character(1))
    threads_section <- paste(thread_lines, collapse = "\n")
  } else {
    threads_section <- "-"
  }

  paste(
    frontmatter,
    "",
    "## Summary",
    summary_text,
    "",
    "## Key Events",
    events_section,
    "",
    "## NPCs Present",
    npcs_section,
    "",
    "## Locations",
    locations_section,
    "",
    "## Items / Artifacts",
    "-",
    "",
    "## Open Threads",
    threads_section,
    "",
    "## GM Notes",
    "",
    sep = "\n"
  )
}
