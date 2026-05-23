# Gemma4 Optimization Plan — Active
Branch: `feature/gemma4-optimization`
History (Phases A–E, D0/E wet runs, P1): `docs/phase_gemma4_history.md`

## Problem
Wet run #2: gemma4 can't produce passage citation indices under Ollama `format=` constrained decoding.
Four mismatches: (1) citation indices wrong model job, (2) thinking unused, (3) context underused, (4) prompts Claude-flavored.

## NOT doing
- Swap gemma4 for another generator
- Touch llama3.1:8b or legacy critic until Phase C ships
- Shiny consolidation (separate track)
- Wet run #3 until this plan lands

## Status entering Phase F
- Phases A–E: DONE
- E3 focus anchor committed (wet run pending)
- Tool calling (XML-in-system-prompt): RETIRED — 1/6 fire rate, null-fill confirmed
- APS grounding: ACTIVE but being replaced by F4 source-sentence substring
- Identity confusion: dominant issue — 4/6 entities write about the wrong character

---

## Phase F — Identity Anchoring + Tool Calling Resolution

Root-cause analysis from D0/E wet runs:

1. **Identity confusion** (dominant) — Gemma4 writes about the most prominent character in multi-character passages, not the target entity. Responsible for 4/6 template/wrong-character outputs in s02e36.
2. **format= template fill** — constrained decoding satisfies schema without semantic grounding. Partially downstream of #1; may self-correct when #1 is fixed.
3. **Tool calling null-fill** — XML-in-system-prompt produces null arguments. Untested: Ollama native `/api/chat` `tools=` parameter.
4. **APS wrong tool** — proposition extraction ≠ factual consistency verification. ~8 propositions regardless of input length; identity confusion fundamental; not fixable by tuning. Replace with source-sentence substring.

---

### Phase F — Canonical Execution Order (Panel Consensus, 2026-05-15)

```
IMMEDIATE — DONE (2026-05-15):
  F3pre DONE — zero tool template hits; tool calling retired from extract_entity()
  F2a   DONE — positive focus anchor in all four user_template.md files (recency bias added)
  F0.5  DONE — format=NULL + R-side parse (fence-strip→JSON→schema validate→NULL)
  F4    DONE — APS replaced by source-sentence substring in agentic_entity_fact_check.R
  F0    PENDING — Bug #15260 verification (manual Ollama run required)
        - Real multi-character s02e36 passage (NOT a trivial stub)
        - Run: think=FALSE vs think=NULL; compare structurally + semantically

IMMEDIATE — DONE (2026-05-22):
  F1    DONE — 3/5 dispatched entities correct (basil, lumi, room); attorrnash filtered
              by MIN_ENTITY_CHUNK_COUNT raise (correct); ted empty (sparse passages)
  F2    DONE — vault note prepend implemented; gate working; identity confusion resolved
              for all 3 PCs across 4 wet runs; ted anchor injected, correctly empty

REMAINING ISSUES (deferred):
  coverage_score=0  substring match too strict for paraphrased claims; need looser match
  attorrnash        name may be spelled differently in VTT passages; grep to confirm
  the_giff_flotilla location schema validation failure; check required fields vs gemma4 output
  ted               empty draft is correct behavior (barely appears in s02e36)

DEFER:
  Phase G (two-pass) — only if F2/F2a/F3 insufficient
  MiniCheck — only if substring false-negative rate on paraphrased claims unacceptably high
```

---

### F0 — Bug #15260 Verification

Bug: `think=FALSE` + `format=` silently disables constrained decoding. If live, all s02e36 schema-constrained quality data is suspect.

Checklist:
- [ ] Use a real multi-character s02e36 source passage
- [ ] Run same passage: think=FALSE vs think=NULL; compare structurally + semantically
- [ ] If outputs differ → bug live; format= fallback path untrustworthy
- [ ] If outputs same → bug not live; format= fallback operational

---

### F0.5 — Confirm format=NULL + R-side parse fallback

Required steps (NOT a one-liner, ~15 lines):
1. Fence-strip: `.strip_json_fences()` (already in codebase)
2. `tryCatch(fromJSON(stripped), error = function(e) NULL)`
3. Schema validate output against `entity_schema(note_type)`
4. Return NULL on validation failure, not crash

Confirm this path produces valid entity records on a real s02e36 passage before treating it as a usable fallback.

---

### F2 — Feed existing vault note as identity anchor

For entities with existing vault notes (PCs: basil, lumi, room), prepend the vault note to the extraction user prompt:

```
Here is the current wiki page for {entity_name}. Use this as an identity anchor —
the gender, role, and relationships listed here are established facts. Extract
only new information from the passages below that adds to or contradicts this page.

EXISTING NOTE:
{existing_note}
```

Implementation:
- `extract_entity()` (`R/agentic_entity_extract.R`): resolve vault note path; read file if non-empty; pass as `existing_note` glue variable.
- `user_template.md` for all four entity skills: add optional `{existing_note}` block (empty string when no vault file).
- Gate: inject only when vault file exists and `nchar(existing_note) > 0`.

Success criterion: basil and lumi drafts match or exceed Phase B "partially grounded" baseline.

---

### F2a — Orientation sentence for entities without vault notes

Replaces E3 "Focus ONLY on {entity_name}. Ignore all other characters." with positive framing:

```
Target entity: {entity_name} (type: {note_type}). Focus exclusively on this entity.
All other characters mentioned in the passages are context, not the subject.
```

- user_template.md change only; no R code required.
- Remove E3 negation framing entirely — likely backfires on small models.
- Add directive at END of user prompt (after SOURCE PASSAGES block) to exploit recency bias.

Success criterion: attorrnash draft correctly identifies the entity as a dowar cartomancer, not "a chef."

---

### F3 — Ollama native /api/chat tools parameter

Pre-check first:
```bash
ollama show gemma4 --modelfile | grep '{{ if .Tools }}'
```
Zero hits → skip F3, go to retire path.

If template present:
- Add `ollama_chat_with_tools(prompt, system_prompt, tools, model, base_url)` to `R/ollama.R`.
- Parse: `message$tool_calls[[1]][["function"]]$arguments` (NOT `$function$` — reserved keyword).
- Test standalone on basil before touching `extract_entity()`.
- Threshold ≥ 5/6 non-null non-empty to replace XML approach.
- If < 5/6: retire tool calling entirely; remove 3-turn loop + `.entity_tc_system()`.

---

### F4 — Replace APS with source-sentence substring

Rewrite `R/agentic_entity_fact_check.R`:
- Remove APS model call and `.parse_aps_propositions()`
- Replace with:
  ```r
  source_text <- paste(entity_record$source_passages, collapse = " ")
  is_matched <- vapply(claims, function(claim) {
    stringr::str_detect(source_text, stringr::fixed(claim, ignore_case = TRUE))
  }, logical(1))
  ```
  Direction: `claim` inside `source_text`. NOT the reverse.
- Return shape unchanged: `coverage_score`, `matched_claims`, `unmatched_claims`.
- Column rename blocked: do NOT rename `aps_proposition_count` until Shiny UI audited. Populate with source sentence count under existing column name.

Plumbing fix required: `aps_proposition_count` absent from `dispatch_agentic_entity()` scope — add `aps_proposition_count <- fact_check_summary$aps_proposition_count %||% 0L` in dispatch.

---

## Phase F — Success Criteria (overall)

- ≥ 4/6 entities from s02e36 write about the correct character (identity confusion ≤ 2/6).
- ≥ 3/6 entities have `coverage_score > 0` (at least one grounded claim matched).
- No entity draft contains named content clearly about a different specific character.
- basil and lumi draft quality matches or exceeds Phase B "partially grounded" baseline.

## Phase F — Ruled-Out Approaches (do not re-evaluate)

| Approach | Phase tested | Outcome |
|---|---|---|
| Gemma4 thinking via `/api/chat` | A | Silently ignored |
| `<\|think\|>` in system prompt via `/api/chat` | A | No effect |
| VTT full-length input to raw thinking | A | Timeout / infinite loop |
| Raise `AGENTIC_ENTITY_PASSAGE_WORD_LIMIT` to 128K | B | Window raised to 8000L; timeout risk on full context |
| XML `<tool_call>` in system prompt | D/E | 1/6 fire rate, null-fill on arguments |
| APS as primary grounding verifier | C/D0 | ~8 propositions, identity confusion in model itself |
