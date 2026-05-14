# Dispatch for the agentic entity-note extraction flow (Phase 4.2).
#
# Mirrors dispatch_agentic_session() in agentic_dispatch.R. Builds a synthetic
# verdict + single-entry iteration_log (no critic loop) and enqueues the entity
# via the existing enqueue_review() path.
#
# route_verdict("agentic_no_critic", ...) already returns "enqueue" in router.R.
# No change to route_verdict is needed.

suppressPackageStartupMessages({
  library(jsonlite)
})

`%||%` <- function(x, y) if (is.null(x)) y else x

dispatch_agentic_entity <- function(markdown,
                                    entity_record,
                                    fact_check_summary,
                                    .queue_path = REVIEW_QUEUE_PATH) {
  entity_id   <- entity_record$entity_id
  entity_name <- entity_record$entity_name
  note_type   <- entity_record$note_type
  episodes    <- entity_record$source_episode_ids

  if (is.null(markdown) || !nzchar(trimws(as.character(markdown)))) {
    stop("dispatch_agentic_entity: empty markdown for entity_id=", entity_id)
  }

  confidence    <- fact_check_summary$confidence    %||% NA_real_
  n_unsupported <- fact_check_summary$n_unsupported %||% 0L

  # Surface unsupported citations as reviewer-visible issues.
  issues  <- list()
  results <- fact_check_summary$results
  if (!is.null(results) && is.data.frame(results) && nrow(results) > 0L) {
    unsup <- results[!results$supported, , drop = FALSE]
    if (nrow(unsup) > 0L) {
      issues <- lapply(seq_len(nrow(unsup)), function(i) {
        kind  <- unsup$kind[[i]]
        line  <- unsup$line[[i]]
        claim <- if ("claim" %in% names(unsup)) unsup$claim[[i]] else NA_character_
        line_label  <- if (is.na(line)) "no line cited" else paste0("line ", line)
        claim_label <- if (!is.na(claim) && nzchar(claim))
          paste0(": \"", substr(claim, 1L, 160L),
                 if (nchar(claim) > 160L) "...\"" else "\"")
        else ""
        sprintf("[%s, %s] not grounded in source%s", kind, line_label, claim_label)
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
      section_id          = entity_id,
      iteration           = 1L,
      model               = "agentic_entity_v1",
      verdict             = "agentic_no_critic",
      confidence          = confidence,
      issues_count        = as.integer(n_unsupported),
      escalated_to_claude = FALSE,
      escalation_reason   = NA,
      timestamp           = Sys.time()
    )), auto_unbox = TRUE),
    error = function(e) "[]"
  )

  ep_ids_json <- tryCatch(toJSON(episodes, auto_unbox = TRUE), error = function(e) "[]")

  action <- route_verdict(verdict_list$verdict, verdict_list$confidence)
  if (action == "skip") return(invisible(NULL))

  enqueue_review(
    draft              = markdown,
    verdict_list       = verdict_list,
    section_id         = entity_id,
    source_text        = paste(entity_record$source_passages, collapse = "\n\n---\n\n"),
    note_type          = note_type,
    entity_name        = entity_name,
    chunk_count        = length(entity_record$source_passages),
    source_episode_ids = ep_ids_json,
    iteration_count    = 1L,
    claude_used        = FALSE,
    iteration_log      = iter_log_json,
    .queue_path        = .queue_path
  )
  invisible("enqueued")
}
