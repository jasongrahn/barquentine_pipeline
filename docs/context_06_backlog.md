# Context 06 — Backlog & Roadmap

**Live priority tracker:** `docs/stack_rank.md` — read this first each session. Updated by `/session-close`.

**Current branch:** `feature/location-writer-fallback`

---

## Top open items (as of 2026-05-27)

### P2 — Quality / phased work

| Item | Detail |
|---|---|
| **giff_flotilla draft quality** | `R/agentic_entity_writer.R::assemble_location_markdown()` — detect null/sparse fields, fall back to vault note content. `docs/phase_4_2/` reference. |
| **Phase 4.2 subsumption decision** | Should agentic entity chain fully replace legacy critic loop? Gated on wet run validation. See `docs/phase_4_2/decisions/retirement.md`. |
| **Chunk-extraction SFT capture** | Phase 2 training data for agentic entity path. `docs/phase_4_2/phases/2_training.md`. |
| **Background regeneration queue** | Non-blocking Shiny regen via `callr::r_bg()`. `shiny/review_queue/R/server.R:447–499`. |
| **`played_by` frontmatter on PC notes** | Add player column to `config/protected_entities.csv`; write to frontmatter; validator enforces for known PC slugs. |
| **PC history timeline** | Append-only `## Session History` section on PC wiki pages — one bullet per processed session, in episode order. Acts as cumulative context file injected into future entity extractions (extends the vault-note anchor beyond single-snapshot identity grounding). Enables chronological replay from s1e0 to build PC growth arcs from early transcripts that lack speaker attribution. Writer appends rather than overwrites; targets pipeline threads the current PC note as both identity anchor and history accumulator. |

### P3 — Backlog

| Item | Detail |
|---|---|
| Run Pipeline button | Shiny `callr::r_bg()` for `tar_make()` with live log stream |
| Slug helper consolidation | `make_slug()` + `agentic_slug()` are identical; merge. Cleanup branch. |
| YAML frontmatter centralisation | Parse/format scattered across writer.R, validator.R, Shiny. Cleanup branch. |
| queue.csv schema centralisation | Column definitions duplicated across writer.R, training.R, Shiny. Cleanup branch. |
| Agentic prefix consistency | Mixed naming in `agentic_*.R` files. Cleanup branch. |

---

## Phase roadmap

### Active: Phase 4.2 entity agentic (in progress)
- Phase 0 (foundation) + Phase 1 (refinements) shipped
- Phase 2 (training capture) + Phase 3 (observability) planned
- Phase 4 (default flip) gated on sustained wet run quality
- → `docs/phase_4_2/`

### Next: Cleanup branch
After Phase 4.2 fully ships — slug consolidation, YAML scatter, queue schema, Shiny P3 items, agentic prefix cleanup.
- → `docs/phase_4_2/decisions/retirement.md`

### Deferred: Session-ingest skill
Gemma4 function-calling chain for takeaway approval + wikilink injection. No API cost option preferred given credit situation.

### Deferred: Agentic recap restructure (3-section format)
Plot Synopsis / Notable Lore / Unresolved Questions. Separate branch after Phase 4.2 ships.
- → `docs/phase_4_2/decisions/rollout.md` Q9

---

## Phase agentic session rollout status

| Gate | Status |
|---|---|
| s02e34 session note | ✅ Published to vault |
| s02e35 session note | ✅ Published to vault |
| s02e36 session note | ✅ Published to vault |
| 3/3 gate | **CLOSED 2026-05-12** — agentic session flow is now canonical |

→ Full session flow roadmap: `docs/phase_agentic_extraction_integration.md`
