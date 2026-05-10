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

list(

  # --- Source B: scan Drive folder, fetch all unprocessed episode docs --------
  # The fetch updates the registry cache for everything new in the folder, but
  # only the current session's sections feed the inner loop (one-session-at-a-time
  # rollout per docs/recursive_critic_loop_design.md "Strict session ordering").
  tar_target(source_b_sections_all,
             fetch_all_episode_docs(EPISODE_NOTES_FOLDER_ID,
                                    DOC_REGISTRY_PATH,
                                    VAULT_PATH),
             format = "rds"),

  tar_target(source_b_sections,
             source_b_sections_all[names(source_b_sections_all) == CURRENT_SESSION]),

  tar_target(section_ids, names(source_b_sections)),

  # --- Alias registry — scanned from vault at pipeline start -----------------
  tar_target(alias_registry, build_alias_registry(VAULT_PATH)),

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

  # Entity notes — inner loop: generate → critic → revise (Phase 1)
  # draft_with_refinement() owns the full generate→critic→revise cycle for all
  # note types. entity_passages is an unnamed list; [[1]] unwraps the record.
  # Existing vault note is passed as prior_draft so generation produces a coherent
  # updated note rather than a fragment.
  tar_target(
    entity_refined,
    {
      ep <- entity_passages[[1]]
      if (is.null(ep)) return(list(
        best_draft = NULL, best_confidence = -Inf,
        final_verdict = list(verdict = "skipped", confidence = NA_real_,
                             issues = list(), source_quotes = list()),
        iteration_log = list(), iteration_count = 1L,
        claude_used = FALSE, escalation_reason = NULL
      ))
      rel_path   <- .entity_relative_path(ep$entity_id, ep$note_type)
      full_path  <- file.path(VAULT_PATH, rel_path)
      vault_note <- if (file.exists(full_path))
        paste(readLines(full_path, warn = FALSE), collapse = "\n") else NULL
      draft_with_refinement(
        source_text     = paste(ep$source_passages, collapse = "\n\n---\n\n"),
        section_id      = ep$entity_id,
        note_type       = ep$note_type,
        entity_name     = ep$entity_name,
        source_passages = ep$source_passages,
        prior_draft     = vault_note
      )
    },
    pattern = map(entity_passages)
  ),

  # Dispatch — best_draft from inner loop → staging queue
  tar_target(
    entity_dispatched,
    {
      ep <- entity_passages[[1]]
      if (is.null(ep)) return(invisible(NULL))
      dispatch_entity_note(
        refinement_result  = entity_refined,
        entity_id          = ep$entity_id,
        entity_name        = ep$entity_name,
        note_type          = ep$note_type,
        source_passages    = ep$source_passages,
        source_episode_ids = ep$source_episode_ids
      )
    },
    pattern = map(entity_refined, entity_passages)
  ),

  # Consolidate entity staging files into queue.csv
  tar_target(
    entity_queue_consolidated,
    {
      entity_dispatched
      consolidate_queue()
    }
  )

)
