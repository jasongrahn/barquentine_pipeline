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

## Actual results (fill in after running)

| entity | note_type | confidence | matched | unmatched | notes |
|---|---|---|---|---|---|
| attorrnash | npc | — | — | — | |
| basil | pc | — | — | — | |
| lumi | pc | — | — | — | |
| room | pc | — | — | — | |
| the_giff_flotilla | location | — | — | — | |

---

## Success criteria

- [ ] confidence > 0 for at least attorrnash and the_giff_flotilla
- [ ] basil/lumi either have confidence > 0, OR are documented as "true hallucination — passes don't explicitly describe them in s02e37"
- [ ] No `"line": {}` JSON in extraction output for basil/lumi
- [ ] Tests pass: `testthat::test_dir("tests/testthat/")` (1 pre-existing fail in test-git_commit.R:204 is expected)
