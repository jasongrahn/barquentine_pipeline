library(targets)
library(tarchetypes)

tar_option_set(
  packages = c("httr2", "googledrive", "jsonlite", "readr",
               "stringr", "purrr", "fs", "gert", "glue", "yaml", "dplyr"),
  error = "continue"
)

source("config.R")
source("R/gdrive.R")
source("R/source_b.R")
source("R/source_c.R")
source("R/ollama.R")
source("R/claude.R")
source("R/extract.R")
source("R/extract_facts.R")
source("R/assemble.R")
source("R/fact_critic.R")
source("R/critic.R")
source("R/router.R")
source("R/story.R")
source("R/queue.R")
source("R/wikilinks.R")
source("R/writer.R")
source("R/merge.R")
source("R/review.R")
source("R/git_commit.R")
source("R/postprocess_shared.R")
source("R/agentic_postprocess.R")
source("R/agentic_extract.R")
source("R/agentic_fact_check.R")
source("R/agentic_writer.R")
source("R/agentic_dispatch.R")
source("R/agentic_entity_schemas.R")
source("R/agentic_entity_extract.R")
source("R/agentic_entity_writer.R")
source("R/agentic_entity_fact_check.R")
source("R/agentic_entity_dispatch.R")

list(

  # --- Source B: scan Drive folder, fetch all unprocessed episode docs --------
  # The fetch updates the registry cache for everything new in the folder, but
  # only the current session's sections feed the inner loop (one-session-at-a-time
  # rollout per docs/recursive_critic_loop_design.md "Strict session ordering").
  tar_target(doc_registry_file, DOC_REGISTRY_PATH, format = "file"),

  tar_target(source_b_sections_all,
             fetch_all_episode_docs(EPISODE_NOTES_FOLDER_ID,
                                    doc_registry_file,
                                    VAULT_PATH),
             format = "rds"),

  tar_target(source_b_sections,
             source_b_sections_all[names(source_b_sections_all) == CURRENT_SESSION]),

  tar_target(section_ids, names(source_b_sections)),

  # --- Alias registry — scanned from vault at pipeline start -----------------
  # format = "file" tracks entity_aliases.csv hash so alias changes invalidate
  # alias_registry and all downstream entity targets automatically.
  tar_target(entity_aliases_file, ENTITY_ALIASES_PATH, format = "file"),
  tar_target(alias_registry, build_alias_registry(VAULT_PATH, entity_aliases_file)),

  # --- Few-shot examples — invalidates generator when sft.jsonl changes ------
  # format = "file" tracks the file hash; downstream targets re-run when
  # Shiny appends new accepted pairs. File is created empty on first run so
  # the target always has a valid path to return.
  tar_target(
    sft_example_files,
    {
      p <- file.path(TRAINING_DATA_PATH, "sft.jsonl")
      if (!file.exists(p)) {
        dir.create(TRAINING_DATA_PATH, showWarnings = FALSE, recursive = TRUE)
        file.create(p)
      }
      p
    },
    format = "file"
  ),

  # --- Story So Far — campaign context for the current session generation ---
  # Reads the highest-numbered snapshot prior to CURRENT_SESSION (or NULL if
  # no snapshot exists yet). Generator uses this to avoid contradicting prior
  # established facts. Updated post-session via update_story_so_far().
  tar_target(
    story_so_far_context,
    read_story_so_far(CURRENT_SESSION, VAULT_PATH)
  ),

  # --- Session notes — extraction pipeline -----------------------------------
  # Decomposed approach: schema-enforced extraction → R template assembly →
  # fact-level verification. Iterates inside the target (not pattern = map())
  # so an empty source_b_sections produces an empty list instead of crashing
  # the DAG with "cannot branch over empty target".
  tar_target(
    dispatched,
    {
      ids <- names(source_b_sections)
      if (length(ids) == 0L) return(invisible(NULL))

      lapply(ids, function(sid) {
        src   <- source_b_sections[[sid]]
        facts <- extract_session_facts(src)
        draft <- assemble_session_note(sid, facts,
                                       story_so_far = story_so_far_context)
        verification <- verify_facts(facts, src)
        dispatch_extracted_note(draft, verification, sid, src,
                                note_type = "session")
      })
    }
  ),

  # --- Consolidate staging files into queue.csv (sequential) ----------------
  tar_target(
    queue_consolidated,
    {
      dispatched
      consolidate_queue()
    }
  ),

  # --- Run header in review log — after all notes are written ---------------
  tar_target(
    review_header,
    {
      queue_consolidated
      write_run_header(CURRENT_SESSION)
    }
  ),

  # --- Git commit — after notes and review log are written ------------------
  tar_target(
    vault_committed,
    {
      review_header
      commit_vault(CURRENT_SESSION)
    }
  ),

  # --- Phase 3: Source C (VTT) -----------------------------------------------

  # Registry CSV path — format="file" tracks the file hash
  tar_target(
    vtt_registry_path,
    "config/vtt_registry.csv",
    format = "file"
  ),

  # Entity exclusions — DM narrator role tags that must never become vault notes
  tar_target(
    entity_exclusions_path,
    ENTITY_EXCLUSIONS_PATH,
    format = "file"
  ),
  tar_target(
    entity_exclusions,
    load_entity_exclusions(entity_exclusions_path)
  ),

  # Protected entities — known PCs/key NPCs that bypass the frequency filter
  tar_target(
    protected_entities_path,
    PROTECTED_ENTITIES_PATH,
    format = "file"
  ),
  tar_target(
    protected_slugs,
    load_protected_slugs(protected_entities_path)
  ),
  # Excluded entity slugs — PCs and player real names that must never become notes
  tar_target(
    excluded_protected_slugs,
    load_excluded_entity_slugs(protected_entities_path)
  ),

  # Parsed registry — re-runs when the CSV content changes
  tar_target(
    vtt_registry,
    load_vtt_registry(vtt_registry_path)
  ),

  # Scope the VTT phase to CURRENT_SESSION (one-session-at-a-time rollout).
  # Empty result is fine — downstream pattern = map() collapses to 0 branches.
  tar_target(
    vtt_registry_for_current,
    vtt_registry[vtt_registry$episode_id == CURRENT_SESSION, , drop = FALSE]
  ),

  # VTT file paths — one per current-session registry row
  tar_target(
    vtt_file_paths,
    file.path(NAS_MOUNT, vtt_registry_for_current$filename)
  ),

  # Episode IDs aligned with vtt_file_paths (same row order)
  tar_target(
    vtt_episode_ids,
    vtt_registry_for_current$episode_id
  ),

  # Entity spotting — one result per VTT file (OLLAMA_CRITIC_MODEL + JSON Schema).
  # Iterates inside the target instead of using pattern = map() so that an empty
  # vtt_file_paths (e.g. CURRENT_SESSION has no VTT) produces an empty list
  # rather than failing the DAG with "cannot branch over empty target".
  tar_target(
    vtt_entities,
    if (length(vtt_file_paths) == 0L) list()
    else lapply(seq_along(vtt_file_paths), function(i) {
      process_vtt_file(vtt_file_paths[i], vtt_episode_ids[i])
    })
  ),

  # Aggregate passages per entity across all VTT files.
  # Returns list(NULL) sentinel when no entities pass the frequency threshold
  # so downstream pattern = map() targets have at least one branch to declare.
  tar_target(
    entity_passages,
    {
      result <- aggregate_entity_passages(vtt_entities, alias_registry,
                                          exclusion_slugs = c(entity_exclusions, excluded_protected_slugs),
                                          protected_slugs = protected_slugs)
      if (length(result) == 0) list(NULL) else result
    }
  ),

  # Consolidate entity staging files into queue.csv.
  # cue=always: dispatched targets return same shape across runs (targets would
  # otherwise skip consolidation and leave staging files unmerged).
  tar_target(
    entity_queue_consolidated,
    {
      entity_agentic_dispatched
      consolidate_queue()
    },
    cue = tar_cue(mode = "always")
  ),

  # --- Phase 4.2: Agentic entity-note chain ----------------------------------
  # Now the default for all entity passages — the legacy critic branch was
  # removed (Phase G1). Every passage with source episodes routes agentic;
  # list(NULL) sentinel when none qualify so downstream pattern = map() declares.

  tar_target(
    entity_agentic_targets,
    {
      keep <- vapply(entity_passages, function(ep) {
        !is.null(ep) && length(ep$source_episode_ids) > 0L
      }, logical(1))
      if (!any(keep)) list(NULL) else entity_passages[keep]
    }
  ),

  tar_target(
    entity_agentic_extracted,
    {
      ep <- entity_agentic_targets[[1]]
      if (is.null(ep)) return(list(entity_id = NA_character_, note_type = NA_character_,
                                   extraction = NULL, timed_out = FALSE))
      extract_entity(ep)
    },
    pattern = map(entity_agentic_targets)
  ),

  tar_target(
    entity_agentic_markdown,
    {
      ep <- entity_agentic_targets[[1]]
      if (is.null(ep) || is.null(entity_agentic_extracted$extraction)) return("")
      assemble_entity_markdown(entity_agentic_extracted$extraction, ep,
                               existing_note = entity_agentic_extracted$existing_note %||% "")
    },
    pattern = map(entity_agentic_targets, entity_agentic_extracted)
  ),

  tar_target(
    entity_agentic_fact_check_result,
    {
      ep <- entity_agentic_targets[[1]]
      if (is.null(ep) || is.null(entity_agentic_extracted$extraction))
        return(list(matched_claims = character(0), unmatched_claims = character(0),
                    coverage_score = NA_real_, aps_proposition_count = 0L,
                    pipeline_path = "aps_error"))
      fact_check_entity(
        entity_id       = ep$entity_id,
        draft_markdown  = entity_agentic_markdown,
        source_passages = ep$source_passages,
        existing_note   = .read_vault_note(ep$entity_id, ep$note_type)
      )
    },
    pattern = map(entity_agentic_targets, entity_agentic_extracted, entity_agentic_markdown)
  ),

  tar_target(
    entity_agentic_dispatched,
    {
      ep <- entity_agentic_targets[[1]]
      if (is.null(ep) || is.null(entity_agentic_extracted$extraction))
        return(invisible(NULL))
      dispatch_agentic_entity(
        markdown           = entity_agentic_markdown,
        entity_record      = ep,
        fact_check_summary = entity_agentic_fact_check_result
      )
    },
    pattern = map(entity_agentic_targets, entity_agentic_extracted,
                  entity_agentic_markdown, entity_agentic_fact_check_result)
  ),

  # --- Phase 0: Agentic VTT → session-note chain -----------------------------
  # Per-session opt-in. Episodes in AGENTIC_VTT_SESSION_IDS run the new
  # agentic extraction flow (per-chunk schema-enforced extraction +
  # R-frontloaded assembly + one Synopsis LLM call). For non-opt-in episodes
  # every target below short-circuits to an empty list / character(0) and
  # the existing doc-prep + entity flows above run unchanged.

  # Opt-in episodes that overlap CURRENT_SESSION's VTT registry rows.
  tar_target(
    agentic_session_ids,
    intersect(vtt_registry_for_current$episode_id, AGENTIC_VTT_SESSION_IDS)
  ),

  # VTT file paths for the opt-in episodes (same row order as
  # agentic_session_ids).
  tar_target(
    agentic_vtt_paths,
    if (length(agentic_session_ids) == 0L) character(0)
    else file.path(NAS_MOUNT,
                   vtt_registry_for_current$filename[
                     match(agentic_session_ids, vtt_registry_for_current$episode_id)
                   ])
  ),

  # Preprocess each opt-in VTT once. format = "rds" so the cached
  # preprocessing survives chunk-level invalidations.
  tar_target(
    agentic_preprocessed,
    if (length(agentic_vtt_paths) == 0L) list()
    else lapply(seq_along(agentic_vtt_paths), function(i) {
      list(
        session_id = agentic_session_ids[i],
        vtt        = preprocess_vtt_for_extraction(
                        agentic_vtt_paths[i],
                        chunk_size = AGENTIC_CHUNK_SIZE_LINES)
      )
    }),
    format = "rds"
  ),

  # Per-chunk extraction inputs, flattened across opt-in sessions. Sentinel
  # list(NULL) when empty so pattern = map() downstream has at least one
  # branch (mirrors the entity_passages -> entity_refined pattern above).
  tar_target(
    agentic_chunk_inputs,
    {
      if (length(agentic_preprocessed) == 0L) return(list(NULL))
      out <- list()
      for (rec in agentic_preprocessed) {
        chunks <- rec$vtt$chunks
        for (i in seq_len(nrow(chunks))) {
          out[[length(out) + 1L]] <- list(
            session_id    = rec$session_id,
            chunk_id      = i,
            chunk_row     = chunks[i, ],
            recap_context = rec$vtt$recap_context
          )
        }
      }
      if (length(out) == 0L) list(NULL) else out
    },
    iteration = "list"
  ),

  # One Ollama extraction per chunk; per-chunk failure invalidates only its
  # branch, not the whole session run.
  tar_target(
    agentic_chunk_extractions,
    {
      inp <- agentic_chunk_inputs
      if (is.null(inp)) return(NULL)
      list(
        session_id = inp$session_id,
        chunk_id   = inp$chunk_id,
        extraction = extract_chunk(
          chunk_row     = inp$chunk_row,
          recap_context = inp$recap_context,
          chunk_id      = inp$chunk_id,
          model         = OLLAMA_MODEL,
          base_url      = OLLAMA_BASE_URL
        )
      )
    },
    pattern   = map(agentic_chunk_inputs),
    iteration = "list",
    format    = "rds"
  ),

  # Merge per-chunk extractions back together, grouped by session_id.
  tar_target(
    agentic_merged,
    {
      if (length(agentic_preprocessed) == 0L) return(list())
      results <- Filter(Negate(is.null), agentic_chunk_extractions)
      if (length(results) == 0L) return(list())
      sids <- vapply(results, function(r) r$session_id %||% NA_character_, character(1))
      lapply(unique(sids), function(sid) {
        per <- lapply(results[sids == sid], function(r) r$extraction)
        list(
          session_id = sid,
          merged     = merge_chunk_extractions(
                          per, dialogue_keep_n = AGENTIC_DIALOGUE_KEEP_N)
        )
      })
    }
  ),

  # Apply NPC/location filters; preserves protected entities via Step 0.6.
  tar_target(
    agentic_postprocessed,
    if (length(agentic_merged) == 0L) list()
    else lapply(agentic_merged, function(rec) {
      list(
        session_id = rec$session_id,
        merged     = postprocess_extracted(
                        rec$merged,
                        protected_path = PROTECTED_ENTITIES_PATH,
                        aliases_path   = ENTITY_ALIASES_PATH,
                        event_keep_n   = AGENTIC_EVENT_KEEP_N)
      )
    })
  ),

  # Single LLM call per session: the Synopsis paragraph only. Everything else
  # in the assembled markdown is R-frontloaded from agentic_postprocessed.
  tar_target(
    agentic_synthesis,
    if (length(agentic_postprocessed) == 0L) list()
    else lapply(seq_along(agentic_postprocessed), function(i) {
      rec     <- agentic_postprocessed[[i]]
      pre_rec <- agentic_preprocessed[[match(rec$session_id,
                                             vapply(agentic_preprocessed,
                                                    function(x) x$session_id,
                                                    character(1)))]]
      list(
        session_id = rec$session_id,
        synthesis  = synthesize_session_recap(
                        merged   = rec$merged,
                        vtt_meta = pre_rec$vtt,
                        model    = OLLAMA_MODEL,
                        base_url = OLLAMA_BASE_URL)
      )
    })
  ),

  # Assembled markdown (R does the heavy lifting; LLM only owned Synopsis).
  tar_target(
    agentic_markdown,
    if (length(agentic_postprocessed) == 0L) list()
    else lapply(seq_along(agentic_postprocessed), function(i) {
      rec     <- agentic_postprocessed[[i]]
      pre_rec <- agentic_preprocessed[[match(rec$session_id,
                                             vapply(agentic_preprocessed,
                                                    function(x) x$session_id,
                                                    character(1)))]]
      synth   <- agentic_synthesis[[match(rec$session_id,
                                          vapply(agentic_synthesis,
                                                 function(x) x$session_id,
                                                 character(1)))]]$synthesis
      list(
        session_id = rec$session_id,
        markdown   = assemble_session_markdown(
                        synthesis = synth,
                        merged    = rec$merged,
                        vtt_meta  = pre_rec$vtt)
      )
    })
  ),

  # Mechanical line-citation verification. Cheap R, no LLM. The score is
  # surfaced as the queue row's confidence; it does NOT block dispatch.
  tar_target(
    agentic_fact_check,
    if (length(agentic_postprocessed) == 0L) list()
    else lapply(agentic_postprocessed, function(rec) {
      pre_rec <- agentic_preprocessed[[match(rec$session_id,
                                             vapply(agentic_preprocessed,
                                                    function(x) x$session_id,
                                                    character(1)))]]
      list(
        session_id  = rec$session_id,
        fact_check  = verify_line_citations(rec$merged, pre_rec$vtt)
      )
    })
  ),

  # Enqueue one queue row per opt-in session, with section_id <sid>__agentic.
  # Coexists with any doc-prep row for the same episode (which writer-layer
  # routes to vault/dm_prep/<sid>.md when sid %in% AGENTIC_VTT_SESSION_IDS).
  tar_target(
    agentic_dispatched,
    {
      if (length(agentic_markdown) == 0L) return(invisible(NULL))
      lapply(seq_along(agentic_markdown), function(i) {
        rec <- agentic_markdown[[i]]
        fc  <- agentic_fact_check[[match(rec$session_id,
                                         vapply(agentic_fact_check,
                                                function(x) x$session_id,
                                                character(1)))]]$fact_check
        pre <- agentic_preprocessed[[match(rec$session_id,
                                           vapply(agentic_preprocessed,
                                                  function(x) x$session_id,
                                                  character(1)))]]
        source_text <- paste(pre$vtt$chunks$text, collapse = "\n\n")
        dispatch_agentic_session(
          markdown    = rec$markdown,
          session_id  = rec$session_id,
          source_text = source_text,
          fact_check  = fc
        )
      })
    }
  ),

  # Re-consolidate after agentic staging files exist so they roll into
  # queue.csv alongside the doc-prep and entity rows. cue=always because
  # agentic_dispatched returns the same `list("enqueued", ...)` shape across
  # runs, which lets targets skip this consolidation and leave the agentic
  # row stuck in review_queue/staging/. consolidate_queue() is idempotent
  # (no-op when staging is empty), so always running it is safe.
  tar_target(
    agentic_queue_consolidated,
    {
      agentic_dispatched
      consolidate_queue()
    },
    cue = tar_cue(mode = "always")
  )

)
