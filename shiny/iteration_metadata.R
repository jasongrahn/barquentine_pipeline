# Helpers for surfacing recursive-critic-loop metadata on the review card.
# Loaded by shiny/review_queue/app.R; pure functions so they are unit-testable.

library(htmltools)
library(jsonlite)

# Walks the iteration_log JSON for the first entry with a non-empty
# escalation_reason. Returns the reason string, or NULL when none is set
# or the JSON is empty/malformed.
.parse_escalation_reason <- function(iter_log_json) {
  if (is.null(iter_log_json) ||
      (length(iter_log_json) == 1 && is.na(iter_log_json)) ||
      !nzchar(iter_log_json) || iter_log_json == "[]") {
    return(NULL)
  }
  entries <- tryCatch(fromJSON(iter_log_json, simplifyVector = FALSE),
                      error = function(e) list())
  for (e in entries) {
    r <- e$escalation_reason
    if (!is.null(r) && length(r) >= 1 && !is.na(r[[1]]) && nzchar(as.character(r[[1]])))
      return(as.character(r[[1]]))
  }
  NULL
}

# Human-readable label for an escalation_reason value.
.escalation_reason_label <- function(reason) {
  switch(as.character(reason),
    "ollama_timeout" = "timed out",
    "cap_hit"        = "cap hit",
    reason
  )
}

# Returns a tags$div with iteration metadata badges, or NULL when there is
# nothing to show (single draft, no Claude). Used in the review card UI.
.format_iteration_badges <- function(iteration_count, claude_used,
                                     iteration_log_json) {
  ic <- if (is.null(iteration_count) ||
            (length(iteration_count) == 1 && is.na(iteration_count)))
    1L else as.integer(iteration_count)
  cu <- isTRUE(as.logical(claude_used))
  reason <- .parse_escalation_reason(iteration_log_json)

  if (ic <= 1L && !cu) return(NULL)

  parts <- list()
  if (ic > 1L) {
    parts <- c(parts, list(tags$span(
      class = "iter-badge",
      sprintf("%d drafts before routing", ic)
    )))
  }
  if (cu) {
    parts <- c(parts, list(tags$span(
      class = "iter-badge claude-badge",
      "Claude revised"
    )))
  }
  if (cu && !is.null(reason)) {
    parts <- c(parts, list(tags$span(
      class = "iter-badge reason-badge",
      sprintf("(%s)", .escalation_reason_label(reason))
    )))
  }
  tags$div(class = "iter-meta", parts)
}
