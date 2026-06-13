# Background regeneration worker.
# Runs inside a callr::r_bg() child process launched by start_regen_job().
# Core dependencies (config.R, queue.R, ollama.R) plus the agentic entity flow
# (agentic_extract.R, agentic_entity_schemas.R, agentic_entity_extract.R,
# agentic_entity_writer.R, agentic_entity_fact_check.R, postprocess_shared.R,
# agentic_postprocess.R, source_c.R) are sourced by the callr wrapper before
# this function is called.

# Agentic entity regeneration deps (extract_entity, assemble_entity_markdown,
# fact_check_entity) are sourced by the caller: the callr worker wrapper in
# start_regen_job(), Shiny global.R, and the test setup all source them before
# regen.R. regenerate_entity_draft() below relies on them being in scope.

if (!exists("%||%", mode = "function"))
  `%||%` <- function(x, y) if (is.null(x)) y else x

# Regenerate an entity draft via the agentic entity extraction flow.
# Rebuilds an entity_record from a queue row, runs extract -> assemble ->
# fact_check, and returns the new markdown plus an agentic verdict_list.
# Returns NULL if extraction is NULL or timed out (caller handles retry/failure).
regenerate_entity_draft <- function(row, user_feedback = NULL) {
  passages <- strsplit(row$source_text, "\n\n---\n\n", fixed = TRUE)[[1]]
  passages <- passages[nzchar(passages)]

  episode_ids <- tryCatch(
    as.character(jsonlite::fromJSON(
      if (is.na(row$source_episode_ids)) "[]" else row$source_episode_ids)),
    error = function(e) character(0)
  )

  entity_record <- list(
    entity_id          = row$section_id,
    entity_name        = row$entity_name,
    note_type          = row$note_type,
    source_passages    = passages,
    source_episode_ids = episode_ids
  )

  res <- extract_entity(entity_record, user_feedback = user_feedback)
  if (is.null(res) || isTRUE(res$timed_out) || is.null(res$extraction)) return(NULL)

  existing <- res$existing_note %||% ""
  markdown <- assemble_entity_markdown(res$extraction, entity_record,
                                       existing_note = existing)
  fact_check <- fact_check_entity(entity_record$entity_id, markdown, passages,
                                  existing_note = existing)

  verdict_list <- list(
    verdict       = "agentic_no_critic",
    confidence    = fact_check$coverage_score,
    issues        = list(),
    source_quotes = list()
  )

  list(markdown = markdown, verdict = verdict_list, fact_check = fact_check)
}

# Regenerate a session draft via the agentic chunk pipeline.
# Re-runs the full per-session extraction (it needs vtt_meta + merged
# extractions that the queue row does not store): recover the base episode id,
# resolve the VTT path from the registry, then run preprocess -> per-chunk
# extract -> merge -> postprocess -> synthesize -> assemble -> fact-check.
# Returns the new markdown plus an agentic verdict_list shaped like
# dispatch_agentic_session(). Mirrors _targets.R:336-520.
# Dependencies (preprocess_vtt_for_extraction, extract_chunk,
# merge_chunk_extractions, postprocess_extracted, synthesize_session_recap,
# assemble_session_markdown, verify_line_citations, strip_agentic_suffix,
# load_vtt_registry) are sourced by the caller; see start_regen_job() and
# Shiny global.R.
regenerate_session_draft <- function(section_id) {
  base <- strip_agentic_suffix(section_id)

  registry <- load_vtt_registry()
  reg_row  <- registry[registry$episode_id == base, , drop = FALSE]
  if (nrow(reg_row) == 0L)
    stop("regenerate_session_draft: no VTT registry row for episode ", base)

  vtt_path <- file.path(NAS_MOUNT, reg_row$filename[[1]])
  if (!file.exists(vtt_path))
    stop("regenerate_session_draft: VTT file not found: ", vtt_path)

  vtt <- preprocess_vtt_for_extraction(vtt_path,
                                       chunk_size = AGENTIC_CHUNK_SIZE_LINES)

  chunks <- vtt$chunks
  per_chunk <- lapply(seq_len(nrow(chunks)), function(i) {
    extract_chunk(
      chunk_row     = chunks[i, ],
      recap_context = vtt$recap_context,
      chunk_id      = i,
      model         = OLLAMA_MODEL,
      base_url      = OLLAMA_BASE_URL
    )
  })

  merged <- merge_chunk_extractions(per_chunk,
                                    dialogue_keep_n = AGENTIC_DIALOGUE_KEEP_N)
  merged <- postprocess_extracted(
    merged,
    protected_path = PROTECTED_ENTITIES_PATH,
    aliases_path   = ENTITY_ALIASES_PATH,
    event_keep_n   = AGENTIC_EVENT_KEEP_N
  )

  synth <- synthesize_session_recap(merged    = merged,
                                    vtt_meta  = vtt,
                                    model     = OLLAMA_MODEL,
                                    base_url  = OLLAMA_BASE_URL)
  markdown <- assemble_session_markdown(synthesis = synth,
                                        merged    = merged,
                                        vtt_meta  = vtt)
  fact_check <- verify_line_citations(merged, vtt)

  # Surface unsupported line citations as issue strings — same shaping as
  # dispatch_agentic_session().
  issues  <- list()
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
        sprintf("[%s, %s] not grounded in source%s", kind, line_label, claim_label)
      })
    }
  }

  verdict_list <- list(
    verdict       = "agentic_no_critic",
    confidence    = fact_check$confidence %||% NA_real_,
    issues        = issues,
    source_quotes = list()
  )

  list(markdown = markdown, verdict = verdict_list, fact_check = fact_check)
}

regen_worker <- function(queue_csv_abs) {
  lock_path <- file.path(dirname(queue_csv_abs), ".regen.lock")

  on.exit({
    if (file.exists(lock_path)) file.remove(lock_path)
  }, add = TRUE)

  df    <- readr::read_csv(queue_csv_abs, show_col_types = FALSE)
  df    <- .fill_missing_columns(df)
  items <- df[df$status == "regenerating", ]

  if (nrow(items) == 0) return(invisible(0L))

  queue_dir <- dirname(queue_csv_abs)

  for (i in seq_len(nrow(items))) {
    row <- items[i, ]

    new_draft <- tryCatch({
      if (identical(row$note_type, "session") || is.na(row$note_type)) {
        regenerate_session_draft(row$section_id)$markdown
      } else if (row$note_type %in% c("npc", "location", "faction", "pc")) {
        feedback <- if (is.na(row$user_feedback) || !nzchar(trimws(row$user_feedback)))
                      NULL else row$user_feedback
        regenerate_entity_draft(row, user_feedback = feedback)$markdown
      } else {
        warning("Unknown note_type for ", row$section_id, ": ", row$note_type)
        NULL
      }
    }, error = function(e) {
      warning("regen failed for ", row$section_id, ": ", conditionMessage(e))
      NULL
    })

    if (!is.null(new_draft) && nzchar(trimws(new_draft))) {
      update_regen_result(
        section_id  = row$section_id,
        new_draft   = new_draft,
        .queue_path = queue_dir
      )
    } else {
      # Generation failed — flip back to regen_queued so it can be retried
      df2  <- readr::read_csv(queue_csv_abs, show_col_types = FALSE)
      df2  <- .fill_missing_columns(df2)
      idx2 <- which(df2$section_id == row$section_id)
      df2$status[idx2]         <- "regen_queued"
      df2$last_action_at[idx2] <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
      readr::write_csv(df2, queue_csv_abs)
    }
  }

  invisible(nrow(items))
}
