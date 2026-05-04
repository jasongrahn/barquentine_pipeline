library(targets)
library(tarchetypes)

tar_option_set(
  packages = c("httr2", "googledrive", "jsonlite", "readr",
               "stringr", "purrr", "fs", "gert", "glue", "yaml", "dplyr")
)

source("config.R")
source("R/gdrive.R")
source("R/source_b.R")
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

  # --- Source B: multi-tab Google Doc ----------------------------------------
  tar_target(source_b_raw,      fetch_gdoc(EPISODE_NOTES_DOC_ID)),
  tar_target(source_b_sections, parse_source_b(source_b_raw)),

  tar_target(section_ids, names(source_b_sections)),

  # --- Alias registry — scanned from vault at pipeline start -----------------
  tar_target(alias_registry, build_alias_registry(VAULT_PATH)),

  # --- Session notes — qwen3.5:9b generates one draft per section ------------
  tar_target(
    session_draft,
    generate_note(section_ids, source_b_sections),
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
  )

)
