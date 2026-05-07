library(targets)
library(tarchetypes)

tar_option_set(
  packages = c("httr2", "googledrive", "jsonlite", "readr",
               "stringr", "purrr", "fs", "gert", "glue", "yaml", "dplyr")
)

source("config.R")
source("R/gdrive.R")
source("R/source_b.R")
source("R/source_c.R")
source("R/ollama.R")
source("R/claude.R")
source("R/extract.R")
source("R/critic.R")
source("R/router.R")
source("R/queue.R")
source("R/wikilinks.R")
source("R/writer.R")
source("R/merge.R")
source("R/review.R")
source("R/git_commit.R")

list(

  # --- Source B: scan Drive folder, fetch all unprocessed episode docs --------
  tar_target(source_b_sections,
             fetch_all_episode_docs(EPISODE_NOTES_FOLDER_ID,
                                    DOC_REGISTRY_PATH,
                                    VAULT_PATH),
             format = "rds"),

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

  # --- Session notes — qwen3.5:9b generates one draft per section ------------
  tar_target(
    session_draft,
    generate_note(section_ids, source_b_sections,
                  few_shot_paths = sft_example_files),
    pattern = map(source_b_sections, section_ids)
  ),

  # --- Critic — llama3.1:8b fact-checks each draft ---------------------------
  tar_target(
    critic_verdict,
    review_note(session_draft, source_b_sections),
    pattern = map(session_draft, source_b_sections)
  ),

  # --- Router — writes to vault (auto-approve) or staging queue --------------
  tar_target(
    dispatched,
    dispatch_note(
      draft        = session_draft,
      verdict_list = critic_verdict,
      section_id   = section_ids,
      source_text  = source_b_sections
    ),
    pattern = map(session_draft, critic_verdict, section_ids, source_b_sections)
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

  # VTT file paths — one per registry row with episode_id populated
  tar_target(
    vtt_file_paths,
    file.path(NAS_MOUNT, vtt_registry$filename)
  ),

  # Episode IDs aligned with vtt_file_paths (same row order)
  tar_target(
    vtt_episode_ids,
    vtt_registry$episode_id
  ),

  # Entity spotting — one result per VTT file (llama3.1:8b + JSON Schema)
  # list() wrapper prevents targets from flattening named list when aggregating branches
  tar_target(
    vtt_entities,
    list(process_vtt_file(vtt_file_paths, vtt_episode_ids)),
    pattern = map(vtt_file_paths, vtt_episode_ids)
  ),

  # Aggregate passages per entity across all VTT files
  tar_target(
    entity_passages,
    aggregate_entity_passages(vtt_entities, alias_registry,
                              exclusion_slugs = c(entity_exclusions, excluded_protected_slugs),
                              protected_slugs = protected_slugs)
  ),

  # Generate NPC/location/faction drafts (qwen3.5:9b)
  # entity_passages is an unnamed list; targets slices with [i] giving list-of-1,
  # so [[1]] is needed to unwrap the record in each branch.
  tar_target(
    entity_draft,
    {
      ep <- entity_passages[[1]]
      generate_entity_note(
        entity_name     = ep$entity_name,
        source_passages = ep$source_passages,
        note_type       = ep$note_type
      )
    },
    pattern = map(entity_passages)
  ),

  # Critic — same llama3.1:8b critic as session notes
  tar_target(
    entity_verdict,
    {
      ep <- entity_passages[[1]]
      review_note(
        draft  = entity_draft,
        source = paste(ep$source_passages, collapse = "\n\n")
      )
    },
    pattern = map(entity_draft, entity_passages)
  ),

  # Dispatch — supplement existing note or create fresh; enqueue for review
  tar_target(
    entity_dispatched,
    {
      ep <- entity_passages[[1]]
      dispatch_entity_note(
        draft              = entity_draft,
        verdict_list       = entity_verdict,
        entity_id          = ep$entity_id,
        entity_name        = ep$entity_name,
        note_type          = ep$note_type,
        source_passages    = ep$source_passages,
        source_episode_ids = ep$source_episode_ids
      )
    },
    pattern = map(entity_draft, entity_verdict, entity_passages)
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
