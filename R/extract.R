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

session_prompt <- function(episode_id, section_text, few_shot_paths = NULL,
                           story_so_far = NULL) {
  few_shot_block <- .build_few_shot_block(few_shot_paths)
  story_block    <- if (!is.null(story_so_far) && nzchar(trimws(story_so_far))) {
    paste0(
      "CAMPAIGN CONTEXT — Story So Far (use only to avoid contradictions; ",
      "do not add details from here that are absent in the source text below):\n",
      story_so_far, "\n\n"
    )
  } else {
    ""
  }
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

{story_block}{few_shot_block}SOURCE TEXT (episode: {episode_id}):
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
                          story_so_far   = NULL,
                          model       = OLLAMA_MODEL,
                          base_url    = OLLAMA_BASE_URL,
                          num_predict = 2400L) {
  if (is_sparse(section_text)) return(NULL)
  prompt <- session_prompt(episode_id, section_text,
                           few_shot_paths = few_shot_paths,
                           story_so_far   = story_so_far)
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

# Verdict tier ranking for select_best_draft(). approved beats flagged beats
# rejected; parse_error and skipped iterations are not selectable.
.verdict_tier <- function(v) {
  switch(v %||% "",
    approved = 3L,
    flagged  = 2L,
    rejected = 1L,
    0L
  )
}

# Pick the iteration whose draft we surface to the reviewer.
# Rule: highest verdict tier wins (approved > flagged > rejected). Within tier,
# fewest issues wins; final tiebreak is the latest iteration (the loop is
# supposed to be improving the draft, so trust later passes).
# parse_error / skipped iterations are not selectable. If every iteration is
# parse_error / skipped, fall back to the latest iteration that has a draft.
select_best_draft <- function(iteration_log) {
  if (length(iteration_log) == 0L) {
    return(list(draft = NULL, entry = NULL, iteration = NA_integer_))
  }

  has_draft <- function(e) is.character(e$draft) && nzchar(e$draft) && !is.na(e$draft)
  candidates <- Filter(function(e) has_draft(e) && .verdict_tier(e$verdict) > 0L,
                       iteration_log)

  if (length(candidates) == 0L) {
    fallback <- NULL
    for (e in iteration_log) if (has_draft(e)) fallback <- e
    if (is.null(fallback)) return(list(draft = NULL, entry = NULL, iteration = NA_integer_))
    return(list(draft = fallback$draft, entry = fallback,
                iteration = fallback$iteration %||% NA_integer_))
  }

  max_tier   <- max(vapply(candidates, function(e) .verdict_tier(e$verdict), integer(1)))
  candidates <- Filter(function(e) .verdict_tier(e$verdict) == max_tier, candidates)

  best <- candidates[[1L]]
  for (e in candidates[-1L]) {
    e_iss  <- e$issues_count    %||% 0L
    b_iss  <- best$issues_count %||% 0L
    e_iter <- e$iteration       %||% 0L
    b_iter <- best$iteration    %||% 0L
    if (e_iss < b_iss || (e_iss == b_iss && e_iter > b_iter)) best <- e
  }

  list(draft = best$draft, entry = best,
       iteration = best$iteration %||% NA_integer_)
}

draft_with_refinement <- function(source_text, section_id, note_type = "session",
                                   few_shot_paths  = NULL,
                                   story_so_far    = NULL,
                                   entity_name     = NULL,
                                   source_passages = NULL,
                                   prior_draft     = NULL,
                                   model           = OLLAMA_MODEL,
                                   base_url        = OLLAMA_BASE_URL) {
  # Ensure temp dir exists for per-iteration checkpoints
  dir.create("temp", showWarnings = FALSE, recursive = FALSE)

  # Degraded-Ollama guard: scoped to this invocation only
  ollama_critic_degraded <- FALSE
  had_timeout            <- FALSE

  iteration_log      <- list()
  claude_used        <- FALSE
  escalation_reason  <- NULL
  iter               <- 0L  # log/sequence number; increments every loop turn
  useful_iters       <- 0L  # critic responses that counted toward the cap
  parse_retry_budget <- DRAFT_PARSE_RETRY_BUDGET
  cap_hit            <- FALSE

  while (useful_iters < DRAFT_MAX_ITERATIONS) {
    iter <- iter + 1L

    # --- Generate or revise ---
    if (iter == 1L) {
      draft <- if (note_type == "session") {
        generate_note(section_id, source_text,
                      few_shot_paths = few_shot_paths,
                      story_so_far   = story_so_far,
                      model = model, base_url = base_url)
      } else {
        generate_entity_note(
          entity_name     = entity_name,
          source_passages = source_passages %||% list(source_text),
          note_type       = note_type,
          model           = model,
          base_url        = base_url,
          prior_draft     = prior_draft
        )
      }
    } else {
      last_verdict <- iteration_log[[iter - 1L]]
      draft <- revise_note(draft, last_verdict$issues, last_verdict$source_quotes,
                           source_text, model = model, base_url = base_url)
      if (is.list(draft) && isTRUE(draft$timed_out)) {
        # Timeout: fall back to the previous iteration's draft so the critic
        # has something to review and the loop can escalate to Claude.
        draft <- last_verdict$draft
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
      issues              = v_issues,
      source_quotes       = v_quotes,
      draft               = if (is.character(draft)) draft else NA_character_,
      escalated_to_claude = escalated,
      escalation_reason   = if (escalated && !is.null(escalation_reason))
                              escalation_reason else NULL,
      timestamp           = Sys.time()
    )
    iteration_log <- c(iteration_log, list(log_entry))

    # parse_error iterations don't count toward the cap until the retry budget
    # is exhausted. The iteration is still logged (so we can debug parse
    # failures), but the loop gets another turn to produce a real verdict.
    if (v_verdict == "parse_error" && parse_retry_budget > 0L) {
      parse_retry_budget <- parse_retry_budget - 1L
      next
    }

    useful_iters <- useful_iters + 1L

    if (v_verdict == "approved") break
    if (useful_iters >= DRAFT_MAX_ITERATIONS) {
      cap_hit <- TRUE
      break
    }
  }

  # On cap hit with no approval: Claude reviews the current best draft.
  # Note: Claude does not generate a new draft here; it provides an
  # authoritative verdict on the best Ollama draft. The cap_entry carries
  # that draft text so select_best_draft() can promote it if Claude approves.
  if (cap_hit && iteration_log[[length(iteration_log)]]$verdict != "approved") {
    pre_claude_best  <- select_best_draft(iteration_log)
    cap_verdict      <- claude_review_note(pre_claude_best$draft, source_text)
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
      issues              = c_issues,
      source_quotes       = c_quotes,
      draft               = if (is.character(pre_claude_best$draft))
                              pre_claude_best$draft else NA_character_,
      escalated_to_claude = TRUE,
      escalation_reason   = "cap_hit",
      timestamp           = Sys.time()
    )
    iteration_log <- c(iteration_log, list(cap_entry))
  }

  # Clean up temp files on successful completion
  for (i in seq_len(length(iteration_log))) {
    p <- file.path("temp", paste0(section_id, "_iter_", i, ".md"))
    if (file.exists(p)) file.remove(p)
  }

  # Pick the draft to surface and the verdict that applies to it.
  best <- select_best_draft(iteration_log)
  best_entry <- best$entry

  # Strip per-iter issue payloads from log before returning to keep
  # iteration_log JSON small. final_verdict (returned separately) keeps them
  # so the router can write them to queue.csv.
  public_log <- lapply(iteration_log, function(e) {
    e$issues        <- NULL
    e$source_quotes <- NULL
    e
  })

  list(
    best_draft        = best$draft,
    best_confidence   = if (is.null(best_entry)) -Inf else (best_entry$confidence %||% 0),
    best_iteration    = best$iteration,
    final_verdict     = if (is.null(best_entry))
                          iteration_log[[length(iteration_log)]] else best_entry,
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
