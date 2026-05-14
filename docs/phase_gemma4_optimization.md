# Gemma4 Optimization Plan
Branch: `feature/gemma4-optimization`

## Problem
Wet run #2: gemma4 can't produce passage citation indices under Ollama `format=` constrained decoding.
Four mismatches: (1) citation indices wrong model job, (2) thinking unused, (3) context underused, (4) prompts Claude-flavored.

## NOT doing
- Swap gemma4 for another generator
- Touch llama3.1:8b or legacy critic until Phase C ships
- Shiny consolidation (separate track)
- Wet run #3 until this plan lands

---

## Phase A — DONE (2026-05-14)

**A1 thinking mode test results:**

| Method | Result |
|---|---|
| `think=TRUE` via `/api/chat` | silently ignored |
| `<\|think\|>` in system prompt via `/api/chat` | no effect |
| `/api/generate` raw, prompt ends `<start_of_turn>model\n<think>\n` | works — real thinking block + answer |
| VTT passages 2x (~3000w) via raw | TIMEOUT at 90s |
| VTT passages 5x (~6873w) via raw | infinite loop, never closes `</think>` |

Conclusion: thinking not viable for VTT entity extraction. `ollama_generate_thinking()` added to `R/ollama.R` for future short-input use; not called by `extract_entity()`.

**A2 Claude-ism audit:** prompts already lean. Issues found:
- `## section headers` — not needed by Gemma4
- `Return ONLY the JSON object. No preamble...` — Claude phrasing
- ALL-CAPS `Do NOT` — Claude emphasis
- citation rule duplicated in system + user template
- `set 'line' to the N from PASSAGE [N]` — specific phrasing pressures hallucinated integers; changed to "or null if uncertain"

---

## Phase B — DONE (2026-05-14)

**What changed:**
- `agents/wiki_skills/05-08/system.md` — rewritten; no `##` headers; explicit type per field (`single object` vs `ARRAY`); shorter closing instruction
- `agents/wiki_skills/05-08/user_template.md` — simplified; removed duplicate citation rule
- `R/ollama.R` — added `ollama_generate_thinking()` (not used in pipeline)
- `config.R` — `AGENTIC_ENTITY_PASSAGE_WORD_LIMIT` 4000L → 8000L
- `R/source_c.R` — `prot_df` hoisted; alias lookup built from `pc_alias` rows; `extract_relevant_sentences()` gets `aliases=` param (OR-matches canonical + aliases); `rec$entity_aliases` populated on every record
- `tests/testthat/test-agentic_entity_extract.R` — stubs changed from `.call_ollama_skill` → `ollama_generate`; 19/19 pass; 7 pre-existing git_commit failures unchanged

**Why `format=` still required:** without it, gemma4 ignores JSON instructions and outputs markdown prose. Constrained decoding stays until Phase C.

**Basil test result:**
- Alias-aware windowing: 6873w → 2974w (57% reduction)
- No timeout, no NULL extraction
- Description grounded in passages (improvement over wet run #2 template fill)
- Identity confusion persists (wrong gender, "Librarian" alias hallucinated)
- `line: {}` persists (constrained decoding bug)
→ Both remaining issues are Phase C's job

---

## Phase C — APS Critic Replacement

**Goal:** replace broken citation-index fact-checker with proposition-based grounding. No constrained decoding.

**Architecture:**
```
source passages → gemma-aps:2b → proposition list
draft markdown  → split sentences → match against propositions → {matched, unmatched, coverage_score}
```

**C1** — confirm `gemma-aps` model name in Ollama registry; pull; feed one entity's passages; record output format. No code.

**C2** — rewrite `R/agentic_entity_fact_check.R`
- APS call: `ollama_generate()`, `format=NULL`, source passages as prompt → parse into `character` vector
- Draft split: strip frontmatter + `##` headers; split on `.` and newlines
- Match: `stringr::str_detect(propositions, claim, ignore_case=TRUE)` per claim
- Return: `list(matched_claims, unmatched_claims, coverage_score, pipeline_path="aps_grounding", aps_proposition_count)`
- On APS timeout or empty list: `coverage_score=NA`, `pipeline_path="aps_error"`, no crash

**C3** — `R/agentic_entity_dispatch.R` + `review_queue/queue.csv`
- Dispatch: read `coverage_score / matched_claim_count / unmatched_claim_count / pipeline_path` instead of `verdict/confidence/issues`
- queue.csv: ADD columns `coverage_score`, `matched_claim_count`, `unmatched_claim_count`, `pipeline_path`; keep old columns for legacy rows; backfill `pipeline_path` on existing rows

**C4** — `shiny/review_queue/app.R`
- Add grounding panel below critic-findings card
- Green badges: matched claims; red badges: unmatched; `coverage_score` as %
- Legacy rows (`pipeline_path=="critic_loop"` or NA): show existing verdict/issues unchanged

**Done when:** one entity end-to-end APS → draft → grounding check; Shiny shows panel; queue.csv has new columns.

**Risk:** if `gemma-aps` not available in Ollama → C1 blocks everything. Confirm before C2.
Rollback: `git revert R/agentic_entity_fact_check.R`; queue schema addition is additive/safe.

---

## Phase C Findings (2026-05-14)

**C1 — APS model confirmed**

Model in Ollama registry: `gurubot/gemma-2b-aps-it:Q4_K_M`

Fed Attorrnash source passages (5 passages, ~7510 words) via `ollama_generate(prompt=passages_text, system_prompt="", model="gurubot/gemma-2b-aps-it:Q4_K_M", format=NULL, think=FALSE)`.

**Raw output format:**
```
: PROPOSITIONS:
<s>
- <proposition text>
- <proposition text>
...
</s>
```

**Key observations:**
- Header line is `: PROPOSITIONS:\n<s>\n`
- Each proposition is a hyphen-bullet line: `- <text>`
- Output ends with `</s>` sentinel
- At 7510 words: only ~8 propositions generated (model hits its generation limit early)
- At ~3004 words (2 passages): still ~8 short propositions
- Propositions reflect surface utterances from the text, not structured facts
- Identity confusion present: propositions about "The Admiral" even when feeding Attorrnash passages (same text contains both characters)

**Parsing strategy:** strip `: PROPOSITIONS:` header and `<s>`/`</s>` tags; split on newlines; strip leading `[-*0-9. ]+`; drop empty strings and `</s>`.

---

## Phase D — Gemma4 Tool Calling (Optional, after C)

Replace `format=` with native `<tool_call>` XML function calling.

**D1** — add `parse_tool_calls(raw)` to `R/ollama.R` — regex extracts `<tool_call>` blocks, parses JSON args

**D2** — rewrite `extract_entity()` as tool-calling loop: `format=NULL`, parse `<tool_call>` blocks, assemble record; fallback to free-text if no calls after 3 turns (`pipeline_path="tool_call_fallback"`)

**Done when:** Gemma4 produces entity record via tool calls; output compared to Phase B baseline.

Rollback: `git revert R/agentic_entity_extract.R`; `parse_tool_calls()` is additive.
