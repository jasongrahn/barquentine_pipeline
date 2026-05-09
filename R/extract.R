library(glue)
library(stringr)

SPARSE_THRESHOLD_WORDS <- 100

is_sparse <- function(text) {
  str_count(text, "\\S+") < SPARSE_THRESHOLD_WORDS
}

load_campaign_facts <- function(path = "config/campaign_facts.md") {
  if (!file.exists(path)) return("")
  paste(readLines(path, warn = FALSE), collapse = "\n")
}

session_prompt <- function(episode_id, section_text, few_shot_paths = NULL) {
  few_shot_block <- .build_few_shot_block(few_shot_paths)
  glue(
"You are building an Obsidian markdown wiki for a D&D 5e Spelljammer campaign called Barquentine.

Your task: extract a structured session note from the source text below.

RULES — follow exactly:
1. Never fabricate. If a detail is not in the source text, leave the field blank or write 'unknown'. Do not infer or guess.
2. Preserve NPC dialogue verbatim if it appears in the source.
3. Always populate the source frontmatter field. Every note must include a source: field identifying where the content came from.
4. The player character formerly known as 'Basil' is referred to as 'the Captain' in all prose and wikilinks, written as [[Basil|the Captain]].
5. If the source text is fewer than 100 words, set review_required to true and populate only what is explicitly present.
6. All entity references (NPCs, locations, items, factions) must use [[wikilink]] syntax.
7. Output only the markdown note. No explanation, no preamble, no code fences.
8. The source text is an automated transcript and may contain garbled, split, or misheard words. Do not guess or correct them — write [unclear] in place of any word or phrase you cannot confidently interpret from context.

{few_shot_block}SOURCE TEXT (episode: {episode_id}):
{section_text}

OUTPUT FORMAT:
---
tags: [session]
episode: {episode_id}
title:
date_played:
source: prep_notes
review_required: false
---

## Summary

## Key Events
-

## NPCs Present
-

## Locations
-

## Items / Artifacts
-

## Open Threads
-

## GM Notes
"
  )
}

generate_note <- function(episode_id, section_text,
                          few_shot_paths = NULL,
                          model       = OLLAMA_MODEL,
                          base_url    = OLLAMA_BASE_URL,
                          num_predict = 2400L) {
  if (is_sparse(section_text)) return(NULL)
  prompt <- session_prompt(episode_id, section_text, few_shot_paths = few_shot_paths)
  ollama_generate(prompt, GENERATOR_SYSTEM_PROMPT, model = model, base_url = base_url,
                  options = list(num_predict = num_predict))
}

# Loads up to 10 most recent SFT pairs from JSONL files and formats them as
# a few-shot block to prepend to the prompt. Returns "" when no files exist.
.build_few_shot_block <- function(few_shot_paths) {
  if (is.null(few_shot_paths) || length(few_shot_paths) == 0) return("")
  paths <- few_shot_paths[file.exists(few_shot_paths)]
  if (length(paths) == 0) return("")

  records <- list()
  for (p in paths) {
    lines <- readLines(p, warn = FALSE)
    lines <- lines[nzchar(lines)]
    for (ln in lines) {
      rec <- tryCatch(jsonlite::fromJSON(ln, simplifyVector = FALSE),
                      error = function(e) NULL)
      if (!is.null(rec) && !is.null(rec$prompt) && !is.null(rec$completion))
        records <- c(records, list(rec))
    }
  }
  if (length(records) == 0) return("")

  records <- tail(records, 10)
  shots <- vapply(records, function(r) {
    paste0("EXAMPLE SOURCE INPUT:\n", r$prompt,
           "\n\nEXAMPLE OUTPUT:\n", r$completion)
  }, character(1))
  paste0("--- FEW-SHOT EXAMPLES ---\n",
         paste(shots, collapse = "\n\n---\n\n"),
         "\n--- END EXAMPLES ---\n\n")
}

revise_note <- function(draft, issues, quotes, source_text,
                        model    = OLLAMA_MODEL,
                        base_url = OLLAMA_BASE_URL) {
  issues_block <- if (length(issues) > 0)
    paste0("ISSUES TO CORRECT:\n", paste0("- ", unlist(issues), collapse = "\n"))
  else
    "ISSUES TO CORRECT:\n(none specified)"

  quotes_block <- if (length(quotes) > 0)
    paste0("SOURCE QUOTES GROUNDING THESE ISSUES:\n",
           paste0("> ", unlist(quotes), collapse = "\n"))
  else
    "SOURCE QUOTES GROUNDING THESE ISSUES:\n(none provided)"

  prompt <- paste0(
    "SOURCE TEXT:\n", source_text,
    "\n\n", quotes_block,
    "\n\n", issues_block,
    "\n\nDRAFT TO REVISE:\n", draft,
    "\n\nRevise the draft above. ",
    "Correct the specific issues listed below. ",
    "You may rephrase immediately surrounding sentences for readability, ",
    "but do not add new facts, remove sections, ",
    "or change anything not adjacent to a listed issue. ",
    "Output only the revised markdown note with no explanation or preamble."
  )

  result <- ollama_generate(prompt, GENERATOR_SYSTEM_PROMPT,
                             model    = model,
                             base_url = base_url,
                             think    = FALSE)

  # Propagate timeout sentinel so draft_with_refinement() can detect it
  if (is.list(result) && isTRUE(result$timed_out)) return(result)
  result
}

draft_with_refinement <- function(source_text, section_id, note_type = "session",
                                   few_shot_paths = NULL,
                                   model          = OLLAMA_MODEL,
                                   base_url       = OLLAMA_BASE_URL) {
  # Ensure temp dir exists for per-iteration checkpoints
  dir.create("temp", showWarnings = FALSE, recursive = FALSE)

  # Degraded-Ollama guard: scoped to this invocation only
  ollama_critic_degraded <- FALSE
  had_timeout            <- FALSE

  best_draft      <- NULL
  best_confidence <- -Inf
  iteration_log   <- list()
  claude_used     <- FALSE
  escalation_reason <- NULL

  for (iter in seq_len(DRAFT_MAX_ITERATIONS)) {

    # --- Generate or revise ---
    if (iter == 1L) {
      draft <- if (note_type == "session") {
        generate_note(section_id, source_text,
                      few_shot_paths = few_shot_paths,
                      model = model, base_url = base_url)
      } else {
        NULL  # entity note generation handled by caller
      }
    } else {
      last_verdict <- iteration_log[[iter - 1L]]
      draft <- revise_note(draft, last_verdict$issues_raw, last_verdict$quotes_raw,
                           source_text, model = model, base_url = base_url)
      if (is.list(draft) && isTRUE(draft$timed_out)) {
        draft <- best_draft  # fall back to best so far; escalate below
      }
    }

    # Write iteration checkpoint
    temp_path <- file.path("temp", paste0(section_id, "_iter_", iter, ".md"))
    if (!is.null(draft) && is.character(draft)) {
      writeLines(draft, temp_path)
    }

    # --- Critic call: route to Claude if Ollama is degraded ---
    verdict <- if (ollama_critic_degraded) {
      claude_review_note(draft, source_text)
    } else {
      review_note(draft, source_text)
    }

    # Handle timeout sentinel from review_note()
    if (is.list(verdict) && isTRUE(verdict$timed_out)) {
      ollama_critic_degraded <- TRUE
      had_timeout            <- TRUE
      escalation_reason      <- "ollama_timeout"
      verdict                <- claude_review_note(draft, source_text)
    }

    # Normalize fields that may be missing
    v_verdict    <- verdict$verdict    %||% "parse_error"
    v_confidence <- if (is.null(verdict$confidence) || is.na(verdict$confidence)) 0 else verdict$confidence
    v_issues     <- if (is.null(verdict$issues)) list() else verdict$issues
    v_quotes     <- if (is.null(verdict$source_quotes)) list() else verdict$source_quotes
    escalated    <- isTRUE(verdict$escalated) || ollama_critic_degraded

    log_entry <- list(
      section_id          = section_id,
      iteration           = iter,
      model               = model,
      verdict             = v_verdict,
      confidence          = v_confidence,
      issues_count        = length(v_issues),
      issues_raw          = v_issues,
      quotes_raw          = v_quotes,
      escalated_to_claude = escalated,
      escalation_reason   = if (escalated && !is.null(escalation_reason))
                              escalation_reason else NULL,
      timestamp           = Sys.time()
    )
    iteration_log <- c(iteration_log, list(log_entry))

    # Track best draft (highest confidence seen, not latest)
    if (v_confidence > best_confidence) {
      best_draft      <- draft
      best_confidence <- v_confidence
    }

    # Break on approval or cap
    if (v_verdict == "approved" || iter == DRAFT_MAX_ITERATIONS) break
  }

  # On cap hit with no approval: Claude full-revision escalation
  if (iteration_log[[length(iteration_log)]]$verdict != "approved" &&
      length(iteration_log) >= DRAFT_MAX_ITERATIONS) {
    cap_verdict      <- claude_review_note(best_draft, source_text)
    claude_used      <- TRUE
    escalation_reason <- if (is.null(escalation_reason)) "cap_hit" else escalation_reason

    c_verdict    <- cap_verdict$verdict    %||% "parse_error"
    c_confidence <- if (is.null(cap_verdict$confidence) || is.na(cap_verdict$confidence))
                      0 else cap_verdict$confidence
    c_issues     <- if (is.null(cap_verdict$issues)) list() else cap_verdict$issues
    c_quotes     <- if (is.null(cap_verdict$source_quotes)) list() else cap_verdict$source_quotes

    cap_entry <- list(
      section_id          = section_id,
      iteration           = length(iteration_log) + 1L,
      model               = "claude (cap_hit escalation)",
      verdict             = c_verdict,
      confidence          = c_confidence,
      issues_count        = length(c_issues),
      issues_raw          = c_issues,
      quotes_raw          = c_quotes,
      escalated_to_claude = TRUE,
      escalation_reason   = "cap_hit",
      timestamp           = Sys.time()
    )
    iteration_log <- c(iteration_log, list(cap_entry))

    if (c_confidence > best_confidence) {
      best_draft      <- best_draft  # Claude didn't produce a new draft here, it reviewed
      best_confidence <- c_confidence
    }
  }

  # Clean up temp files on successful completion
  for (i in seq_len(length(iteration_log))) {
    p <- file.path("temp", paste0(section_id, "_iter_", i, ".md"))
    if (file.exists(p)) file.remove(p)
  }

  # Strip internal fields from log before returning
  public_log <- lapply(iteration_log, function(e) {
    e$issues_raw <- NULL
    e$quotes_raw <- NULL
    e
  })

  list(
    best_draft        = best_draft,
    best_confidence   = best_confidence,
    final_verdict     = iteration_log[[length(iteration_log)]],
    iteration_log     = public_log,
    iteration_count   = length(iteration_log),
    claude_used       = claude_used,
    escalation_reason = escalation_reason
  )
}

# Null-coalescing helper (base R)
`%||%` <- function(x, y) if (is.null(x)) y else x

.regen_context_block <- function(prior_draft, critic_findings, user_feedback) {
  parts <- character(0)
  if (!is.null(prior_draft) && nzchar(trimws(prior_draft)))
    parts <- c(parts, paste0("PREVIOUS DRAFT (do not repeat as-is; improve it):\n", prior_draft))
  if (!is.null(critic_findings) && length(critic_findings) > 0)
    parts <- c(parts, paste0("CRITIC ISSUES TO ADDRESS:\n- ",
                              paste(unlist(critic_findings), collapse = "\n- ")))
  if (!is.null(user_feedback) && nzchar(trimws(user_feedback)))
    parts <- c(parts, paste0("REVIEWER FEEDBACK:\n", user_feedback))
  if (length(parts) == 0) return("")
  paste0("\n\n--- REGENERATION CONTEXT ---\n",
         paste(parts, collapse = "\n\n"),
         "\n\nAddress all critic issues and incorporate reviewer feedback in your revised draft.")
}

npc_prompt <- function(npc_name, source_passages,
                        campaign_facts  = "",
                        prior_draft     = NULL,
                        critic_findings = NULL,
                        user_feedback   = NULL) {
  passages_text <- paste(source_passages, collapse = "\n\n---\n\n")
  facts_block   <- if (nzchar(trimws(campaign_facts)))
    paste0("\n\nKNOWN CAMPAIGN FACTS:\n", campaign_facts) else ""
  regen_block   <- .regen_context_block(prior_draft, critic_findings, user_feedback)

  paste0(glue(
"You are building an Obsidian markdown wiki for a D&D 5e Spelljammer campaign called Barquentine.

Your task: extract a structured NPC note for '{npc_name}' from the source passages below.

RULES — follow exactly:
1. Never fabricate. Only include details explicitly stated in the source. Leave fields blank or write 'unknown' if not present.
2. Preserve any direct quotes verbatim, wrapped in blockquote syntax (> ).
3. Always populate the source frontmatter field. Every note must include a source: field identifying where the content came from.
4. The player character formerly known as 'Basil' is referred to in prose as [[Basil|the Captain]]. His own note title remains 'Basil'.
5. If fewer than 3 distinct facts are present about this NPC, set review_required to true.
6. Output only the markdown note. No explanation, no preamble, no code fences. Your response must begin with exactly `---` on the first line and nothing before it.
7. The source text is an automated transcript and may contain garbled, split, or misheard words. Write [unclear] in place of any word or phrase you cannot confidently interpret from context.

SOURCE PASSAGES:
{passages_text}

OUTPUT FORMAT:
---
tags: [npc]
name: {npc_name}
aliases: []
status: unknown
faction:
first_seen:
source:
review_required: false
---

## Overview

## Appearance & Vibe

## Motivation

## Relationship to Party

## Quotes

## Session Appearances
-

## GM Notes
"
  ), facts_block, regen_block)
}

location_prompt <- function(location_name, source_passages,
                             campaign_facts  = "",
                             prior_draft     = NULL,
                             critic_findings = NULL,
                             user_feedback   = NULL) {
  passages_text <- paste(source_passages, collapse = "\n\n---\n\n")
  facts_block   <- if (nzchar(trimws(campaign_facts)))
    paste0("\n\nKNOWN CAMPAIGN FACTS:\n", campaign_facts) else ""
  regen_block   <- .regen_context_block(prior_draft, critic_findings, user_feedback)

  paste0(glue(
"You are building an Obsidian markdown wiki for a D&D 5e Spelljammer campaign called Barquentine.

Your task: extract a structured location note for '{location_name}' from the source passages below.

RULES — follow exactly:
1. Never fabricate. Only include details explicitly stated in the source. Leave fields blank or write 'unknown' if not present.
2. Preserve any direct quotes verbatim, wrapped in blockquote syntax (> ).
3. Always populate the source frontmatter field. Every note must include a source: field identifying where the content came from.
4. The player character formerly known as 'Basil' is referred to in prose as [[Basil|the Captain]]. His own note title remains 'Basil'.
5. If fewer than 3 distinct facts are present about this location, set review_required to true.
6. Output only the markdown note. No explanation, no preamble, no code fences. Your response must begin with exactly `---` on the first line and nothing before it.
7. The source text is an automated transcript and may contain garbled, split, or misheard words. Write [unclear] in place of any word or phrase you cannot confidently interpret from context.

SOURCE PASSAGES:
{passages_text}

OUTPUT FORMAT:
---
tags: [location]
name: {location_name}
type: unknown
region: unknown
source:
review_required: false
---

## Description

## Notable Features
-

## NPCs Here
-

## Session Appearances
-

## GM Notes
"
  ), facts_block, regen_block)
}

faction_prompt <- function(faction_name, source_passages,
                            campaign_facts  = "",
                            prior_draft     = NULL,
                            critic_findings = NULL,
                            user_feedback   = NULL) {
  passages_text <- paste(source_passages, collapse = "\n\n---\n\n")
  facts_block   <- if (nzchar(trimws(campaign_facts)))
    paste0("\n\nKNOWN CAMPAIGN FACTS:\n", campaign_facts) else ""
  regen_block   <- .regen_context_block(prior_draft, critic_findings, user_feedback)

  paste0(glue(
"You are building an Obsidian markdown wiki for a D&D 5e Spelljammer campaign called Barquentine.

Your task: extract a structured faction note for '{faction_name}' from the source passages below.

RULES — follow exactly:
1. Never fabricate. Only include details explicitly stated in the source. Leave fields blank or write 'unknown' if not present.
2. Preserve any direct quotes verbatim, wrapped in blockquote syntax (> ).
3. Always populate the source frontmatter field. Every note must include a source: field identifying where the content came from.
4. The player character formerly known as 'Basil' is referred to in prose as [[Basil|the Captain]]. His own note title remains 'Basil'.
5. If fewer than 3 distinct facts are present about this faction, set review_required to true.
6. Output only the markdown note. No explanation, no preamble, no code fences. Your response must begin with exactly `---` on the first line and nothing before it.
7. The source text is an automated transcript and may contain garbled, split, or misheard words. Write [unclear] in place of any word or phrase you cannot confidently interpret from context.

SOURCE PASSAGES:
{passages_text}

OUTPUT FORMAT:
---
tags: [faction]
name: {faction_name}
disposition_to_party: unknown
source:
review_required: false
---

## Overview

## Key Members
-

## Goals

## Session Appearances
-

## GM Notes
"
  ), facts_block, regen_block)
}

generate_entity_note <- function(entity_name, source_passages, note_type,
                                  model           = OLLAMA_MODEL,
                                  base_url        = OLLAMA_BASE_URL,
                                  num_predict     = ENTITY_NUM_PREDICT,
                                  campaign_facts  = NULL,
                                  prior_draft     = NULL,
                                  critic_findings = NULL,
                                  user_feedback   = NULL) {
  combined <- paste(source_passages, collapse = "\n\n")
  if (is_sparse(combined)) return(NULL)

  facts <- if (is.null(campaign_facts)) load_campaign_facts() else campaign_facts

  prompt <- switch(note_type,
    "npc"      = npc_prompt(entity_name, source_passages, facts,
                             prior_draft, critic_findings, user_feedback),
    "location" = location_prompt(entity_name, source_passages, facts,
                                  prior_draft, critic_findings, user_feedback),
    "faction"  = faction_prompt(entity_name, source_passages, facts,
                                 prior_draft, critic_findings, user_feedback),
    stop("Unknown note_type: ", note_type)
  )

  raw <- ollama_generate(prompt, GENERATOR_SYSTEM_PROMPT,
                         model    = model,
                         base_url = base_url,
                         options  = list(num_predict = num_predict),
                         think    = FALSE)
  if (is.null(raw)) return(NULL)
  sub("^[^-]*(?=---)", "", raw, perl = TRUE)
}
