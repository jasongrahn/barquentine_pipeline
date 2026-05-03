library(glue)
library(stringr)

SPARSE_THRESHOLD_WORDS <- 100

is_sparse <- function(text) {
  str_count(text, "\\S+") < SPARSE_THRESHOLD_WORDS
}

session_prompt <- function(episode_id, section_text) {
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

SOURCE TEXT (episode: {episode_id}):
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
