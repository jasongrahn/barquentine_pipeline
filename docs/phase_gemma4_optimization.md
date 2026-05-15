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

## Phase D Assessment — D0 Wet Run Results (s02e36, 2026-05-15)

CURRENT_SESSION=s02e36, AGENTIC_ENTITY_SESSION_IDS includes "s02e36". 6 entities kept after passage aggregation: lumi (pc), room (pc), attorrnash (npc), ted (npc), basil (pc), the_giff_flotilla (location).

**Coverage scores:**

| entity | note_type | coverage_score | matched | unmatched | aps_props |
|---|---|---|---|---|---|
| lumi | pc | 0.0 | 0 | 7 | 68 |
| room | pc | 0.0 | 0 | 6 | 7 |
| attorrnash | npc | 0.0 | 0 | 5 | 4 |
| ted | npc | 0.0 | 0 | 1 | 19 |
| basil | pc | 0.0 | 0 | 2 | 27 |
| the_giff_flotilla | location | 0.0 | 0 | 1 | 20 |

All 6 entities: coverage_score = 0.0. Threshold condition (< 0.3 for majority) met.

**Identity confusion observed in drafts:**

- lumi: "The provided text does not contain explicit biographical information about a character" — model refused to identify lumi in passages. Then generic cooking-competition template.
- room: "A character participating in a cooking/culinary competition setting" — no Room-specific facts.
- attorrnash: Misidentified as "a professional chef hosting the competition" — wrong role, wrong identity.
- ted: 1 sentence, grounded ("The Admiral mentions Ted's progress on the astral plane") but draft is too thin to evaluate further.
- basil: 2 sentences, partially grounded ("bags under his eyes", "King Burger's Summons"). No clear confusion.
- the_giff_flotilla: "The challenge/competition setup / The appearance of the three teams" — generic template, zero location specifics.

4/6 entities show clear identity confusion or template output. 1 (basil) is partially grounded. 1 (ted) is sparse but grounded.

**Two causes for coverage_score=0:**

1. APS matching algorithm direction bug: code does `str_detect(proposition, claim)` — checks if the full claim text appears INSIDE a short proposition. A 50-word claim sentence will never appear as a substring of a 10-word proposition. Even grounded output would score 0. Coverage_score is not a reliable signal until this is fixed.

2. Gemma4 template output: 4/6 drafts are generic "character in cooking competition" templates that don't name the entity. These would fail grounding even with a correct matcher.

**D0 Decision: PROCEED with Phase D.**

Condition met: coverage_score < 0.3 for 6/6 entities AND unmatched claims are model-output failures (identity confusion / template fill), not APS noise. Removing format= may reduce template output. Note: Phase D cannot fix identity confusion alone — the underlying cause is likely that passages contain multiple characters and the model doesn't anchor to the target entity name. Tool calling will be tested; if output is still identity-confused, move to entity-name anchoring in prompts as a separate fix.

---

## Phase D — Gemma4 Tool Calling — DONE (2026-05-15)

Replace `format=` with native `<tool_call>` XML function calling.

**D1 — DONE:** `parse_tool_calls(raw)` added to `R/ollama.R`.
- Regex-extracts all `(?s)<tool_call>(.*?)</tool_call>` blocks (DOTALL, handles multiline JSON).
- Parses each block with `fromJSON()`.
- Returns list of parsed objects or NULL on no valid blocks.

**D2 — DONE:** `extract_entity()` in `R/agentic_entity_extract.R` rewritten as tool-calling loop.
- `.entity_tc_system()` helper builds augmented system prompt: base system + JSON tool definition + `<tool_call>` output instruction.
- Loop: 3 turns of `ollama_generate(format=NULL)` → `parse_tool_calls()` → match on `name == "extract_<type>"` → return `extraction=$arguments, pipeline_path="tool_calling"`.
- On timed_out in any turn: return `pipeline_path="tool_call_timeout"`.
- After 3 failed turns: fallback to original `format=entity_schema(note_type)` path → `pipeline_path="tool_call_fallback"`.
- Public signature unchanged. Return shape gains `pipeline_path` field (ignored by existing callers).

**Tests:** 19/19 pass (stubs return plain JSON → tool-call turns fail → fallback runs correctly). 7 pre-existing git_commit failures unchanged.

**Done when Gemma4 produces entity record via tool calls for at least one entity:** Not yet confirmed on live hardware (requires next wet run). Fallback path guarantees no regression — if tool calling never fires, behavior is identical to pre-D2.

Rollback: `git revert R/agentic_entity_extract.R`; `parse_tool_calls()` and `.entity_tc_system()` are additive/safe.

---

## Phase E — Next Steps (from D0 findings)

Two unresolved issues. Fix in order.

**E1 — Fix APS matcher direction bug (one-liner)**

File: `R/agentic_entity_fact_check.R`, line ~117.

Current:
```r
any(str_detect(propositions, regex(claim, ignore_case = TRUE)))
```
Bug: looks for the full claim text as a substring inside a short proposition. Always FALSE.

Fix:
```r
any(str_detect(claim, regex(propositions, ignore_case = TRUE)))
```
This checks whether any proposition text appears as a substring inside the claim. Still imperfect (exact substring match) but directionally correct. Rerun s02e36 after fix and record new coverage_score distribution.

**E2 — Verify Phase D tool calling on live hardware**

After E1, run `tar_make()` with s02e36. Check `pipeline_path` in queue.csv:
- `tool_calling` → Gemma4 emitted valid `<tool_call>` XML. Compare draft quality to Phase B/D0 baseline.
- `tool_call_fallback` (all rows) → `.entity_tc_system()` prompt format not recognized by Gemma4 under Ollama. If so, try: (a) use Ollama's native `/api/chat` `tools` parameter instead of XML-in-system-prompt, or (b) defer tool calling, accept `format=` constrained decoding as permanent.

**E3 — Identity confusion root cause (if E2 still produces templates)**

If tool calling fires but drafts are still identity-confused, the issue is that VTT passages contain 4+ characters and gemma4 doesn't anchor to the target entity name. Candidate fix: prepend a one-line anchor to the user prompt — "Focus ONLY on {entity_name}. Ignore all other characters." — before the passage block. Test on basil and lumi first.

---

## Phase E Findings (2026-05-15, s02e36)

**E1 — APS matcher direction fix confirmed**

One-liner fix applied to `R/agentic_entity_fact_check.R` line 118.
Two direction-locking tests added to `test-agentic_entity_fact_check.R`; 29/29 pass.

**E2 — Coverage scores after E1 fix**

| entity | note_type | coverage_score | matched | unmatched | extraction_path |
|---|---|---|---|---|---|
| attorrnash | npc | 0.20 | 1 | 4 | tool_call_fallback |
| basil | pc | 0.00 | 0 | 2 | tool_call_fallback |
| lumi | pc | 0.00 | 0 | 5 | tool_call_fallback |
| room | pc | 0.00 | 0 | 7 | tool_call_fallback |
| ted | npc | 0.00 | 0 | 1 | **tool_calling** |
| the_giff_flotilla | location | 0.00 | 0 | 6 | tool_call_fallback |

**E2 — Tool calling results**

- 1/6 entities fired `tool_calling` (ted). 5/6 fell back to `format=` constrained decoding.
- ted's `tool_calling` draft is all-nulls (valid `<tool_call>` XML emitted but arguments populated with null). Fallback (basil) produced grounded content. Tool calling path works syntactically but not semantically — Gemma4 emits the function call scaffold but doesn't populate fields.
- Conclusion: Ollama XML-in-system-prompt approach produces null-fill on 5/6 entities. Try Ollama native `/api/chat` `tools` parameter before deferring.

**E2 — Identity confusion persists (E3 triggered)**

- attorrnash draft: describes "Room's cooking" on the attorrnash page — identity confusion confirmed.
- lumi draft: generic magical performer, N/A overview.
- room draft: generic cooking competitor template.
- ted draft: all nulls (tool_calling null-fill).
- basil draft: partially grounded ("Spelljammer's Supper Nova", "cautious/thoughtful") — best outcome.

**E3 — Focus anchor applied**

Added "Focus ONLY on {entity_name}. Ignore all other characters." immediately before the SOURCE PASSAGES block in all four entity skills (05–08 user_template.md). Committed. Requires wet run to validate.

---

## P1: Captain Stale-Status Investigation (2026-05-15)

Bug description: "captain row shows status=merged with a fresh draft after s02e35 run."

After s02e36 run, queue.csv shows:
- captain: status=rejected (from s02e35 UI action), enqueued_at=2026-05-12
- the_captain: status=rejected (from s02e35 UI action), enqueued_at=2026-05-12
- basil: status=pending (fresh from today's run), enqueued_at=2026-05-14

**Root cause:** Canonical routing (added in Phase B) merges captain+the_captain passages into basil before dispatch. No captain or the_captain staging files are ever written. `consolidate_queue()` only overwrites rows whose section_id appears in staging; since captain/the_captain are absent from staging, their prior UI-set statuses persist. This is correct behavior: the UI resolved captain as rejected; canonical routing then directed all future captain data to basil.

**consolidate_queue() logic is correct:** line `existing <- existing[!existing$section_id %in% new_rows$section_id, ]` properly drops-and-replaces on section_id match. No bug.

The "merged+fresh-draft" scenario from s02e35 pre-dates canonical routing and was a one-time state. It cannot recur in current code because captain no longer gets its own staging file.

**Verdict: Not a bug. No fix needed. Remove from P1.**
