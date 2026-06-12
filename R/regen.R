# Background regeneration worker.
# Runs inside a callr::r_bg() child process launched by start_regen_job().
# All dependencies (config.R, queue.R, ollama.R, claude.R, extract.R) are
# sourced by the callr wrapper before this function is called.

# Agentic entity regeneration deps (extract_entity, assemble_entity_markdown,
# fact_check_entity) are sourced by the caller: the callr worker wrapper in
# start_regen_job(), Shiny global.R, and the test setup all source them before
# regen.R. regenerate_entity_draft() below relies on them being in scope.

if (!exists("%||%", mode = "function"))
  `%||%` <- function(x, y) if (is.null(x)) y else x

# Regenerate an entity draft via the agentic entity extraction flow.
# Rebuilds an entity_record from a queue row, runs extract -> assemble ->
# fact_check, and returns the new markdown plus an agentic verdict_list.
# Returns NULL if extraction is NULL or timed out (caller handles retry/failure).
regenerate_entity_draft <- function(row, user_feedback = NULL,
                                    .queue_path = REVIEW_QUEUE_PATH) {
  passages <- strsplit(row$source_text, "\n\n---\n\n", fixed = TRUE)[[1]]
  passages <- passages[nzchar(passages)]

  episode_ids <- tryCatch(
    as.character(jsonlite::fromJSON(
      if (is.na(row$source_episode_ids)) "[]" else row$source_episode_ids)),
    error = function(e) character(0)
  )

  entity_record <- list(
    entity_id          = row$section_id,
    entity_name        = row$entity_name,
    note_type          = row$note_type,
    source_passages    = passages,
    source_episode_ids = episode_ids
  )

  res <- extract_entity(entity_record, user_feedback = user_feedback)
  if (is.null(res) || isTRUE(res$timed_out) || is.null(res$extraction)) return(NULL)

  existing <- res$existing_note %||% ""
  markdown <- assemble_entity_markdown(res$extraction, entity_record,
                                       existing_note = existing)
  fact_check <- fact_check_entity(entity_record$entity_id, markdown, passages,
                                  existing_note = existing)

  verdict_list <- list(
    verdict       = "agentic_no_critic",
    confidence    = fact_check$coverage_score,
    issues        = list(),
    source_quotes = list()
  )

  list(markdown = markdown, verdict = verdict_list, fact_check = fact_check)
}

regen_worker <- function(queue_csv_abs) {
  lock_path <- file.path(dirname(queue_csv_abs), ".regen.lock")

  on.exit({
    if (file.exists(lock_path)) file.remove(lock_path)
  }, add = TRUE)

  df    <- readr::read_csv(queue_csv_abs, show_col_types = FALSE)
  df    <- .fill_missing_columns(df)
  items <- df[df$status == "regenerating", ]

  if (nrow(items) == 0) return(invisible(0L))

  queue_dir <- dirname(queue_csv_abs)

  for (i in seq_len(nrow(items))) {
    row <- items[i, ]

    new_draft <- tryCatch({
      if (identical(row$note_type, "session") || is.na(row$note_type)) {
        generate_note(
          episode_id  = row$section_id,
          section_text = row$source_text
        )
      } else if (row$note_type %in% c("npc", "location", "faction", "pc")) {
        feedback <- if (is.na(row$user_feedback) || !nzchar(trimws(row$user_feedback)))
                      NULL else row$user_feedback
        regenerate_entity_draft(row, user_feedback = feedback)$markdown
      } else {
        warning("Unknown note_type for ", row$section_id, ": ", row$note_type)
        NULL
      }
    }, error = function(e) {
      warning("regen failed for ", row$section_id, ": ", conditionMessage(e))
      NULL
    })

    if (!is.null(new_draft) && nzchar(trimws(new_draft))) {
      update_regen_result(
        section_id  = row$section_id,
        new_draft   = new_draft,
        .queue_path = queue_dir
      )
    } else {
      # Generation failed — flip back to regen_queued so it can be retried
      df2  <- readr::read_csv(queue_csv_abs, show_col_types = FALSE)
      df2  <- .fill_missing_columns(df2)
      idx2 <- which(df2$section_id == row$section_id)
      df2$status[idx2]         <- "regen_queued"
      df2$last_action_at[idx2] <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
      readr::write_csv(df2, queue_csv_abs)
    }
  }

  invisible(nrow(items))
}
