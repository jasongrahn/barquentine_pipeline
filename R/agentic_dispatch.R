# Dispatch for the agentic VTT extraction flow.
#
# The agentic flow does not produce a critic verdict, so dispatch_note() does
# not apply. Instead this dispatcher builds a synthetic verdict + a synthetic
# single-entry iteration_log (Q3 in
# docs/phase_agentic_extraction_integration.md) and enqueues the row via the
# existing enqueue_review() path. Routing for this row is handled by the new
# `verdict == "agentic_no_critic"` branch in R/router.R::route_verdict, which
# always returns "enqueue" — there is no auto-approve and no escalation.
#
# The queue row uses agentic_section_id("<sid>") = "<sid>__agentic" so it
# coexists with any doc-prep row for the same episode without clobbering its
# staging file.

suppressPackageStartupMessages({
  library(jsonlite)
})

dispatch_agentic_session <- function(markdown,
                                     session_id,
                                     source_text,
                                     fact_check,
                                     .queue_path = REVIEW_QUEUE_PATH) {
  if (is.null(markdown) || !nzchar(trimws(as.character(markdown))))
    stop("dispatch_agentic_session: empty markdown for ", session_id)

  confidence    <- fact_check$confidence    %||% NA_real_
  n_unsupported <- fact_check$n_unsupported %||% 0L

  # Surface unsupported line citations as issues so the reviewer can see what
  # the mechanical fact-check flagged. Without this the queue row's issues
  # column is always [] and the Shiny UI's findings panel has nothing to show.
  issues <- list()
  results <- fact_check$results
  if (!is.null(results) && is.data.frame(results) && nrow(results) > 0L) {
    unsup <- results[!results$supported, , drop = FALSE]
    if (nrow(unsup) > 0L) {
      issues <- lapply(seq_len(nrow(unsup)), function(i) {
        kind  <- unsup$kind[[i]]
        line  <- unsup$line[[i]]
        claim <- if ("claim" %in% names(unsup)) unsup$claim[[i]] else NA_character_
        line_label <- if (is.na(line)) "no line cited" else paste0("line ", line)
        claim_label <- if (!is.na(claim) && nzchar(claim))
          paste0(": \"", substr(claim, 1L, 160L),
                 if (nchar(claim) > 160L) "…\"" else "\"")
        else ""
        sprintf("[%s, %s] not grounded in source%s",
                kind, line_label, claim_label)
      })
    }
  }

  verdict_list <- list(
    verdict       = "agentic_no_critic",
    confidence    = confidence,
    issues        = issues,
    source_quotes = list(),
    escalated     = FALSE
  )

  iter_log_json <- tryCatch(
    toJSON(list(list(
      section_id          = session_id,
      iteration           = 1L,
      model               = "agentic_extraction_v1",
      verdict             = "agentic_no_critic",
      confidence          = confidence,
      issues_count        = as.integer(n_unsupported),
      escalated_to_claude = FALSE,
      escalation_reason   = NA,
      timestamp           = Sys.time()
    )), auto_unbox = TRUE),
    error = function(e) "[]"
  )

  queue_section_id <- agentic_section_id(session_id)

  action <- route_verdict(verdict_list$verdict, verdict_list$confidence)
  if (action == "skip") return(invisible(NULL))

  enqueue_review(
    draft              = markdown,
    verdict_list       = verdict_list,
    section_id         = queue_section_id,
    source_text        = source_text,
    note_type          = "session",
    iteration_count    = 1L,
    claude_used        = FALSE,
    iteration_log      = iter_log_json,
    .queue_path        = .queue_path
  )
  invisible("enqueued")
}

`%||%` <- function(x, y) if (is.null(x)) y else x
