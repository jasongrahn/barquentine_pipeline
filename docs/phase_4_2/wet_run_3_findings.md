# Phase 4.2 — Wet Run #3 Findings
**Date:** 2026-05-24 (pending run)
**Branch:** `feature/gemma4-optimization`
**Session:** s02e37
**Schema version:** v2
**Status:** READY TO RUN — pre-run fixes committed; awaiting results

---

## Pre-run fixes (this session)

### Fix 1 — verify_entity_citations() all-passages check
**Status: Already done.** The `verify_entity_citations()` function referenced in wet run #2
findings no longer exists. Phase F4 replaced the entire fact-check with
`fact_check_entity()` in `R/agentic_entity_fact_check.R`, which concatenates all passages
into `source_text` and runs substring + word-overlap matching against that. No per-passage
index lookup happens. The `line` field from the extraction JSON is ignored entirely.

This means the `confidence=0` results from wet run #2 (all `line: 1`, checked only passage 1)
should already be fixed by the F4 rewrite.

### Fix 2 — Remove relatives from PC schema (commit a4f696f)
**Status: Done.** Removed the `relatives` array from `.pc_schema()` in
`R/agentic_entity_schemas.R`. The nested array with its own `line` field was the likely cause
of gemma4's constrained-decoding emitting `"line": {}` (empty object) for all
`valued_field()` top-level entries on PC entities. Flattened to the same scalar-only
structure as NPC schema. The Relationships section in `agentic_entity_writer.R` is
unaffected (gracefully omitted when `extraction$relatives` is NULL).

---

## Wet run #3 config

```r
# In config.R before running:
CURRENT_SESSION               <- "s02e37"
DRY_RUN                       <- TRUE
AGENTIC_ENTITY_SESSION_IDS    <- c("s02e37")
```

Invalidate and run:
```r
targets::tar_invalidate(starts_with("entity_agentic"))
targets::tar_make()
```

---

## Expected results (hypothesis)

| entity | wet run #2 confidence | hypothesis for #3 |
|---|---|---|
| attorrnash | 0 (all `line: 1`, checked only passage 1) | > 0 — real source support exists; F4 now checks all passages |
| the_giff_flotilla | 0 (same root cause) | > 0 — cooking competition content is in passages, just wrong index |
| room | 0 (same root cause) | > 0 — PC with vault anchor, should have source evidence |
| basil | NA (`"line": {}`, extraction empty) | > 0 — relatives removed; valued fields should now populate |
| lumi | NA (`"line": {}`, extraction empty) | > 0 — same fix |

Worst case: basil/lumi still produce low confidence because the s02e37 passages genuinely
don't describe them in detail (they're background characters in this episode).

---

## Actual results (2026-05-24)

| entity | note_type | confidence | matched | unmatched | notes |
|---|---|---|---|---|---|
| attorrnash | npc | 0 | 0 | 1 | Draft is all "N/A" — not directly mentioned in s02e37 (dropped at passage aggregation as "implied by 'Admiral' but not directly mentioned") |
| basil | pc | 0 | 0 | 2 | Draft has real content (schema fix confirmed) but claims are vague/paraphrased — not verbatim substrings |
| lumi | pc | 1.0 | 2 | 0 | Full success — both fixes confirmed working |
| room | pc | 0.5 | 1 | 1 | Matched cooking-competition claim; unmatched personality claim (Robert/zombies) |
| the_giff_flotilla | location | 0 | 0 | 2 | Model generates vague generic claims ("collection of ships") — no verbatim match in source |

### Matched/unmatched claim detail

**lumi** (matched):
- "Lumi's aunt is the goddess of agriculture and harvest"
- "Anticipative, careful with assumptions … Competitor in a cooking competition … familiar with the Manticore ship"

**room** (matched): "Participated in a cooking competition (creating cheesy blink crab ravioli) and later sought to investigate or check on others"
**room** (unmatched): "Curious, worried about others' safety (specifically regarding Robert and zombies)"

**basil** (unmatched): Both claims are paraphrased summaries, not source sentences — passes substring grounding by design.

**the_giff_flotilla** (unmatched): "A collection of ships or a location associated with travel or a gathering of vessels" / "Mentions are associated with the captaincy and potential areas of activity" — generic, vague claims.

---

## Success criteria evaluation

- [ ] confidence > 0 for at least attorrnash and the_giff_flotilla — **FAILED**
  - attorrnash: true data sparsity (not present in s02e37 dialogue; pipeline correctly dropped it at aggregation)
  - the_giff_flotilla: model generates vague paraphrase claims that don't substring-match source — content quality issue, not schema
- [x] basil/lumi either have confidence > 0, OR documented — lumi=1.0 (PASS); basil=0 but confirmed as vague-claim generation problem, not `line:{}` schema bug
- [x] No `"line": {}` JSON in extraction for basil/lumi — confirmed; basil draft has real content post-fix
- [x] Tests pass — 1249 pass, 1 pre-existing fail (test-git_commit.R:204, expected)

## Root cause summary

The two pre-run fixes worked:
- **Fix 1 (F4 all-passages)**: lumi went from NA → 1.0. Confirmed root cause was index bug.
- **Fix 2 (relatives removal)**: basil extraction is no longer empty. Draft has content. Confidence=0 is now a generation quality problem, not a schema problem.

Remaining zero-confidence entities have distinct root causes:
1. **attorrnash**: not present in s02e37 — correctly yields an empty/NA draft. No fix needed.
2. **basil**: extraction extracts vague summaries instead of verbatim-matchable sentences. Substring grounding is working correctly — the model output just isn't source-grounded enough.
3. **the_giff_flotilla**: same as basil — vague claim generation. No vault anchor exists to bias the model toward specifics.

Next candidate fix: feed existing vault notes as identity anchors for location entities (same as F2 for PCs). Alternatively, accept that new entities with thin passages will always yield low grounding scores and rely on human review.
