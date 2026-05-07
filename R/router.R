library(jsonlite)

route_verdict <- function(verdict, confidence) {
  if (verdict == "skipped")     return("skip")
  if (verdict == "parse_error") return("enqueue")
  if (verdict == "rejected" && !is.na(confidence) && confidence >= CRITIC_REJECT_THRESHOLD)
    return("critic_reject")
  if (verdict == "rejected")    return("enqueue")

  if (verdict == "approved") {
    if (!is.na(confidence) && confidence >= CRITIC_AUTO_APPROVE_THRESHOLD)
      return("auto_approve")
    return("enqueue")
  }

  if (verdict == "flagged") {
    if (!is.na(confidence) && confidence < CRITIC_ESCALATE_THRESHOLD)
      return("escalate")
    return("enqueue")
  }

  "enqueue"
}

dispatch_note <- function(draft, verdict_list, section_id, source_text,
                          dry_run = DRY_RUN,
                          .vault_path    = VAULT_PATH,
                          .dry_run_path  = DRY_RUN_PATH,
                          .queue_path    = REVIEW_QUEUE_PATH) {
  action <- route_verdict(verdict_list$verdict, verdict_list$confidence)

  if (action == "skip") return(invisible(NULL))

  if (action == "auto_approve") {
    write_note(
      content       = draft,
      relative_path = file.path("sessions", paste0(section_id, ".md")),
      dry_run       = dry_run,
      overwrite     = TRUE,
      .vault_path   = .vault_path,
      .dry_run_path = .dry_run_path
    )
    return(invisible("auto_approved"))
  }

  if (action == "escalate") {
    enqueue_review(draft, verdict_list, section_id, source_text,
                   note_type = "session", .queue_path = .queue_path)
    return(invisible("escalated_enqueued"))
  }

  enqueue_review(draft, verdict_list, section_id, source_text,
                 note_type = "session", .queue_path = .queue_path)
  invisible("enqueued")
}

.entity_relative_path <- function(entity_id, note_type) {
  switch(note_type,
    "npc"      = file.path("npcs",      paste0(entity_id, ".md")),
    "location" = file.path("locations", paste0(entity_id, ".md")),
    "faction"  = file.path("factions",  paste0(entity_id, ".md")),
    stop("Unknown note_type: ", note_type)
  )
}

dispatch_entity_note <- function(draft, verdict_list, entity_id, entity_name,
                                  note_type, source_passages, source_episode_ids,
                                  dry_run       = DRY_RUN,
                                  .vault_path   = VAULT_PATH,
                                  .dry_run_path = DRY_RUN_PATH,
                                  .queue_path   = REVIEW_QUEUE_PATH) {
  source_text    <- paste(source_passages, collapse = "\n\n---\n\n")
  ep_ids_json    <- toJSON(source_episode_ids, auto_unbox = TRUE)

  if (is.null(draft) || !nzchar(trimws(draft))) {
    enqueue_review(
      draft              = NA_character_,
      verdict_list       = list(verdict = "generation_failed", confidence = NA_real_,
                                issues = list("Generator produced no output"),
                                source_quotes = list(), escalated = FALSE),
      section_id         = entity_id,
      source_text        = source_text,
      note_type          = note_type,
      entity_name        = entity_name,
      chunk_count        = length(source_passages),
      source_episode_ids = ep_ids_json,
      status             = "generation_failed",
      .queue_path        = .queue_path
    )
    return(invisible("generation_failed"))
  }

  action <- route_verdict(verdict_list$verdict, verdict_list$confidence)

  if (action == "skip") return(invisible(NULL))

  if (action == "critic_reject") {
    enqueue_review(draft, verdict_list, entity_id, source_text,
                   note_type = note_type, entity_name = entity_name,
                   chunk_count = length(source_passages),
                   source_episode_ids = ep_ids_json,
                   status = "critic_rejected",
                   .queue_path = .queue_path)
    return(invisible("critic_rejected"))
  }

  relative_path <- .entity_relative_path(entity_id, note_type)

  if (action == "auto_approve") {
    content <- if (note_exists(relative_path, dry_run = dry_run,
                                .vault_path   = .vault_path,
                                .dry_run_path = .dry_run_path)) {
      existing <- readLines(get_output_path(relative_path, dry_run = dry_run,
                                             .vault_path   = .vault_path,
                                             .dry_run_path = .dry_run_path),
                             warn = FALSE) |> paste(collapse = "\n")
      supplement_note(existing, draft, source_episode_ids[[1]], note_type)
    } else {
      draft
    }
    write_note(content, relative_path, dry_run = dry_run, overwrite = TRUE,
               .vault_path = .vault_path, .dry_run_path = .dry_run_path)
    return(invisible("auto_approved"))
  }

  if (action == "escalate") {
    enqueue_review(draft, verdict_list, entity_id, source_text,
                   note_type = note_type, entity_name = entity_name,
                   chunk_count = length(source_passages),
                   source_episode_ids = ep_ids_json,
                   .queue_path = .queue_path)
    return(invisible("escalated_enqueued"))
  }

  enqueue_review(draft, verdict_list, entity_id, source_text,
                 note_type = note_type, entity_name = entity_name,
                 chunk_count = length(source_passages),
                 source_episode_ids = ep_ids_json,
                 .queue_path = .queue_path)
  invisible("enqueued")
}
