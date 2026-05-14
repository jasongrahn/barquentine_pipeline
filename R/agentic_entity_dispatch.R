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

  # APS grounding shape (Phase C)
  coverage_score        <- fact_check_summary$coverage_score        %||% NA_real_
  matched_claims_vec    <- fact_check_summary$matched_claims         %||% character(0)
  unmatched_claims_vec  <- fact_check_summary$unmatched_claims       %||% character(0)
  pipeline_path_val     <- fact_check_summary$pipeline_path          %||% NA_character_
  matched_claim_count   <- length(matched_claims_vec)
  unmatched_claim_count <- length(unmatched_claims_vec)

  verdict_list <- list(
    verdict       = "agentic_no_critic",
    confidence    = coverage_score,
    issues        = list(),
    source_quotes = list(),
    escalated     = FALSE
  )

  iter_log_json <- tryCatch(
    toJSON(list(list(
      section_id          = entity_id,
      iteration           = 1L,
      model               = "agentic_entity_v1",
      verdict             = "agentic_no_critic",
      coverage_score      = coverage_score,
      pipeline_path       = pipeline_path_val,
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
    draft                 = markdown,
    verdict_list          = verdict_list,
    section_id            = entity_id,
    source_text           = paste(entity_record$source_passages, collapse = "\n\n---\n\n"),
    note_type             = note_type,
    entity_name           = entity_name,
    chunk_count           = length(entity_record$source_passages),
    source_episode_ids    = ep_ids_json,
    iteration_count       = 1L,
    claude_used           = FALSE,
    iteration_log         = iter_log_json,
    coverage_score        = coverage_score,
    matched_claim_count   = as.integer(matched_claim_count),
    unmatched_claim_count = as.integer(unmatched_claim_count),
    pipeline_path         = pipeline_path_val,
    matched_claims        = tryCatch(toJSON(matched_claims_vec, auto_unbox = FALSE),
                                     error = function(e) NA_character_),
    unmatched_claims      = tryCatch(toJSON(unmatched_claims_vec, auto_unbox = FALSE),
                                     error = function(e) NA_character_),
    .queue_path           = .queue_path
  )
  invisible("enqueued")
}
