# Re-synthesize a wiki entry from cached extraction.
#
# This version puts R in charge of structural assembly (frontmatter, NPC list,
# Location list, Dialogue block, Threads) and uses ONE narrow LLM call for the
# prose-only sections (Synopsis + Major Events). The model is no longer asked
# to assemble a multi-section markdown template; that was the failure mode.
#
# Run from project root:
#   Rscript agents/resynthesize.R [extracted_rds_path] [output_md_path]

suppressPackageStartupMessages({
  library(tidyverse); library(glue); library(jsonlite)
  source("config.R")
  source("R/ollama.R")
  source("R/agentic_postprocess.R")
  source("agents/run_wiki_pipeline.R")
})

args <- commandArgs(trailingOnly = TRUE)
.coalesce <- function(x, default) if (length(x) == 0 || is.na(x) || !nzchar(x)) default else x
extracted_path <- .coalesce(args[1], "/tmp/barquentine-agentic-s02e34/extracted.rds")
output_md      <- .coalesce(args[2], "/tmp/barquentine-agentic-s02e34/session_2025-12-23_v4.md")
preproc_path   <- file.path(dirname(extracted_path), "preprocessed.rds")

if (!file.exists(extracted_path)) stop("Missing extracted.rds: ", extracted_path)
if (!file.exists(preproc_path))   stop("Missing preprocessed.rds: ", preproc_path)

cat(sprintf("Loading cached extraction from %s\n", extracted_path))
ex   <- readRDS(extracted_path)
vtt  <- readRDS(preproc_path)

cat(sprintf("Pre-postprocess: %d events, %d NPCs, %d locations, %d dialogue\n",
            nrow(ex$events), nrow(ex$npcs), nrow(ex$locations), nrow(ex$dialogue)))

pp <- postprocess_extracted(ex)

cat(sprintf("Post-postprocess: %d events, %d NPCs, %d locations, %d dialogue\n",
            nrow(pp$events), nrow(pp$npcs), nrow(pp$locations), nrow(pp$dialogue)))

# --- LLM call: prose narrative only -----------------------------------------
events_json    <- toJSON(pp$events,    pretty = TRUE, auto_unbox = TRUE)
npcs_json      <- toJSON(pp$npcs,      pretty = TRUE, auto_unbox = TRUE)
locations_json <- toJSON(pp$locations, pretty = TRUE, auto_unbox = TRUE)

user_prompt <- glue(
  load_skill("04_synthesize_recap", "user_template"),
  session_date   = vtt$session_date,
  events_json    = events_json,
  npcs_json      = npcs_json,
  locations_json = locations_json,
  .open = "{", .close = "}"
)
cat(sprintf("Narrative-prose prompt: %d chars\n\n", nchar(user_prompt)))

t0 <- Sys.time()
narrative <- call_ollama(
  model  = OLLAMA_MODEL,
  system = load_skill("04_synthesize_recap", "system"),
  user   = user_prompt,
  think  = FALSE
)
dt <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
cat(sprintf("Narrative call took %.1fs (%d chars)\n", dt,
            if (is.null(narrative)) 0 else nchar(narrative)))

if (is.null(narrative) || (is.list(narrative) && isTRUE(narrative$timed_out))) {
  stop("Narrative call failed (empty/timeout). Aborting.")
}

# --- R assembly: frontmatter, NPCs, locations, dialogue, threads ------------
.fmt_list <- function(xs) {
  if (length(xs) == 0) return("[]")
  paste0("[", paste0("\"", xs, "\"", collapse = ", "), "]")
}

.fmt_quote <- function(q) {
  # Lines: replace mid-sentence ellipses with cleaner runs
  q <- str_replace_all(q, "\\s+", " ")
  trimws(q)
}

npc_section <- if (nrow(pp$npcs) > 0) {
  paste0(
    "## NPCs Encountered\n\n",
    paste(
      sprintf("### %s\n%s",
              pp$npcs$name,
              ifelse(is.na(pp$npcs$description) | !nzchar(pp$npcs$description),
                     "(no description in source)",
                     pp$npcs$description)),
      collapse = "\n\n"
    )
  )
} else "## NPCs Encountered\n\n_None recorded._"

loc_section <- if (nrow(pp$locations) > 0) {
  paste0(
    "## Locations Visited\n\n",
    paste(
      sprintf("### %s\n%s",
              pp$locations$name,
              ifelse(is.na(pp$locations$description) | !nzchar(pp$locations$description),
                     "(no description in source)",
                     pp$locations$description)),
      collapse = "\n\n"
    )
  )
} else "## Locations Visited\n\n_None recorded._"

dialogue_section <- if (nrow(pp$dialogue) > 0) {
  paste0(
    "## Key Dialogue\n\n",
    paste(
      sprintf("> \"%s\" — **%s**\n%s",
              .fmt_quote(pp$dialogue$dialogue),
              pp$dialogue$speaker,
              ifelse(is.na(pp$dialogue$context), "", pp$dialogue$context)),
      collapse = "\n\n"
    )
  )
} else "## Key Dialogue\n\n_None recorded._"

threads_section <- "## Unresolved Threads\n\n_(Reviewer: fill in based on Major Events.)_"

frontmatter <- glue(
  "---\n",
  "session_date: {date}\n",
  "episode_title: \"\"\n",
  "pcs: [Captain, Room, Lumi]\n",
  "npcs: {npcs}\n",
  "locations: {locations}\n",
  "tags: [session-recap, barquentine]\n",
  "source: vtt\n",
  "review_required: true\n",
  "---",
  date = vtt$session_date,
  npcs = .fmt_list(pp$npcs$name),
  locations = .fmt_list(pp$locations$name)
)

# --- Major Events: rendered mechanically from pruned events list ----------
# Each event is one bullet with its line citation. The synthesis LLM is no
# longer asked to write this section because long freeform prose drifts into
# fabrication (it invents line numbers and generic scene descriptors).
events_section <- if (nrow(pp$events) > 0) {
  paste0(
    "## Major Events\n\n",
    paste(
      sprintf("- (line %s) %s",
              ifelse(is.na(pp$events$line), "?", as.character(pp$events$line)),
              pp$events$event),
      collapse = "\n"
    )
  )
} else "## Major Events\n\n_None extracted from this session._"

# narrative starts with "## Synopsis" per the prompt
wiki_entry <- paste(
  frontmatter,
  "",
  paste0("# Session ", vtt$session_date),
  "",
  trimws(narrative),
  "",
  events_section,
  "",
  npc_section,
  "",
  loc_section,
  "",
  dialogue_section,
  "",
  threads_section,
  "",
  "## Session Notes",
  "None this session.",
  sep = "\n"
)

writeLines(wiki_entry, output_md)
cat(sprintf("Wrote %s (%d chars total; LLM contributed %d chars of prose)\n",
            output_md, nchar(wiki_entry),
            if (is.null(narrative)) 0L else nchar(narrative)))
