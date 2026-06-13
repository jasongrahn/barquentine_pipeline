library(jsonlite)

route_verdict <- function(verdict, confidence) {
  if (verdict == "skipped")     return("skip")
  if (verdict == "parse_error") return("enqueue")
  # Agentic VTT extraction flow (docs/phase_agentic_extraction_integration.md,
  # Q3). Pre-queue verification is the mechanical line-citation check in
  # R/agentic_fact_check.R; the critic loop is not used. Always enqueue.
  if (verdict == "agentic_no_critic") return("enqueue")
  if (verdict == "rejected" && !is.na(confidence) && confidence >= CRITIC_REJECT_THRESHOLD)
    return("critic_reject")
  if (verdict == "rejected")    return("enqueue")

  # auto_approve path disabled for Phase 0 rollout: all drafts go to human review.
  # CRITIC_AUTO_APPROVE_THRESHOLD is preserved in config for re-enablement after
  # 5 validated sessions. Do not restore this branch without explicit instruction.
  if (verdict == "approved")    return("enqueue")

  if (verdict == "flagged") {
    if (!is.na(confidence) && confidence < CRITIC_ESCALATE_THRESHOLD)
      return("escalate")
    return("enqueue")
  }

  "enqueue"
}

dispatch_note <- function(refinement_result, section_id, source_text,
                          # Legacy direct-draft args kept for backward compatibility
                          # during transition; use refinement_result going forward.
                          draft        = NULL,
                          verdict_list = NULL,
                          dry_run = DRY_RUN,
                          .vault_path    = VAULT_PATH,
                          .dry_run_path  = DRY_RUN_PATH,
                          .queue_path    = REVIEW_QUEUE_PATH) {
  # Accept either a draft_with_refinement() result list or legacy draft+verdict_list
  if (is.list(refinement_result) && "best_draft" %in% names(refinement_result)) {
    draft           <- refinement_result$best_draft
    verdict_list    <- refinement_result$final_verdict
    iteration_count <- if (is.null(refinement_result$iteration_count))
                         1L else as.integer(refinement_result$iteration_count)
    claude_used     <- isTRUE(refinement_result$claude_used)
    iter_log_json   <- tryCatch(
      toJSON(refinement_result$iteration_log, auto_unbox = TRUE),
      error = function(e) "[]"
    )
  } else {
    # Legacy path: plain draft + verdict_list (pre-Phase-0 callers)
    iteration_count <- 1L
    claude_used     <- FALSE
    iter_log_json   <- "[]"
  }

  action <- route_verdict(verdict_list$verdict, verdict_list$confidence)

  if (action == "skip") return(invisible(NULL))

  if (action == "escalate") {
    enqueue_review(draft, verdict_list, section_id, source_text,
                   note_type = "session",
                   iteration_count = iteration_count,
                   claude_used     = claude_used,
                   iteration_log   = iter_log_json,
                   .queue_path = .queue_path)
    return(invisible("escalated_enqueued"))
  }

  enqueue_review(draft, verdict_list, section_id, source_text,
                 note_type = "session",
                 iteration_count = iteration_count,
                 claude_used     = claude_used,
                 iteration_log   = iter_log_json,
                 .queue_path = .queue_path)
  invisible("enqueued")
}

dispatch_extracted_note <- function(assembled_draft, verification, section_id,
                                    source_text,
                                    note_type       = "session",
                                    entity_name     = NA_character_,
                                    dry_run         = DRY_RUN,
                                    .queue_path     = REVIEW_QUEUE_PATH) {
  verdict_list <- list(
    verdict       = verification$verdict,
    confidence    = verification$confidence,
    issues        = lapply(
      Filter(function(r) isFALSE(r$supported), verification$results),
      function(r) r$claim
    ),
    source_quotes = lapply(
      Filter(function(r) isTRUE(r$supported) && !is.na(r$quote), verification$results),
      function(r) r$quote
    )
  )

  action <- route_verdict(verdict_list$verdict, verdict_list$confidence)
  if (action == "skip") return(invisible(NULL))

  iter_log_json <- tryCatch(
    toJSON(list(list(
      section_id = section_id,
      iteration  = 1L,
      model      = "extraction_pipeline",
      verdict    = verification$verdict,
      confidence = verification$confidence,
      issues_count = verification$unsupported,
      timestamp    = Sys.time()
    )), auto_unbox = TRUE),
    error = function(e) "[]"
  )

  enqueue_review(assembled_draft, verdict_list, section_id, source_text,
                 note_type       = note_type,
                 entity_name     = entity_name,
                 iteration_count = 1L,
                 claude_used     = FALSE,
                 iteration_log   = iter_log_json,
                 .queue_path     = .queue_path)
  invisible("enqueued")
}
