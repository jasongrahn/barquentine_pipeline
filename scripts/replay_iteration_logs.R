# Recompute queue.csv `draft`, `verdict`, and `confidence` columns from the
# `iteration_log` JSON using the corrected select_best_draft() rule. No model
# calls. Backs up the original queue.csv first.
#
# `issues` and `source_quotes` columns cannot be recovered for rows produced
# before the field-rename fix — those iteration_logs were written with the
# stripping bug active, so the per-iter issue text is gone. New pipeline runs
# will populate them correctly.
#
# Run from project root:
#   source("scripts/replay_iteration_logs.R"); replay_queue()

suppressPackageStartupMessages({
  library(readr); library(jsonlite); library(dplyr)
})

source("config.R")
source("R/extract.R")
source("R/router.R")

replay_queue <- function(queue_path = "review_queue/queue.csv",
                          dry_run    = FALSE) {
  if (!file.exists(queue_path)) stop("queue not found: ", queue_path)

  df <- read_csv(queue_path, show_col_types = FALSE,
                 col_types = cols(.default = "c"))
  cat(sprintf("Loaded %d rows from %s\n", nrow(df), queue_path))

  changes <- 0L
  for (i in seq_len(nrow(df))) {
    log_json <- df$iteration_log[i]
    if (is.na(log_json) || !nzchar(log_json) || log_json == "[]") next

    parsed <- tryCatch(fromJSON(log_json, simplifyVector = FALSE),
                       error = function(e) NULL)
    if (is.null(parsed) || length(parsed) == 0L) next

    # Coerce iteration field to integer, confidence to numeric — JSON
    # round-tripping sometimes leaves them as strings.
    parsed <- lapply(parsed, function(e) {
      e$iteration    <- as.integer(e$iteration   %||% NA_integer_)
      e$confidence   <- suppressWarnings(as.numeric(e$confidence %||% NA))
      e$issues_count <- as.integer(e$issues_count %||% 0L)
      e
    })

    best <- select_best_draft(parsed)
    if (is.null(best$entry)) next

    new_draft   <- best$draft
    new_verdict <- best$entry$verdict %||% NA_character_
    new_conf    <- best$entry$confidence %||% NA_real_

    # Recompute status from the new verdict so e.g. a row whose verdict
    # flipped from rejected to flagged moves out of critic_rejected.
    # Only adjust status if it was set by the router originally — preserve
    # human-set statuses (accepted, rejected_by_user, snoozed, merged, ...).
    router_set_statuses <- c("pending", "critic_rejected", "escalated_enqueued")
    old_status   <- df$status[i] %||% ""
    new_status   <- old_status
    if (old_status %in% router_set_statuses) {
      action <- route_verdict(new_verdict, new_conf)
      new_status <- switch(action,
        critic_reject = "critic_rejected",
        escalate      = "pending",   # escalated rows still surface in queue
        enqueue       = "pending",
        old_status
      )
    }

    old_draft   <- df$draft[i]   %||% ""
    old_verdict <- df$verdict[i] %||% ""
    old_conf    <- df$confidence[i] %||% ""

    if (!identical(old_draft, new_draft) ||
        !identical(old_verdict, new_verdict) ||
        !identical(old_conf, as.character(new_conf)) ||
        !identical(old_status, new_status)) {
      changes <- changes + 1L
      cat(sprintf("  [%s] verdict %s@%s -> %s@%s | status %s -> %s | draft %d -> %d (iter %s)\n",
                  df$section_id[i],
                  old_verdict, old_conf,
                  new_verdict, new_conf,
                  old_status, new_status,
                  nchar(old_draft), nchar(new_draft),
                  best$iteration))
      df$draft[i]      <- new_draft
      df$verdict[i]    <- new_verdict
      df$confidence[i] <- as.character(new_conf)
      df$status[i]     <- new_status
    }
  }

  cat(sprintf("\nWould update %d row(s).\n", changes))

  if (dry_run) {
    cat("dry_run = TRUE — no file written.\n")
    return(invisible(df))
  }

  if (changes > 0L) {
    backup <- paste0(queue_path, ".bak.replay-", format(Sys.time(), "%Y%m%dT%H%M%S"))
    file.copy(queue_path, backup)
    cat(sprintf("Backed up original to %s\n", backup))
    write_csv(df, queue_path)
    cat(sprintf("Wrote %s\n", queue_path))
  } else {
    cat("No changes — file untouched.\n")
  }

  invisible(df)
}

# When sourced interactively, surface the function name.
if (interactive()) cat("replay_queue() ready. Try replay_queue(dry_run = TRUE) first.\n")
