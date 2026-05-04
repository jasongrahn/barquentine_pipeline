route_verdict <- function(verdict, confidence) {
  if (verdict == "skipped")     return("skip")
  if (verdict == "parse_error") return("enqueue")
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
    prompt     <- .build_critic_prompt(draft, source_text)
    claude_raw <- claude_generate_note(prompt, CRITIC_SYSTEM_PROMPT)
    claude_verdict <- parse_critic_response(claude_raw)

    # Append Claude's verdict to issues so reviewer sees both opinions
    combined_verdict <- verdict_list
    combined_verdict$escalated     <- TRUE
    combined_verdict$claude_verdict <- claude_verdict$verdict
    combined_verdict$issues <- c(
      verdict_list$issues,
      paste0("[Claude] ", unlist(claude_verdict$issues))
    )

    if (claude_verdict$verdict == "approved") {
      write_note(
        content       = draft,
        relative_path = file.path("sessions", paste0(section_id, ".md")),
        dry_run       = dry_run,
        overwrite     = TRUE,
        .vault_path   = .vault_path,
        .dry_run_path = .dry_run_path
      )
      return(invisible("escalated_approved"))
    }

    enqueue_review(draft, combined_verdict, section_id, source_text,
                   .queue_path = .queue_path)
    return(invisible("escalated_enqueued"))
  }

  # action == "enqueue"
  enqueue_review(draft, verdict_list, section_id, source_text,
                 .queue_path = .queue_path)
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
  action        <- route_verdict(verdict_list$verdict, verdict_list$confidence)
  relative_path <- .entity_relative_path(entity_id, note_type)
  source_text   <- paste(source_passages, collapse = "\n\n---\n\n")

  if (action == "skip") return(invisible(NULL))

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
    prompt         <- .build_critic_prompt(draft, source_text)
    claude_raw     <- claude_generate_note(prompt, CRITIC_SYSTEM_PROMPT)
    claude_verdict <- parse_critic_response(claude_raw)

    combined_verdict <- verdict_list
    combined_verdict$escalated      <- TRUE
    combined_verdict$claude_verdict <- claude_verdict$verdict
    combined_verdict$issues <- c(
      verdict_list$issues,
      paste0("[Claude] ", unlist(claude_verdict$issues))
    )

    if (claude_verdict$verdict == "approved") {
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
      return(invisible("escalated_approved"))
    }

    enqueue_review(draft, combined_verdict, entity_id, source_text,
                   .queue_path = .queue_path)
    return(invisible("escalated_enqueued"))
  }

  # action == "enqueue"
  enqueue_review(draft, verdict_list, entity_id, source_text,
                 .queue_path = .queue_path)
  invisible("enqueued")
}
