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
