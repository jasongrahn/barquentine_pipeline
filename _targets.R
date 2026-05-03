library(targets)
library(tarchetypes)

tar_option_set(
  packages = c("httr2", "googledrive", "jsonlite", "readr",
               "stringr", "purrr", "fs", "gert", "glue", "yaml", "dplyr")
)

source("config.R")
source("R/gdrive.R")
source("R/source_b.R")
source("R/claude.R")
source("R/extract.R")
source("R/wikilinks.R")
source("R/writer.R")
source("R/merge.R")
source("R/review.R")
source("R/git_commit.R")

list(

  # --- Source B: multi-tab Google Doc ----------------------------------------
  tar_target(source_b_raw,      fetch_gdoc(EPISODE_NOTES_DOC_ID)),
  tar_target(source_b_sections, parse_source_b(source_b_raw)),

  # Section IDs (heading text) needed for filenames and prompts in branches.
  # Extracted as a separate target so pattern = map() can iterate over
  # (section_text, episode_id) simultaneously.
  tar_target(section_ids, names(source_b_sections)),

  # --- Alias registry — scanned from vault at pipeline start ----------------
  tar_target(alias_registry, build_alias_registry(VAULT_PATH)),

  # --- Session notes — one Claude call per Source B section -----------------
  tar_target(
    session_note_content,
    claude_generate_note(
      prompt        = session_prompt(section_ids, source_b_sections),
      system_prompt = paste(
        "You are a precise structured data extractor for a D&D campaign wiki.",
        "Follow all instructions exactly."
      )
    ),
    pattern = map(source_b_sections, section_ids)
  ),

  # --- Write session notes to vault (or DRY_RUN_PATH) -----------------------
  tar_target(
    session_notes_written,
    write_note(
      content       = session_note_content,
      relative_path = file.path("sessions", paste0(section_ids, ".md")),
      dry_run       = DRY_RUN,
      overwrite     = TRUE
    ),
    pattern = map(session_note_content, section_ids)
  ),

  # --- Run header in review log — after all notes are written ---------------
  # Referencing session_notes_written in the block forces the dependency
  # without adding a parameter to write_run_header().
  tar_target(
    review_header,
    {
      session_notes_written
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
  )

)
