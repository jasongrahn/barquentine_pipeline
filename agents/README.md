# Barquentine Wiki Recap — Skill Chain

## Architecture

A VTT transcript is ~20K words. Local models (gemma, llama) degrade at length and fabricate under complex multi-task prompts. Solution: **decompose into focused skills, preprocess aggressively in R, keep each LLM call short and single-purpose.**

```
Raw VTT
  │
  ▼
[00_preprocess] ← R, not LLM
  │ Strips timestamps, normalizes speakers, segments into
  │ recap / play / post-session, outputs clean chunks
  │
  ├──► play_chunks[] (chunked transcript, ~800-1000 words each)
  │    context: recap_section (from "Previously on")
  │
  ▼
[01_extract_events] ← LLM, per chunk
  │ Input: one chunk + campaign context
  │ Output: structured event list with line citations
  │
[02_extract_entities] ← LLM, per chunk
  │ Input: one chunk
  │ Output: NPCs and locations with descriptions
  │
[03_extract_dialogue] ← LLM, per chunk
  │ Input: one chunk + speaker map
  │ Output: key IC dialogue with attribution
  │
  ▼
[R merges chunk outputs, deduplicates entities]
  │
  ▼
[04_synthesize_recap] ← LLM, single call
  │ Input: merged events + entities + dialogue
  │ Output: final wiki entry (Obsidian markdown)
  │
  ▼
Wiki Entry (.md)
```

## Design Principles

1. **R does the structural work.** VTT parsing, speaker normalization, section boundaries, chunking, output merging, deduplication — none of this needs an LLM.
2. **Each LLM call does ONE thing.** Extract events. Extract entities. Extract dialogue. Synthesize. Never ask a local model to do all four at once.
3. **Chunks stay under ~1000 words.** Quality degrades on long inputs with small models. Short chunks = reliable extraction.
4. **Line numbers are preserved.** Every extracted claim carries a line citation back to the source VTT. This enables verification and makes fabrication auditable.
5. **Anti-fabrication is per-skill.** Each skill has its own guardrails tuned to its specific failure mode.

## Model Recommendations

| Skill | Recommended Model | Why |
|---|---|---|
| 01_extract_events | gemma or llama 8b+ | Factual extraction, moderate reasoning |
| 02_extract_entities | gemma or llama 8b+ | Pattern matching, low creativity needed |
| 03_extract_dialogue | gemma or llama 8b+ | Speaker attribution, IC/OOC filtering |
| 04_synthesize_recap | largest available | Generation task, needs coherence over length |

## Usage with Ollama

Each skill prompt is designed for `think=FALSE` (no thinking-mode token budget). System prompt is in `system.md`, user prompt template is in `user_template.md`. Call pattern:

```r
result <- call_ollama(
  model = "gemma3:12b",
  system = read_file("01_extract_events/system.md"),
  user = glue(read_file("01_extract_events/user_template.md")),
  think = FALSE
)
```
