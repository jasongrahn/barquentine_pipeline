# Background regeneration worker.
# Runs inside a callr::r_bg() child process launched by start_regen_job().
# All dependencies (config.R, queue.R, ollama.R, claude.R, extract.R) are
# sourced by the callr wrapper before this function is called.

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
      } else if (row$note_type %in% c("npc", "location", "faction")) {
        critic_findings <- tryCatch(
          jsonlite::fromJSON(if (is.na(row$issues)) "[]" else row$issues,
                             simplifyVector = FALSE),
          error = function(e) list()
        )
        feedback <- if (is.na(row$user_feedback) || !nzchar(trimws(row$user_feedback)))
                      NULL else row$user_feedback
        # Source passages were joined with "\n\n---\n\n" at enqueue time
        passages <- strsplit(row$source_text, "\n\n---\n\n", fixed = TRUE)[[1]]
        generate_entity_note(
          entity_name     = row$entity_name,
          source_passages = passages,
          note_type       = row$note_type,
          prior_draft     = if (is.na(row$existing_note)) NULL else row$existing_note,
          critic_findings = critic_findings,
          user_feedback   = feedback
        )
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
