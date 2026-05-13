# run_wiki_pipeline.R — smoke-test entry point for the agentic VTT pipeline.
#
# Production runs the same logic via targets (see _targets.R; the agentic_*
# chain). This script is the fastest way to iterate on the per-chunk skill
# prompts in agents/wiki_skills/ or the assembly logic in
# R/agentic_extract.R against a single VTT file without rebuilding the
# whole DAG.
#
# Usage:
#   source("agents/run_wiki_pipeline.R")
#   result <- run_wiki_pipeline("/Volumes/share/videos/<file>.vtt")
#
# Output (in `output_dir`):
#   preprocessed.rds     — VTT chunks + recap context
#   raw_extracted.rds    — per-chunk per-skill raw outputs
#   extracted.rds        — merged + postprocessed extraction
#   session_<date>.md    — assembled session-note markdown
#
# All real logic lives in R/agentic_extract.R and R/agentic_postprocess.R.

.this_dir <- dirname(sys.frame(1)$ofile %||% "agents/run_wiki_pipeline.R")
.project_root <- normalizePath(file.path(.this_dir, ".."))
source(file.path(.project_root, "config.R"))
source(file.path(.project_root, "R/ollama.R"))
source(file.path(.project_root, "R/agentic_postprocess.R"))
source(file.path(.project_root, "R/agentic_extract.R"))
source(file.path(.project_root, "R/agentic_fact_check.R"))

SKILLS_DIR <- file.path(.this_dir, "wiki_skills")

run_wiki_pipeline <- function(vtt_path,
                              output_dir  = "/tmp/barquentine-agentic",
                              model       = OLLAMA_MODEL,
                              chunk_size  = AGENTIC_CHUNK_SIZE_LINES,
                              skills_dir  = SKILLS_DIR) {
  if (!file.exists(vtt_path)) stop("VTT not found: ", vtt_path)
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  cli::cli_h1("Processing: {basename(vtt_path)}")

  cli::cli_h2("Step 0: Preprocessing VTT")
  vtt <- preprocess_vtt_for_extraction(
    vtt_path,
    chunk_size       = chunk_size,
    preprocess_script = file.path(.this_dir, "preprocess_vtt.R")
  )
  cli::cli_alert_success("{vtt$n_chunks} chunks, {vtt$total_words} words")
  saveRDS(vtt, file.path(output_dir, "preprocessed.rds"))

  cli::cli_h2("Step 1: Per-chunk extraction")
  t_extract_start <- Sys.time()
  per_chunk <- lapply(seq_len(vtt$n_chunks), function(i) {
    chunk <- vtt$chunks[i, ]
    cli::cli_h3("Chunk {i}/{vtt$n_chunks} (lines {chunk$start_line}-{chunk$end_line}, {chunk$word_count} words)")
    extract_chunk(
      chunk_row     = chunk,
      recap_context = vtt$recap_context,
      chunk_id      = i,
      model         = model,
      base_url      = OLLAMA_BASE_URL,
      skills_dir    = skills_dir
    )
  })
  saveRDS(per_chunk, file.path(output_dir, "raw_extracted.rds"))
  t_extract <- difftime(Sys.time(), t_extract_start, units = "mins")

  cli::cli_h2("Step 2: Merge + postprocess")
  merged <- merge_chunk_extractions(per_chunk, dialogue_keep_n = AGENTIC_DIALOGUE_KEEP_N)
  post   <- postprocess_extracted(merged, event_keep_n = AGENTIC_EVENT_KEEP_N)
  saveRDS(post, file.path(output_dir, "extracted.rds"))
  cli::cli_alert_info(
    "{nrow(post$events)} events, {nrow(post$npcs)} NPCs, {nrow(post$locations)} locations, {nrow(post$dialogue)} dialogue lines"
  )

  cli::cli_h2("Step 3: Synthesize (Synopsis only)")
  t_synth_start <- Sys.time()
  synth <- synthesize_session_recap(
    merged     = post, vtt_meta = vtt,
    model      = model, base_url = OLLAMA_BASE_URL, skills_dir = skills_dir
  )
  t_synth <- difftime(Sys.time(), t_synth_start, units = "mins")
  if (isTRUE(synth$timed_out)) cli::cli_alert_danger("Synthesis timed out — assembling with placeholder Synopsis.")

  cli::cli_h2("Step 4: Assemble markdown")
  markdown <- assemble_session_markdown(synthesis = synth, merged = post, vtt_meta = vtt)

  cli::cli_h2("Step 5: Fact check (mechanical line citations)")
  fc <- verify_line_citations(post, vtt)
  cli::cli_alert_info(
    "fact_check: {fc$n_checked} checked, {fc$n_unsupported} unsupported, confidence={signif(fc$confidence, 3)}"
  )

  output_filename <- file.path(output_dir, sprintf("session_%s.md", vtt$session_date))
  writeLines(markdown, output_filename)
  cli::cli_alert_success("Written to {output_filename}")
  cli::cli_alert_info(
    "Extraction: {round(as.numeric(t_extract), 2)} min; synthesis: {round(as.numeric(t_synth), 2)} min"
  )

  invisible(list(
    session_date     = vtt$session_date,
    markdown         = markdown,
    extracted        = post,
    fact_check       = fc,
    output_file      = output_filename,
    extract_minutes  = as.numeric(t_extract),
    synth_minutes    = as.numeric(t_synth)
  ))
}

`%||%` <- function(x, y) if (is.null(x)) y else x
