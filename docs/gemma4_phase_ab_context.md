# Gemma4 Optimization — Phase A & B Context
**Branch:** `feature/gemma4-optimization`  
**Commit:** 65d661c  
**Date:** 2026-05-14  
**Full plan:** `docs/phase_gemma4_optimization.md`

This document captures the concrete, verified results from Phases A and B for
use as context in future conversations. Do not edit it to record Phase C+ findings
— append those to the plan doc directly.

---

## Why this work exists

Wet run #2 (2026-05-13) found that `gemma4:latest` cannot reliably produce passage
citation indices under Ollama's `format` / JSON Schema constrained decoding. The
plan (`docs/phase_gemma4_optimization.md`) identified four mismatches between how
barquentine uses Gemma4 and how it actually works. Phases A and B addressed the
diagnostic and prompt/context layers. Phase C (APS grounding) is next.

---

## Phase A — Diagnostic Results

### A1: Thinking mode wiring

Three approaches tested on `gemma4:latest` via Ollama:

| Method | Result |
|---|---|
| `think = TRUE` on `/api/chat` | Silently ignored — no thinking field, no tokens in content |
| `<\|think\|>` injected into system prompt via `/api/chat` | Does not activate thinking |
| `/api/generate`, `raw=TRUE`, prompt ends with `<start_of_turn>model\n<think>\n` | **Works** — genuine thinking block, closes with `</think>`, clean answer follows |

The Ollama model file for `gemma4:latest` has template `{{ .Prompt }}` — no Gemma4
chat template is applied. Thinking only fires via the raw generate endpoint with the
manually constructed Gemma4 chat format.

**Why thinking is still not used for entity extraction:** VTT transcript text is
dense and noisy. Testing showed:
- 3,000-word VTT input → **90s Ollama timeout** (hard limit hit)
- 6,873-word VTT input → **infinite loop** (model repeats "The user has presented a
  very long string of text..." and never closes `</think>`)

`ollama_generate_thinking()` is implemented in `R/ollama.R` for future use with
shorter, cleaner inputs. It is not called by `extract_entity()`.

### A2: Claude-ism audit of entity skill prompts

All four system prompts (`05_extract_pc`, `06_extract_npc`, `07_extract_location`,
`08_extract_faction`) were already relatively clean — no multi-paragraph XML
preambles, no `<rules>` tags, no chain-of-thought cues. Identified issues:

1. **Markdown headers as section dividers** (`## What to extract`, `## Citation rules`,
   `## Output format`) — not required by Gemma4's training
2. **"Return ONLY the JSON object. No preamble, no markdown fences, no explanation."** —
   Claude-specific phrasing
3. **ALL-CAPS negation** (`Do NOT invent details`) — Claude-style emphasis
4. **Citation rule duplication** — same rule in both system prompt and user template
5. **"set `line` to the N from the `PASSAGE [N]:` label, DO NOT use numbers found
   inside the passage text"** — overly specific phrasing that, combined with
   constrained decoding, pressured the model into hallucinating wrong integers.
   Changed to: "set `line` to the passage number or null if uncertain"

---

## Phase B — Changes Made

### B1: System prompts rewritten (`agents/wiki_skills/05-08/system.md`)

All four files rewritten. Key changes:
- Removed markdown section headers — replaced with direct field listings
- Added explicit type annotations: `fieldname: {"value": "...", "line": N}  — single object`
  vs `fieldname: ["str1", "str2"]  — plain array of strings, no line field`
- This was necessary because without constrained decoding, Gemma4 applied `{value, line}`
  structure to all fields including arrays like `aliases`
- Removed "Return ONLY the JSON object..." — replaced with "Respond with only the JSON object."
- No-fabrication rule kept; `[unclear]` instruction kept

### B2: User templates simplified (`agents/wiki_skills/05-08/user_template.md`)

Removed the redundant inline citation rule (already in system prompt). Kept entity
header block and passage block. Simplified closing instruction.

### B3: `ollama_generate_thinking()` added to `R/ollama.R`

New function using `/api/generate` with `raw=TRUE` and Gemma4 chat template.
Constructs: `<start_of_turn>user\n{system}\n\n{user}<end_of_turn>\n<start_of_turn>model\n<think>\n`
(system prepended to user turn — the `<start_of_turn>system` role does not work via
the raw endpoint).
Strips thinking block; returns only the answer after `</think>`.
**Not called by `extract_entity()` — kept for future short-input use cases.**

### B4: `extract_entity()` — generation approach unchanged

`extract_entity()` in `R/agentic_entity_extract.R` continues to call `ollama_generate()`
with `format = entity_schema(note_type)` and `think = FALSE`.

**Why `format=` is still required:** Testing without `format=` showed that Gemma4
ignores JSON instructions entirely when unconstrained — outputs markdown prose
regardless of system prompt. Constrained decoding remains necessary for JSON output,
despite its citation-index quality problems (Phase C's problem to fix).

### B5: Word limit raised (`config.R`)

`AGENTIC_ENTITY_PASSAGE_WORD_LIMIT`: 4,000L → **8,000L**

At ~12s per 3,000 words (no thinking mode), 8,000 words fits well within the 90s
Ollama timeout. The Basil entity record has 6,873 words — all 5 passages now fit.

### B6: `entity_aliases` populated on entity records (`R/source_c.R`)

**Problem found:** `entity_record$entity_aliases` was always NULL. The aliases
(e.g. `captain`, `the_captain` for Basil) were never passed to `extract_entity()`,
so the extraction prompt said "Known aliases: " with nothing. The model had no way
to know that "Captain" references in the VTT were about Basil.

**Fix in `aggregate_entity_passages()`:**
1. `prot_df` load hoisted before the `if (length(routing_map) > 0L)` block so it is
   always defined (previously it was only defined inside the routing block).
2. After Step 1.5, builds `alias_lookup`: a canonical-slug → alias-slug vector from
   `pc_alias` rows in `protected_entities.csv` and from `alias_registry`.
3. In Step 3 (sentence-window extraction), populates `rec$entity_aliases` from
   `alias_lookup`.

### B7: `extract_relevant_sentences()` — alias-aware (`R/source_c.R`)

**Problem found:** Sentence-window extraction searched only for the canonical entity
name. For Basil (canonical: "Basil"), passages full of "Captain" references returned
empty strings → fell back to full 1,500-word passage chunks. The model was getting
dense, unfocused context.

**Fix:** Added `aliases = character(0)` parameter. All names (canonical + aliases)
are OR-combined into a single regex pattern. Results for Basil:
- Before: 5 full passages, 6,873 words
- After: 5 windowed passages, **2,974 words** (57% reduction, more focused)

Backward-compatible: default `aliases = character(0)` reproduces previous behaviour.

### B8: Test stubs updated (`tests/testthat/test-agentic_entity_extract.R`)

`extract_entity()` now calls `ollama_generate()` directly (not via `.call_ollama_skill`).
Test stubs changed from `assign(".call_ollama_skill", ...)` to `assign("ollama_generate", ...)`.
The "uses pc skill" test now checks `system_prompt` arg instead of `system`.
**All 19 tests pass. No regressions introduced.**

---

## Remaining issues NOT fixed by Phase B

These are known and documented; they are Phase C's scope:

| Issue | Root cause | Phase C fix |
|---|---|---|
| `line: {}` instead of integer/null | Gemma4 constrained decoding bug — outputs empty object for null in some schemas | APS grounding removes dependency on line numbers entirely |
| `aliases` sometimes a string instead of array | Same constrained decoding bug | APS grounding; entity aliases now passed via prompt anyway |
| Identity confusion (wrong character, wrong gender) | Model conflates entities in dense VTT passages; sentence-window helps but doesn't fully resolve | APS propositions from source text will flag ungrounded claims |
| "Librarian", "High Sorcerer" as hallucinated aliases | Constrained decoding + dense context | APS grounding will mark these as unmatched |

---

## File inventory — what changed in Phase A+B

| File | Change |
|---|---|
| `R/ollama.R` | Added `ollama_generate_thinking()` (60 lines) |
| `R/agentic_entity_extract.R` | Minor: whitespace cleanup only (generation call unchanged) |
| `R/source_c.R` | `extract_relevant_sentences()` alias param; `aggregate_entity_passages()` alias lookup + hoisted `prot_df` |
| `config.R` | `AGENTIC_ENTITY_PASSAGE_WORD_LIMIT` 4000L → 8000L |
| `agents/wiki_skills/05_extract_pc/system.md` | Full rewrite (Gemma4-native style) |
| `agents/wiki_skills/05_extract_pc/user_template.md` | Simplified |
| `agents/wiki_skills/06_extract_npc/system.md` | Full rewrite |
| `agents/wiki_skills/06_extract_npc/user_template.md` | Simplified |
| `agents/wiki_skills/07_extract_location/system.md` | Full rewrite |
| `agents/wiki_skills/07_extract_location/user_template.md` | Simplified |
| `agents/wiki_skills/08_extract_faction/system.md` | Full rewrite |
| `agents/wiki_skills/08_extract_faction/user_template.md` | Simplified |
| `tests/testthat/test-agentic_entity_extract.R` | Stubs updated to `ollama_generate` |
| `docs/phase_gemma4_optimization.md` | Phase A + B findings appended |

---

## Phase C starting point

Next step is `R/agentic_entity_fact_check.R` — full replacement with APS-based
grounding. See `docs/phase_gemma4_optimization.md` § Phase C for the full spec.
The Phase C prompt is available to paste into a new conversation.
