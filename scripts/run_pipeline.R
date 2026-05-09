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
  invisible(failed)
}
