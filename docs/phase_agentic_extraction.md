# Phase — Agentic Extraction Pipeline
**Status:** Prototype (draft) — validating on s02e34
**Created:** 2026-05-10
**Source:** `agents/README.md` (original draft author's notes)

A pipeline of focused, single-task LLM calls glued together with R, replacing
the current monolithic `generate_note() → critic loop` for VTT-sourced
content. Motivated by the s02e34 validation run, where the existing pipeline
produced hallucinated "Triune Healing" templates and meta-commentary
("Contextual Notes for Revision: ...") because gemma4:latest cannot reliably
generate a structured wiki entry from 14k chars of input in one shot.

> "Local models degrade at length and fabricate under complex multi-task
> prompts. Solution: decompose into focused skills, preprocess aggressively
> in R, keep each LLM call short and single-purpose."

---

## Architecture

```
Raw VTT
  │
  ▼
[00_preprocess]            ← R, not LLM
  │  Strip timestamps, normalize speakers, segment into
  │  recap / play / post-session, output ~50-line chunks
  │
  ├──► play_chunks[]       (~800-1000 words each)
  │    + recap_context     (from "Previously on")
  │
  ▼
[01_extract_events]        ← LLM, per chunk
  │  Input: one chunk + recap context
  │  Output: structured event list with line citations
  │
[02_extract_entities]      ← LLM, per chunk
  │  Output: NPCs and locations with descriptions
  │
[03_extract_dialogue]      ← LLM, per chunk
  │  Output: significant IC dialogue with attribution
  │
  ▼
[R merge + dedup]          ← R, not LLM
  │
  ▼
[04_synthesize_recap]      ← LLM, single call
  │  Input: merged events + entities + dialogue (no transcript)
  │  Output: Obsidian-compatible wiki entry
  │
  ▼
Wiki entry (.md)
```

## Design Principles

1. **R does the structural work.** VTT parsing, speaker normalization,
   section boundaries, chunking, output merging, deduplication — none of
   this needs an LLM.
2. **Each LLM call does ONE thing.** Extract events. Extract entities.
   Extract dialogue. Synthesize. Never ask a local model to do all four at
   once.
3. **Chunks stay under ~1000 words.** Quality degrades on long inputs with
   small models. Short chunks = reliable extraction.
4. **Line numbers are preserved.** Every extracted claim carries a line
   citation back to the source VTT. Enables verification; makes
   fabrication auditable.
5. **Anti-fabrication is per-skill.** Each skill has its own guardrails
   tuned to its specific failure mode.
6. **Synthesis sees only structured data.** The synthesis LLM call never
   reads the transcript — it only assembles pre-extracted JSON. Format
   becomes mechanical; the model cannot drift into meta-commentary because
   it has no raw text to monologue about.

## Files

| Path | Purpose |
|---|---|
| `agents/preprocess_vtt.R` | VTT parser, speaker normalizer, chunker |
| `agents/run_wiki_pipeline.R` | Orchestrator; chains preprocess → extract → merge → synthesize |
| `agents/wiki_skills/01_extract_events/{system,user_template}.md` | Events skill |
| `agents/wiki_skills/02_extract_entities/{system,user_template}.md` | Entities skill |
| `agents/wiki_skills/03_extract_dialogue/{system,user_template}.md` | Dialogue skill |
| `agents/wiki_skills/04_synthesize_recap/{system,user_template}.md` | Synthesis skill |

## Open questions (track during prototype)

- **PC vs DM disambiguation.** Smoke test showed `02_extract_entities`
  returning "The Admiral" as an NPC despite the system prompt telling it
  The Admiral IS the DM. Needs prompt strengthening, or a post-hoc R
  filter against `config/entity_exclusions.csv`.
- **Line-number fidelity.** `03_extract_dialogue` returned `line: 1,2,3,…`
  instead of real transcript line numbers. LLMs are bad at numerical
  precision. R can fix post-hoc by `str_locate`-ing the dialogue substring
  in chunk text.
- **PC names hard-coded in `02_extract_entities/system.md`.** Drift risk
  when a new PC joins. Pull from a `config/pc_roster` (does not yet exist).
- **Cross-session entity merging.** Current `merge.R` + Shiny merge modal
  handle vault-wide entity dedup. The new flow produces per-session entity
  lists; still need cross-session merging against the existing vault.
- **Chunk boundary stitching.** Conversations span chunks. Either chunk
  with overlap, or have synthesis tolerate slight redundancy.
- **No critic on extraction.** Mechanical checks (cited line exists in
  chunk range; line of cited dialogue actually contains the dialogue
  substring) are cheap; add them in R rather than via another LLM call.
- **Doc prep notes path.** Currently `source_b.R` produces session notes
  from DM Google Doc tabs. Keep that path? Merge with VTT-derived notes
  at the wiki level? Out of scope for prototype; revisit after VTT
  validation.

## Integration with current pipeline (deferred)

| /agents/ component | Replaces in current pipeline |
|---|---|
| `preprocess_vtt.R` | `source_c.R` parsing + per-chunk extraction in `vtt_entities` |
| `01_extract_events` | (new — no equivalent today) |
| `02_extract_entities` | Entity-name spotting + per-entity passage aggregation in `entity_passages` |
| `03_extract_dialogue` | (new — no equivalent today) |
| `04_synthesize_recap` | `generate_note()` + the `draft_with_refinement` critic loop for session notes |
| R merge/dedup | Chunk-level entity merging in `aggregate_entity_passages` |

The recursive critic loop becomes mostly redundant in this architecture:
extraction skills have constrained outputs that fail loudly rather than
hallucinate quietly; synthesis gets pre-validated structured data, so it
can't fabricate facts. A lightweight critic on the synthesis step (does
the prose match the structured data?) may still help but does not need
6 generator↔critic iterations.

## Validation plan

1. **Prototype run on s02e34's VTT.** Compare wiki entry quality and
   per-entity extraction to current pipeline's queue.csv outputs for the
   same session. Specifically check whether characters like Attorrnash,
   The Admiral, Lumi, Room, The Captain, the Giff Flotilla produce
   wiki-shaped output rather than generic "Character Archetype
   Guidelines" / "Revised Narrative Arc Analysis" meta-essays.
2. If meaningfully better → write follow-up phase doc for full migration
   into `_targets.R`, vault writing, queue integration, training data
   capture.
3. If not better → diagnose: prompt tuning vs. model swap vs. architecture
   rethink. Keep the recursive-critic-loop work as the production path.
