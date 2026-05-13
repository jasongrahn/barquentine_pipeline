library(httr2)

# Returns the content of the highest-numbered Story So Far snapshot whose
# session ID is strictly less than current_session (lexicographic comparison
# works correctly with zero-padded s01e01 format).
# Returns NULL if no prior snapshot exists.
read_story_so_far <- function(current_session, vault_path = VAULT_PATH) {
  ssf_dir <- file.path(vault_path, "story_so_far")
  if (!dir.exists(ssf_dir)) return(NULL)

  files <- list.files(ssf_dir, pattern = "^through_.*\\.md$", full.names = FALSE)
  if (length(files) == 0L) return(NULL)

  basenames   <- tools::file_path_sans_ext(files)
  session_ids <- sub("^through_", "", basenames)

  valid <- session_ids[session_ids < current_session]
  if (length(valid) == 0L) return(NULL)

  highest  <- max(valid)
  path     <- file.path(ssf_dir, paste0("through_", highest, ".md"))
  paste(readLines(path, warn = FALSE), collapse = "\n")
}

# Update the Story So Far to incorporate the events of through_session.
# Reads the session note for through_session from the vault, combines it with
# the prior summary, and calls Claude via the Batch API (non-blocking during
# the call, but the function polls until the batch completes before returning).
# Writes a versioned snapshot: vault/story_so_far/through_{session_id}.md
update_story_so_far <- function(through_session, vault_path = VAULT_PATH,
                                 model              = CLAUDE_MODEL,
                                 poll_interval_secs = 5,
                                 max_wait_secs      = 300) {
  session_path <- file.path(vault_path, "sessions", paste0(through_session, ".md"))
  if (!file.exists(session_path)) {
    stop(sprintf("Session note not found: %s\nRun write_placeholder_note('%s') if this session had no notes.",
                 session_path, through_session))
  }

  new_session_lines <- readLines(session_path, warn = FALSE)
  new_session_text  <- paste(new_session_lines, collapse = "\n")

  # Skip gap sessions — do not fabricate content for missing notes
  if (any(grepl("^gap:\\s*true", new_session_lines, ignore.case = TRUE))) {
    message(sprintf("Skipping gap session %s — no content to incorporate into Story So Far.",
                    through_session))
    return(invisible(NULL))
  }

  prior_summary <- read_story_so_far(through_session, vault_path)

  prior_block <- if (!is.null(prior_summary)) {
    paste0("CURRENT STORY SO FAR (update this; do not discard prior events):\n",
           prior_summary, "\n\n")
  } else {
    ""
  }

  pc_status_block <- paste0(
    "KEY ENTITIES (update their status based on the new session — this is narrative context, ",
    "not a replacement for vault entity files):\n",
    "- Basil / The Captain: PC; was known as 'Basil', now goes by 'The Captain'\n",
    "- Room: PC (played by John)\n",
    "- Lumi: PC (played by Chase)\n\n"
  )

  prompt <- paste0(
    prior_block,
    pc_status_block,
    "NEW SESSION TO INCORPORATE (", through_session, "):\n",
    new_session_text, "\n\n",
    "Update the campaign summary to incorporate the events of this session. ",
    "Preserve all prior context, compress where appropriate, highlight new developments, ",
    "active threads, and unresolved plot points. ",
    "Output only the updated narrative prose — no frontmatter, no preamble, no code fences."
  )

  system_prompt <- paste(
    "You are maintaining a living narrative summary of a D&D Spelljammer campaign called Barquentine.",
    "Never fabricate events not present in the provided session notes.",
    "Write in present-tense third-person narrative prose.",
    "Do not infer or guess any details not explicitly stated in the source."
  )

  api_key <- Sys.getenv("ANTHROPIC_API_KEY")
  if (nchar(api_key) == 0L) {
    stop("ANTHROPIC_API_KEY is not set. Add it to ~/.Renviron with usethis::edit_r_environ().")
  }

  batch_resp <- request("https://api.anthropic.com/v1/message_batches") |>
    req_headers(
      "x-api-key"         = api_key,
      "anthropic-version" = CLAUDE_API_VERSION,
      "anthropic-beta"    = "message-batches-2024-09-24",
      "content-type"      = "application/json"
    ) |>
    req_body_json(list(
      requests = list(list(
        custom_id = paste0("story_so_far_", through_session),
        params    = list(
          model      = model,
          max_tokens = 4000L,
          system     = system_prompt,
          messages   = list(list(role = "user", content = prompt))
        )
      ))
    )) |>
    req_perform() |>
    resp_body_json()

  batch_id <- batch_resp$id
  message(sprintf("Story So Far batch submitted (id: %s)", batch_id))

  elapsed <- 0L
  repeat {
    Sys.sleep(poll_interval_secs)
    elapsed <- elapsed + poll_interval_secs
    status_resp <- request(paste0("https://api.anthropic.com/v1/message_batches/", batch_id)) |>
      req_headers(
        "x-api-key"         = api_key,
        "anthropic-version" = CLAUDE_API_VERSION,
        "anthropic-beta"    = "message-batches-2024-09-24"
      ) |>
      req_perform() |>
      resp_body_json()
    if (status_resp$processing_status == "ended") break
    if (elapsed >= max_wait_secs) {
      stop(sprintf("Batch %s did not complete within %d seconds.", batch_id, max_wait_secs))
    }
    message(sprintf("  Polling batch %s... (%ds elapsed)", batch_id, elapsed))
  }

  results_resp <- request(paste0("https://api.anthropic.com/v1/message_batches/", batch_id, "/results")) |>
    req_headers(
      "x-api-key"         = api_key,
      "anthropic-version" = CLAUDE_API_VERSION,
      "anthropic-beta"    = "message-batches-2024-09-24"
    ) |>
    req_perform() |>
    resp_body_string()

  first_line <- strsplit(trimws(results_resp), "\n")[[1L]][[1L]]
  result_obj <- jsonlite::fromJSON(first_line, simplifyVector = FALSE)
  narrative  <- result_obj$result$message$content[[1L]]$text

  # Build sessions_covered from prior snapshot frontmatter + new session
  prior_covered <- .parse_sessions_covered(prior_summary)
  sessions_covered <- sort(unique(c(prior_covered, through_session)))
  sessions_yaml    <- paste0("[", paste(sessions_covered, collapse = ", "), "]")

  # Detect gaps among covered sessions
  gap_sessions <- vapply(sessions_covered, function(sid) {
    p <- file.path(vault_path, "sessions", paste0(sid, ".md"))
    if (!file.exists(p)) return(FALSE)
    any(grepl("^gap:\\s*true", readLines(p, warn = FALSE), ignore.case = TRUE))
  }, logical(1L))
  gaps_yaml <- if (any(gap_sessions))
    paste0("[", paste(sessions_covered[gap_sessions], collapse = ", "), "]")
  else "[]"

  frontmatter <- paste0(
    "---\n",
    "type: campaign_summary\n",
    "through_session: ", through_session, "\n",
    "generated_at: ", format(Sys.time(), "%Y-%m-%dT%H:%M:%S"), "\n",
    "sessions_covered: ", sessions_yaml, "\n",
    "gaps: ", gaps_yaml, "\n",
    "---\n\n"
  )

  ssf_dir <- file.path(vault_path, "story_so_far")
  dir.create(ssf_dir, showWarnings = FALSE, recursive = TRUE)
  out_path <- file.path(ssf_dir, paste0("through_", through_session, ".md"))
  writeLines(paste0(frontmatter, narrative, "\n"), out_path)
  message(sprintf("Story So Far written: %s", out_path))

  invisible(out_path)
}

# Extract sessions_covered list from an existing snapshot's frontmatter.
# Returns character(0) if the prior summary is NULL or has no sessions_covered field.
.parse_sessions_covered <- function(prior_summary) {
  if (is.null(prior_summary)) return(character(0))
  m <- regmatches(prior_summary,
                  regexpr("sessions_covered:\\s*\\[([^\\]]+)\\]", prior_summary, perl = TRUE))
  if (length(m) == 0L) return(character(0))
  inner  <- sub("sessions_covered:\\s*\\[([^\\]]+)\\]", "\\1", m, perl = TRUE)
  tokens <- trimws(strsplit(inner, ",")[[1L]])
  tokens[nzchar(tokens)]
}
