library(glue)
library(stringr)

SPARSE_THRESHOLD_WORDS <- 100

is_sparse <- function(text) {
  str_count(text, "\\S+") < SPARSE_THRESHOLD_WORDS
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
                          num_predict = 800L) {
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

npc_prompt <- function(npc_name, source_passages) {
  passages_text <- paste(source_passages, collapse = "\n\n---\n\n")
  glue(
"You are building an Obsidian markdown wiki for a D&D 5e Spelljammer campaign called Barquentine.

Your task: extract a structured NPC note for '{npc_name}' from the source passages below.

RULES — follow exactly:
1. Never fabricate. Only include details explicitly stated in the source. Leave fields blank or write 'unknown' if not present.
2. Preserve any direct quotes verbatim, wrapped in blockquote syntax (> ).
3. Always populate the source frontmatter field. Every note must include a source: field identifying where the content came from.
4. The player character formerly known as 'Basil' is referred to in prose as [[Basil|the Captain]]. His own note title remains 'Basil'.
5. If fewer than 3 distinct facts are present about this NPC, set review_required to true.
6. Output only the markdown note. No explanation, no preamble, no code fences.

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
  )
}

location_prompt <- function(location_name, source_passages) {
  passages_text <- paste(source_passages, collapse = "\n\n---\n\n")
  glue(
"You are building an Obsidian markdown wiki for a D&D 5e Spelljammer campaign called Barquentine.

Your task: extract a structured location note for '{location_name}' from the source passages below.

RULES — follow exactly:
1. Never fabricate. Only include details explicitly stated in the source. Leave fields blank or write 'unknown' if not present.
2. Preserve any direct quotes verbatim, wrapped in blockquote syntax (> ).
3. Always populate the source frontmatter field. Every note must include a source: field identifying where the content came from.
4. The player character formerly known as 'Basil' is referred to in prose as [[Basil|the Captain]]. His own note title remains 'Basil'.
5. If fewer than 3 distinct facts are present about this location, set review_required to true.
6. Output only the markdown note. No explanation, no preamble, no code fences.
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
  )
}

faction_prompt <- function(faction_name, source_passages) {
  passages_text <- paste(source_passages, collapse = "\n\n---\n\n")
  glue(
"You are building an Obsidian markdown wiki for a D&D 5e Spelljammer campaign called Barquentine.

Your task: extract a structured faction note for '{faction_name}' from the source passages below.

RULES — follow exactly:
1. Never fabricate. Only include details explicitly stated in the source. Leave fields blank or write 'unknown' if not present.
2. Preserve any direct quotes verbatim, wrapped in blockquote syntax (> ).
3. Always populate the source frontmatter field. Every note must include a source: field identifying where the content came from.
4. The player character formerly known as 'Basil' is referred to in prose as [[Basil|the Captain]]. His own note title remains 'Basil'.
5. If fewer than 3 distinct facts are present about this faction, set review_required to true.
6. Output only the markdown note. No explanation, no preamble, no code fences.
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
  )
}

generate_entity_note <- function(entity_name, source_passages, note_type,
                                  model       = OLLAMA_MODEL,
                                  base_url    = OLLAMA_BASE_URL,
                                  num_predict = 800L) {
  combined <- paste(source_passages, collapse = "\n\n")
  if (is_sparse(combined)) return(NULL)

  prompt <- switch(note_type,
    "npc"      = npc_prompt(entity_name, source_passages),
    "location" = location_prompt(entity_name, source_passages),
    "faction"  = faction_prompt(entity_name, source_passages),
    stop("Unknown note_type: ", note_type)
  )

  ollama_generate(prompt, GENERATOR_SYSTEM_PROMPT,
                  model    = model,
                  base_url = base_url,
                  options  = list(num_predict = num_predict))
}
