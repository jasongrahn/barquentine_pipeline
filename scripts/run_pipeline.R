# Run the full pipeline with automatic retry for Ollama timeouts.
# Uses error = "continue" so a single timed-out branch doesn't block the other
# branches from dispatching and consolidating into the review queue.
# After each pass, any errored branches are retried until all succeed or
# max_retries is exhausted.
#
# Usage (from R console in project root):
#   source("scripts/run_pipeline.R")
#   run_pipeline()

# Returns the previous session ID for a zero-padded format like "s02e34".
# Returns NULL if session_id can't be parsed or if it's the first episode of
# a season (s01e01, s02e01).
.previous_session_id <- function(session_id) {
  if (is.null(session_id) || !is.character(session_id) || length(session_id) != 1L) return(NULL)
  m <- regmatches(session_id, regexec("^s(\\d+)e(\\d+)$", session_id))[[1L]]
  if (length(m) < 3L) return(NULL)
  season <- as.integer(m[[2L]])
  ep     <- as.integer(m[[3L]])
  if (ep <= 1L) return(NULL)
  sprintf("s%02de%02d", season, ep - 1L)
}

# Checks whether a session note (real or placeholder) exists in the vault for
# session_id. The session ordering guard accepts both — a placeholder is enough
# to prove "we have considered this session and confirmed there are no notes".
.session_in_vault <- function(session_id, vault_path = VAULT_PATH) {
  path <- file.path(vault_path, "sessions", paste0(session_id, ".md"))
  file.exists(path)
}

# Returns TRUE if iteration_log JSON contains an entry with
# escalation_reason == "cap_hit". Iteration logs are JSON strings produced by
# `toJSON(refinement_result$iteration_log, auto_unbox = TRUE)`.
.has_cap_hit <- function(iter_log_json) {
  if (is.null(iter_log_json) || (length(iter_log_json) == 1 && is.na(iter_log_json)) ||
      !nzchar(iter_log_json) || iter_log_json == "[]") {
    return(FALSE)
  }
  entries <- tryCatch(jsonlite::fromJSON(iter_log_json, simplifyVector = FALSE),
                      error = function(e) list())
  any(vapply(entries,
             function(e) identical(e$escalation_reason, "cap_hit"),
             logical(1L)))
}

# Aggregates pipeline metrics from queue rows enqueued during this run.
# Filters by enqueued_at timestamp >= run_start_time.
.compute_run_summary <- function(run_start_time, queue_path = REVIEW_QUEUE_PATH) {
  if (!exists("read_queue", mode = "function")) source("R/queue.R")

  empty <- list(
    sections_processed     = 0L,
    passed_first_attempt   = 0L,
    avg_iterations_flagged = NA_real_,
    hit_iteration_cap      = 0L,
    claude_escalations     = 0L,
    est_claude_cost_usd    = 0
  )

  csv_path <- file.path(queue_path, "queue.csv")
  if (!file.exists(csv_path)) return(empty)

  df <- tryCatch(
    read_queue(.queue_path = queue_path, status = NULL),
    error = function(e) NULL
  )
  if (is.null(df) || nrow(df) == 0) return(empty)

  # `enqueued_at` is written as local-time without an offset, but readr parses
  # it as UTC. Re-anchor to the local timezone so it compares apples-to-apples
  # with `run_start_time` (a local POSIXct).
  enq_str <- if (inherits(df$enqueued_at, "POSIXt"))
    format(df$enqueued_at, "%Y-%m-%dT%H:%M:%S", tz = "UTC")
  else as.character(df$enqueued_at)
  enq <- suppressWarnings(as.POSIXct(enq_str, format = "%Y-%m-%dT%H:%M:%S",
                                      tz = Sys.timezone()))
  recent <- !is.na(enq) & enq >= run_start_time
  df_run <- df[recent, , drop = FALSE]
  if (nrow(df_run) == 0) return(empty)

  iter_count  <- as.integer(df_run$iteration_count)
  iter_count[is.na(iter_count)] <- 1L
  claude_used <- isTRUE_vec(df_run$claude_used)
  verdict     <- as.character(df_run$verdict)

  cap_hit     <- claude_used & vapply(df_run$iteration_log, .has_cap_hit, logical(1L))
  flagged_idx <- verdict %in% c("flagged", "rejected")
  n_claude    <- sum(claude_used, na.rm = TRUE)

  list(
    sections_processed     = nrow(df_run),
    passed_first_attempt   = sum(iter_count == 1L & !claude_used &
                                   verdict == "approved", na.rm = TRUE),
    avg_iterations_flagged = if (sum(flagged_idx) > 0)
                               mean(iter_count[flagged_idx], na.rm = TRUE)
                             else NA_real_,
    hit_iteration_cap      = sum(cap_hit, na.rm = TRUE),
    claude_escalations     = n_claude,
    est_claude_cost_usd    = n_claude * 0.04
  )
}

# Coerce a queue column (which may be character "TRUE"/"FALSE" after CSV
# round-trip, or already logical) to a logical vector with NA → FALSE.
isTRUE_vec <- function(x) {
  v <- as.logical(x)
  v[is.na(v)] <- FALSE
  v
}

.format_run_summary <- function(s) {
  avg_str <- if (is.na(s$avg_iterations_flagged)) "\u2014"
             else sprintf("%.1f", s$avg_iterations_flagged)
  paste(
    "",
    "Run summary:",
    sprintf("  Sections processed:                %d", s$sections_processed),
    sprintf("  Passed first attempt:              %d", s$passed_first_attempt),
    sprintf("  Avg iterations (flagged sections): %s", avg_str),
    sprintf("  Hit iteration cap:                 %d", s$hit_iteration_cap),
    sprintf("  Claude escalations:                %d", s$claude_escalations),
    sprintf("  Est. Claude cost:                  $%.2f", s$est_claude_cost_usd),
    sep = "\n"
  )
}

# Hard-stop guard: when PROCESS_ONE_SESSION is TRUE, refuses to run if the
# previous session has neither a note nor a placeholder in the vault. This
# prevents the outer loop from advancing out of order.
.assert_session_ordering <- function(current_session = CURRENT_SESSION,
                                      vault_path = VAULT_PATH) {
  if (!isTRUE(PROCESS_ONE_SESSION)) return(invisible(TRUE))
  if (is.null(current_session)) return(invisible(TRUE))

  prev <- .previous_session_id(current_session)
  if (is.null(prev)) return(invisible(TRUE))  # first ep of a season

  if (!.session_in_vault(prev, vault_path)) {
    stop(sprintf(
      paste0(
        "Session ordering violation: vault is missing %s.\n",
        "Process %s before running %s, or write a placeholder if it had no notes:\n",
        "  write_placeholder_note(\"%s\")"
      ),
      prev, prev, current_session, prev
    ), call. = FALSE)
  }
  invisible(TRUE)
}

run_pipeline <- function(max_retries = 3) {
  # Ensure config globals (CURRENT_SESSION, PROCESS_ONE_SESSION, VAULT_PATH, etc.)
  # are present in the calling env. _targets.R sources config.R during tar_make(),
  # but the pre-tar_make assertions below reference these globals directly, so a
  # stale R session that predates the relevant config additions would otherwise
  # blow up before the pipeline ever starts.
  if (!exists("PROCESS_ONE_SESSION", envir = globalenv()) ||
      !exists("CURRENT_SESSION", envir = globalenv()) ||
      !exists("VAULT_PATH", envir = globalenv())) {
    sys.source("config.R", envir = globalenv())
  }

  # Auto-detect CURRENT_SESSION when not explicitly set in config.R.
  # Any non-NULL value in config.R is used as-is (explicit override).
  if (is.null(CURRENT_SESSION)) {
    if (!exists("next_unprocessed_session", mode = "function")) {
      source("R/source_b.R")
    }
    detected <- next_unprocessed_session()
    if (is.null(detected)) {
      stop("CURRENT_SESSION is NULL and next_unprocessed_session() returned NULL. ",
           "Set CURRENT_SESSION in config.R or populate the doc registry first.",
           call. = FALSE)
    }
    message(sprintf("CURRENT_SESSION auto-detected: %s", detected))
    CURRENT_SESSION <<- detected
  }

  .assert_session_ordering()

  run_start <- Sys.time()

  for (i in seq_len(max_retries)) {
    targets::tar_make()
    failed <- targets::tar_errored()
    if (length(failed) == 0) break
    message(sprintf(
      "[retry %d/%d] %d branch(es) still errored: %s",
      i, max_retries, length(failed), paste(failed, collapse = ", ")
    ))
  }
  failed <- targets::tar_errored()
  if (length(failed) > 0) {
    warning(sprintf(
      "Pipeline finished with %d unresolved error(s): %s",
      length(failed), paste(failed, collapse = ", ")
    ))
  } else {
    message("Pipeline complete — no errors.")
  }

  message(.format_run_summary(.compute_run_summary(run_start)))

  invisible(failed)
}
