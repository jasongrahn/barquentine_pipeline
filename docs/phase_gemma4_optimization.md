# Phase: Gemma4 Optimization
**Date opened:** 2026-05-13  
**Status:** PLANNING — no code merged  
**Triggered by:** Wet run #2 citation scoring failure; Gemma4 capability audit in `docs/oss_wiki_tools_investigation.md`

---

## Background

Wet run #2 (2026-05-13) surfaced that `gemma4:latest` cannot reliably produce passage citation
indices (integers into a chunk array) under Ollama's `format` / JSON Schema constrained decoding.
A capability audit identified four concrete mismatches between how barquentine currently uses
Gemma4 and how Gemma4 is actually designed to work:

1. **Citation index scoring fights the model** — not what it was built for; Gemma-APS is.
2. **Thinking mode is not being used** — `think = FALSE` in `agentic_entity_extract.R`; Gemma4
   supports native thinking via `<|think|>` but it is unknown whether Ollama wires `think = TRUE`
   to that token for Gemma4 specifically.
3. **Long context is underutilized** — `AGENTIC_ENTITY_PASSAGE_WORD_LIMIT = 4000L` when Gemma4
   supports ~96K words (128K tokens).
4. **Extraction prompts written for Claude** — XML-heavy, multi-paragraph, Anthropic instruction
   idioms that do not match Gemma4's training template.

This plan addresses all four mismatches in four sequential phases.

---

## Phase A — Diagnostics

**Goal:** Characterize the two unknowns (thinking mode wiring; Claude-ism inventory) before
changing any production code. No code merged to pipeline at end of this phase.

### Tasks

**A1 — Test `think = TRUE` on Gemma4 via Ollama**

Run a minimal R script (outside `tar_make()`) that calls `ollama_generate()` with
`think = TRUE` on `gemma4:latest` using a simple entity extraction task (e.g., "Extract
the name and role of every character mentioned in: [short VTT excerpt]"). Capture the raw
response text before any parsing. Inspect it for:
- `<thinking>...</thinking>` tokens (Gemma4 native)
- `<think>...</think>` tokens (qwen3-style, which Ollama wires automatically)
- Absence of any thinking block (parameter silently ignored)

If thinking tokens are absent, document what manual system prompt injection is needed:
prepend `<|think|>` to the system prompt string in the skill files or in
`R/agentic_entity_extract.R` before the `.load_skill()` call.

**Files touched:** none (test script in `scratch/` or run interactively; not committed to pipeline)  
**Touches `tar_make()`?** No  
**Estimated effort:** 30 min

**A2 — Audit extraction system prompts for Claude-isms**

Read all four entity skill system prompt files:
- `agents/wiki_skills/05_extract_pc/system`
- `agents/wiki_skills/06_extract_npc/system`
- `agents/wiki_skills/07_extract_location/system`
- `agents/wiki_skills/08_extract_faction/system`

List every phrase or structural pattern that is Anthropic-specific:
- "Think carefully before responding"
- "Your answer must be valid JSON"
- Numbered rule lists with XML-like delimiters (`<rules>`, `<instructions>`, `<context>`)
- Multi-paragraph preambles that describe what the model is before giving the task
- Claude-style chain-of-thought cues ("First, read the passages carefully...")

Document findings in the diagnostic report section below (to be filled in after running A1/A2).

**Files touched:** none (read-only audit)  
**Touches `tar_make()`?** No  
**Estimated effort:** 1 hr

### Definition of done

Written diagnostic findings appended to this document under "Phase A Findings" before any
Phase B code is written. No code merged.

### Risk

None — this phase makes no changes. The only risk is spending too long auditing; time-box A2
to 1 hr and move on.

---

## Phase B — Prompt and Context Improvements

**Goal:** Rewrite entity extraction prompts in Gemma4-native style; raise passage word limit to
test holistic (no-chunk, no-index) extraction. Validate on one entity (Basil) through the Shiny
queue.

**Prerequisite:** Phase A complete and diagnostic findings written.

### Tasks

**B1 — Rewrite entity extraction system prompts**

Using Phase A audit findings, rewrite the four system prompt files (`05_extract_pc/system`
through `08_extract_faction/system`) in Gemma4-native style:
- Shorter, task-focused opening (one sentence: what the model is doing, not what it is)
- Remove multi-paragraph preambles and Anthropic-style XML delimiters
- Replace Claude-style chain-of-thought cues with direct imperatives
- If A1 showed Ollama does not wire `think = TRUE`, prepend `<|think|>` to system prompt
  text (one line at the top; do not add it to the `user_template` files)
- Keep the no-fabrication instruction: "Write `[unclear]` rather than guess. Do not infer
  facts not present in the source passages."

**Files to change:**
- `agents/wiki_skills/05_extract_pc/system`
- `agents/wiki_skills/06_extract_npc/system`
- `agents/wiki_skills/07_extract_location/system`
- `agents/wiki_skills/08_extract_faction/system`
- `R/agentic_entity_extract.R` — if `<|think|>` injection is needed, add it in
  `extract_entity()` before the `.call_ollama_skill()` call; also change `think = FALSE`
  to `think = TRUE` if Ollama wires it automatically

**Touches `tar_make()`?** Yes — skill files are loaded by `extract_entity()` at runtime.
The change is gated behind `AGENTIC_ENTITY_SESSION_IDS`, so only opt-in episodes are affected.

**Estimated effort:** 2–4 hrs

**B2 — Raise passage word limit and test holistic extraction**

In `config.R`, raise `AGENTIC_ENTITY_PASSAGE_WORD_LIMIT` from `4000L` toward Gemma4's
effective ceiling. Start with `32000L` (half of what fits comfortably in 128K tokens after
system prompt overhead). This eliminates truncation for most entities.

Then run a single-entity smoke test: call `extract_entity()` directly (not via `tar_make()`)
on Basil's aggregated passages from s02e37 with the new prompt and raised limit. Compare
the raw extraction to the wet run #2 baseline for the same entity.

**Files to change:**
- `config.R` — `AGENTIC_ENTITY_PASSAGE_WORD_LIMIT <- 32000L` (or higher after testing)

**Touches `tar_make()`?** Yes — `AGENTIC_ENTITY_PASSAGE_WORD_LIMIT` is read at extraction time.

**Estimated effort:** 2 hrs (1 hr config change + test run; 1 hr comparing output)

### Validation procedure

1. Run `extract_entity()` on Basil (entity_id: `basil`, note_type: `pc`) with B1+B2 changes.
2. Route result through `agentic_entity_dispatch.R` into the review queue.
3. Open `shiny/review_queue/app.R` (port 7474).
4. Review the Basil entry: does it avoid character identity confusion? Are facts grounded in
   the source passages? Are `[unclear]` markers present where appropriate?
5. Compare side-by-side with the wet run #2 Basil output.

### Definition of done

Basil extracted cleanly with new prompt + raised limit; output reviewed in Shiny queue; quality
meaningfully better than wet run #2 baseline (fewer ungrounded facts, correct identity, no
template fill-in). Document outcome in "Phase B Findings" section.

### Risk

**What breaks:** If rewritten prompts produce worse output (e.g., missing required schema fields,
structural collapse under constrained decoding), the pipeline produces more `NULL` extractions.
These show up as "Failed Generation" items in the Shiny sidebar — reviewable, not catastrophic.

**Rollback:** `git revert` the skill file changes and restore `AGENTIC_ENTITY_PASSAGE_WORD_LIMIT`
to `4000L` in `config.R`. No pipeline state is persisted between runs for this parameter.

---

## Phase C — Gemma-APS as Critic Replacement

**Goal:** Replace the broken citation-index scoring step with a proposition-based grounding check
that does not require constrained decoding and uses each model for what it was trained for.

**Prerequisite:** Phase B complete and validated.

### Architecture

```
Source passages (entity)
        │
        ▼
[Step 1] APS pass — gemma-aps:2b (Ollama)
        │  Output: character vector of atomic propositions
        │  e.g. c("Basil is a halfling rogue", "Basil works as a courier", ...)
        │
        ▼
[Step 2] Generator pass — gemma4:latest (Ollama)
        │  Free-text generation; no format= constraint on this call
        │  Output: wiki page markdown draft
        │
        ▼
[Step 3] Grounding check — R-only (no model call)
        │  For each claim sentence in the draft:
        │    string-match (or embedding-match) against proposition set
        │    unmatched → flagged
        │
        ▼
[Step 4] Result struct
         {matched_claims, unmatched_claims, coverage_score}
         replaces current {verdict, confidence, issues, source_quotes}
```

### Tasks

**C1 — Pull and test gemma-aps:2b via Ollama**

Run `ollama pull gemma-aps:2b` (confirm model name in Ollama registry first; variant names
may differ). Feed one entity's raw source passages and verify it returns a proposition list.
Document what the raw output format looks like (newline-separated? JSON array? numbered list?).

**Files touched:** none (interactive test only)  
**Touches `tar_make()`?** No  
**Estimated effort:** 1 hr

**C2 — Implement APS → grounding check in `R/agentic_entity_fact_check.R`**

Rewrite `R/agentic_entity_fact_check.R`. Current function signature:
`fact_check_entity(entity_id, draft_markdown, source_passages, model, base_url)`
returns `{verdict, confidence, issues, source_quotes}`.

New implementation:
1. Call `ollama_generate()` with `gemma-aps:2b`, `format = NULL` (free-text), passing
   numbered source passages as the user prompt. Parse the response into a character vector
   of propositions.
2. Split the `draft_markdown` into claim sentences (simple period/newline split is sufficient;
   no model call).
3. For each claim: `any(stringr::str_detect(propositions, fixed(claim, ignore_case=TRUE)))`.
   Produce `matched_claims` and `unmatched_claims` vectors.
4. Return `list(matched_claims, unmatched_claims, coverage_score = mean(is_matched),
   pipeline_path = "aps_grounding")`.

The function must remain a drop-in replacement at the call site in `R/agentic_entity_dispatch.R`
— change the return shape there too (see C3).

**Files to change:**
- `R/agentic_entity_fact_check.R` — full replacement of verification logic  
**Touches `tar_make()`?** Yes — called from `agentic_entity_dispatch.R` which is a targets node.  
**Estimated effort:** 4 hrs

**C3 — Update dispatch and queue schema**

`R/agentic_entity_dispatch.R`: update the section that reads the fact-check result and
writes to `review_queue/queue.csv`. Replace `verdict`/`confidence`/`issues` columns with
`coverage_score`, `matched_claim_count`, `unmatched_claim_count`, `pipeline_path`.

`review_queue/queue.csv`: add columns `coverage_score` (numeric, 0–1), `matched_claim_count`
(integer), `unmatched_claim_count` (integer), `pipeline_path` (character). Existing rows:
backfill `pipeline_path = "critic_loop"` or `"agentic_no_critic"` as appropriate; leave
coverage columns `NA` for legacy rows.

**Files to change:**
- `R/agentic_entity_dispatch.R`
- `review_queue/queue.csv` (schema addition only; no existing data removed)  
**Touches `tar_make()`?** Yes  
**Estimated effort:** 2 hrs

**C4 — Shiny queue display**

`shiny/review_queue/app.R`: add a "Grounding" panel below the existing critic-findings card.
Display `matched_claim_count` as green badges, `unmatched_claims` as red badges (one per
unmatched sentence). Display `coverage_score` as a percentage. For legacy rows where
`pipeline_path == "critic_loop"`, show the existing `issues` list unchanged.

**Files to change:**
- `shiny/review_queue/app.R`  
**Touches `tar_make()`?** No (Shiny only)  
**Estimated effort:** 2 hrs

### Validation procedure

1. Run `tar_make()` with one entity (Basil, s02e37) in `AGENTIC_ENTITY_SESSION_IDS`.
2. Confirm the APS pass produces a non-empty proposition list (log it to
   `review_queue/agentic_intermediates/`).
3. Confirm the grounding check produces `matched_claims` and `unmatched_claims`.
4. Open Shiny queue; confirm the new grounding panel renders correctly.
5. Confirm `queue.csv` has `coverage_score`, `matched_claim_count`, `unmatched_claim_count`,
   `pipeline_path` populated.

### Definition of done

One entity passes APS → generator → grounding check end-to-end; result appears correctly in
Shiny queue with matched/unmatched claim display; `coverage_score` column present in queue.csv.

### Risk

**What breaks:** If `gemma-aps` is not available via Ollama under the expected model name,
Phase C is blocked entirely. Mitigation: confirm model availability in C1 before writing C2.

**If APS produces malformed output** (no parseable proposition list): `fact_check_entity()`
returns `coverage_score = NA` and routes to the review queue with `pipeline_path = "aps_error"`.
No crash; the reviewer sees the draft with an error badge.

**Rollback:** Restore previous `R/agentic_entity_fact_check.R` from git. The queue schema
addition (new columns) is backwards-compatible — old code ignores extra columns.

---

## Phase D — Gemma4 Native Function Calling (Optional)

**Goal:** Replace Ollama's `format =` constrained decoding (which degrades generation quality)
with Gemma4's native `<tool_call>` XML function-calling format for structured extraction.

**Prerequisite:** Phase C complete. This phase is marked **optional** — if Phase B+C produce
acceptable quality, Phase D may be deferred indefinitely.

### Architecture

Define R-side tool schemas for three tools:
- `extract_entity_fields(name, role, description, first_appearance, status)` — core entity metadata
- `cite_source_passage(field_name, passage_number, quote)` — source grounding per field
- `flag_uncertainty(field_name, reason)` — explicit uncertainty marker

Gemma4 orchestrates multi-step extraction as a tool-calling loop:
1. System prompt includes tool definitions in Gemma4's native format (Python-style function
   signatures or JSON schema, per model card)
2. Gemma4 generates one or more `<tool_call>` XML blocks in its response
3. R parses `<tool_call>` blocks with regex on raw response text (not via `format=` parameter)
4. R executes the "tool" (assembles the result struct) and feeds it back if multi-turn
5. Final response: assembled entity record from accumulated tool calls

### Tasks

**D1 — Implement `<tool_call>` parser in `R/ollama.R`**

Add a new function `parse_tool_calls(raw_response)` that:
- Extracts all `<tool_call>` blocks from the raw response string using regex
- Parses the JSON arguments inside each block
- Returns a named list: `list(tool_name = "extract_entity_fields", args = list(...))`

Handle malformed blocks (regex returns NULL → return empty list; caller treats as failed call).

**Files to change:**
- `R/ollama.R` — add `parse_tool_calls()`  
**Touches `tar_make()`?** No (new helper only; not yet called from pipeline)  
**Estimated effort:** 2 hrs

**D2 — Rewrite `R/agentic_entity_extract.R` as tool-calling loop**

Replace the single `ollama_generate()` call in `extract_entity()` with a multi-turn loop:
1. First call: system prompt with tool definitions, user prompt with numbered passages.
   `format = NULL` (no constrained decoding). `think = TRUE` if Phase A confirmed it works.
2. Parse `<tool_call>` blocks from response with `parse_tool_calls()`.
3. If tool calls present: assemble the entity record from accumulated calls. If `cite_source_passage`
   or `flag_uncertainty` calls are present, merge them into the record.
4. If no tool calls after max_turns (default 3): fall back to free-text extraction and log
   `pipeline_path = "tool_call_fallback"`.

The return value of `extract_entity()` must remain a named list with `entity_id`, `note_type`,
`extraction`, `timed_out` — same shape as today.

**Files to change:**
- `R/agentic_entity_extract.R` — rewrite `extract_entity()` inner loop; keep public signature  
**Touches `tar_make()`?** Yes  
**Estimated effort:** 4–6 hrs

### Validation procedure

1. Run `extract_entity()` interactively on Basil with D1+D2 changes.
2. Inspect raw Ollama response for `<tool_call>` blocks — confirm Gemma4 is generating them.
3. Confirm `parse_tool_calls()` extracts the arguments correctly.
4. Compare assembled entity record to Phase B baseline: is schema coverage higher? Are
   `cite_source_passage` calls grounding the extracted fields?

### Definition of done

Gemma4 produces a structured entity record via tool calls (not constrained decoding) for at
least one entity; `<tool_call>` blocks visible in raw response; `parse_tool_calls()` parses
them correctly; output quality compared to Phase B baseline and documented.

### Risk

**What breaks:** If Gemma4 via Ollama does not generate `<tool_call>` blocks in the expected
format (format may differ between Ollama versions and model variants), the parser returns an
empty list and the pipeline falls back to free-text extraction with `pipeline_path = "tool_call_fallback"`.
Reviewers see the same draft; no crash.

**Rollback:** Restore previous `R/agentic_entity_extract.R` from git. `parse_tool_calls()` in
`R/ollama.R` is additive and does not affect any existing code path.

---

## Sequence summary

```
Phase A (diagnostics, no code) → Phase B (prompt + context) → Phase C (APS critic) → Phase D (optional, tool calling)
```

Phases B, C, D each depend on the previous phase being validated. Do not start B without
Phase A findings written. Do not start C without Phase B validated in Shiny queue.

---

## What we are NOT doing

- **Swapping Gemma4 for a different generator model.** `OLLAMA_MODEL = gemma4:latest` is the
  generator. This plan optimizes how we use it, not what it is. Model swaps require explicit
  instruction.

- **Touching `llama3.1:8b` or the legacy critic loop.** `OLLAMA_CRITIC_MODEL` is not in scope
  until Phase C ships and APS replaces the citation-scoring step. Until then, the legacy critic
  loop runs unchanged for non-agentic episodes.

- **Changing the Shiny review UI** beyond the grounding panel added in Phase C4. The Shiny
  consolidation (merging `shiny/app.R` into `shiny/review_queue/app.R`) is a separate post-rollout
  track.

- **Any Phase 4.2 wet run #3 work.** Wet run #3 is explicitly blocked until this optimization
  plan lands. The `AGENTIC_ENTITY_SESSION_IDS` opt-in vector remains `c("s02e37")` during this
  phase; do not expand it until Phase B is validated.

---

## Phase A Findings

**Date completed:** 2026-05-14

### A1 — Thinking mode via Ollama

Tested three approaches on `gemma4:latest`:

**`think = TRUE` via `/api/chat`:** Silently ignored. `thinking` field in response is absent.
No `<thinking>`, `<think>`, `<|think|>`, or `<|thinking|>` tokens appear in `content`.

**`<|think|>` injected into system prompt via `/api/chat`:** Does not activate thinking.
Response is identical in structure to a standard call — no thinking tokens, just the answer.

**Raw generate endpoint (`/api/generate`, `raw: true`) with `<start_of_turn>model\n<think>\n` prefix:**
Works. The model generates a genuine thinking block, ending with `</think>`, followed by a clean
answer. Example output parsed: thinking block contained step-by-step reasoning about the passage
("The user wants me to extract...", "The phrase 'everyone knew the halfling rogue' suggests..."),
then `</think>`, then concise answer ("Basil, halfling rogue").

**Conclusion:** Thinking mode for Gemma4 requires the raw `/api/generate` endpoint with the
Gemma4 native chat template: `<start_of_turn>system\n{system}<end_of_turn>\n<start_of_turn>user\n{user}<end_of_turn>\n<start_of_turn>model\n<think>\n`. The `/api/chat` endpoint cannot activate it.

**Implication for Phase B:** The `format =` (constrained decoding) parameter is incompatible with
the raw generate endpoint. Activating thinking requires dropping the JSON Schema enforcement.
Since constrained decoding is already failing (producing wrong citation indices), this is an
acceptable trade: free-text JSON output + thinking vs. schema-constrained output without thinking.
The existing `.parse_skill_json()` / `.strip_json_fences()` pipeline already handles free-text JSON.

### A2 — Claude-ism audit of entity skill system prompts

All four files (`05_extract_pc`, `06_extract_npc`, `07_extract_location`, `08_extract_faction`)
are already concise (21–26 lines). No multi-paragraph XML preambles, no `<rules>` tags, no
chain-of-thought cues. The prompts were likely already cleaned up during Phase 4.2 setup.

**Identified Claude-isms:**

1. **Markdown headers as section dividers** (`## What to extract`, `## Citation rules`,
   `## Output format`) — structural pattern common in Claude system prompts; Gemma4's training
   doesn't require this structure and it may add unnecessary tokens.

2. **`Return ONLY the JSON object. No preamble, no markdown fences, no explanation.`** —
   Claude-specific phrasing. With `format=` removed, a simpler instruction suffices.
   With thinking mode, the model naturally separates reasoning from output.

3. **ALL-CAPS negation** (`Do NOT invent details. Do NOT infer.`) — Claude-style emphasis.
   Gemma4's training does not depend on capitalization for instruction weight.

4. **Citation rule duplication** — "must cite a passage number" appears in both the system prompt
   and the user template. The user template's inline reminder is redundant once the system prompt
   establishes the rule.

5. **`set 'line' to the N from the 'PASSAGE [N]:' label`** — overly specific citation wording
   that, combined with constrained decoding, produced hallucinated integer indices. With thinking
   mode and no `format=`, reframing as "set line to the passage number or null if uncertain" 
   reduces hallucination pressure while keeping the citation structure.

**Not Claude-isms (keep as-is):**
- The opening "You are a D&D session note-taker..." persona statement — universal across model families.
- The `[unclear]` instruction for garbled transcript text — content policy, not style.
- The no-fabrication constraint — domain requirement.
- The PC name list in the NPC prompt — factual context.

---

## Phase B Findings

**Date completed:** 2026-05-14

### B1 — System prompt rewrites

All four system prompt files (`05_extract_pc`, `06_extract_npc`, `07_extract_location`,
`08_extract_faction`) rewritten. Removed markdown headers as section dividers; replaced
with direct field listings in the format `fieldname: {...}  — description`. Added explicit
type indicators for array fields (`ARRAY of strings`, `ARRAY of objects`) to prevent the
model from applying `{value, line}` structure to everything. Removed "Return ONLY the JSON
object. No preamble, no markdown fences, no explanation." in favour of "Respond with only the
JSON object." (shorter, less Claude-specific phrasing).

User templates also simplified: removed the redundant inline citation rule (the system prompt
already establishes the rule); kept the entity header and passage block.

### B2 — Thinking mode for entity extraction — NOT viable for VTT text

Testing revealed a hard ceiling on thinking mode with raw VTT passages:

| Condition | Result |
|---|---|
| Short clean prose (~70 words, `/api/chat`) | FAILS — `think=TRUE` silently ignored |
| Short clean prose (~70 words, `/api/generate` raw) | WORKS — proper thinking+answer pattern |
| VTT passages, 2 passages (~3000 words), raw | TIMEOUT — 90s Ollama limit hit |
| VTT passages, 5 passages (~6873 words), raw | LOOPS — never closes `</think>`, fills context |

Root cause: raw VTT transcript text (speaker labels, timestamps, crosstalk, garbled words) is
dense and noisy. The model cannot find a stable "I have processed this" anchor to end the
thinking phase. It loops on repeated restatements of the task ("The user has presented a very
long string of text...").

**Decision:** `ollama_generate_thinking()` is implemented and remains in `R/ollama.R` for
future use cases with cleaner/shorter inputs. It is NOT used for entity extraction.
Entity extraction retains `ollama_generate()` with `format = entity_schema(note_type)`.

### B3 — Word limit raised to 8,000

`AGENTIC_ENTITY_PASSAGE_WORD_LIMIT` raised from 4,000L to 8,000L. At the observed throughput
(~12s per 3,000 words without thinking), 8,000 words comfortably fits within the 90s Ollama
timeout. The Basil entity record has 6,873 words across 5 passages — all passages now fit.

### B4 — `entity_aliases` added to entity records

`aggregate_entity_passages()` in `R/source_c.R` now:
1. Reads `pc_alias` rows from `protected_entities.csv` and builds a canonical-slug →
   alias-slug lookup after Step 1.5 (canonical routing).
2. Passes `entity_aliases` to `extract_relevant_sentences()` so the sentence-window
   filter hits on alias names ("Captain", "the_captain") as well as the canonical name
   ("Basil"). Previously, passages for Basil were stripped of Captain-references because
   the window only searched for "Basil".
3. Populates `rec$entity_aliases` on every entity record so `extract_entity()` can pass
   alias names to the extraction prompt.

Also hoisted `prot_df` load before the `if (length(routing_map) > 0L)` block so it is
always defined when Step 3 runs.

**Impact on `extract_relevant_sentences()`:** Added `aliases = character(0)` parameter.
All names (canonical + aliases) are OR'd into a single regex pattern for sentence matching.
Backward-compatible: default is empty vector (no aliases → original behaviour).

### B5 — Test updates

`tests/testthat/test-agentic_entity_extract.R`: stubs updated from `.call_ollama_skill`
to `ollama_generate` (the function now called by `extract_entity()`). All 19 tests pass.
Pre-existing `test-git_commit.R` failures (7) are unchanged.

### B — Quality comparison vs. wet run #2

Basil extraction with B-series changes (alias-aware sentence window, new prompts, 8K limit):
- Word count fed to model: 2,974 (from 6,873 via alias-aware windowing — 57% reduction)
- Extraction completed without timeout or NULL result ✅
- Description content grounded in actual passage phrases ✅ (improvement from wet run #2 template fill-in)
- Identity confusion: persists — model described "She/her" and assigned "Librarian" alias ❌
- `line` field: still `{}` (constrained decoding Gemma4 bug — Phase C addresses) ❌

**Assessment:** Phase B improvements are structural, not yet quality-visible on the hardest
entity (Basil/Captain identity split). The alias-aware sentence windowing reduces context
and is immediately beneficial for all entities. Identity confusion and `line: {}` are
Phase C's domain (APS grounding will catch claims not supported by the proposition set).
