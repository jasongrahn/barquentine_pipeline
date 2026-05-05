# Phase 3 Design — Source C (VTT) Entity Pipeline

*Status: implemented on `pipeline_phase_3`, PR open*

---

## What Phase 3 Adds

Phases 1 & 2 process Source B (Google Doc) → session notes. Phase 3 adds Source C (VTT transcripts from NAS) → entity notes (NPCs, locations, factions).

**Full Phase 3 flow:**

```
VTT file (NAS)
  → read_vtt()           strip WEBVTT metadata, collapse to plain text
  → chunk_vtt()          overlapping 1500-word windows, 150-word overlap
  → spot_entities()      llama3.1:8b + JSON Schema → {npcs, locations, items, factions}
  → aggregate_entity_passages()  deduplicate across episodes, resolve aliases
  → generate_entity_note()       qwen3.5:9b → NPC/location/faction markdown
  → review_note()        llama3.1:8b critic (same as session notes)
  → dispatch_entity_note()       supplement existing note OR create fresh → vault/queue
```

---

## Design Decisions

### VTT registry CSV rather than filename parsing

VTT filenames are Zoom-style timestamps (`GMT20251223-022554_Recording.transcript.vtt`) with no episode ID. A `config/vtt_registry.csv` maps filenames to episode IDs. This mirrors `source_a_registry.csv` and keeps episode identity explicit and auditable.

Episode IDs were populated by extracting opening recaps from each VTT and matching against Source B Google Doc sections via Claude — not by manual entry.

`ACTIVE_EPISODES <- NULL` in `config.R` processes all confirmed episodes. Set to e.g. `c("S2e34")` to run one episode for debugging.

### llama3.1:8b for entity spotting, not qwen3.5:9b

qwen3.5 series has a confirmed open Ollama bug (#14645): the `format` parameter (JSON Schema enforcement) is silently ignored when `think=false`. Since entity spotting requires structured JSON output, llama3.1:8b (the critic model) is used instead. It handles the `format` parameter correctly and is already validated in this role.

Model roles remain:
- `qwen3.5:9b` — free-text generation (session notes, entity notes)
- `llama3.1:8b` — JSON-structured output (critic, entity spotting)

### Separate `dispatch_entity_note()` from `dispatch_note()`

`dispatch_note()` hardcodes `sessions/` as the vault path. Entity notes route to `npcs/`, `locations/`, or `factions/` based on `note_type`. Rather than adding a branching parameter to `dispatch_note()`, a new `dispatch_entity_note()` was added. Both reuse `route_verdict()` — the routing logic is shared.

### `supplement_note()` for existing vault entries

When an entity note already exists in the vault, Phase 3 runs use `supplement_note()` (`R/merge.R`) rather than overwriting. This:
1. Calls `merge_note()` for frontmatter conflict detection (existing logic)
2. Appends `- [[{source_episode_id}]]` to the `## Session Appearances` section

The function is purely text-in/text-out — no file I/O. File handling stays in `router.R`.

### `list()` wrapper on `vtt_entities` branches

When `pattern = map()` branches over a stem that returns a **named list**, targets aggregates branches with `c()`, which flattens named lists at the top level. The downstream target then sees a flat list with duplicate keys rather than a list-of-records.

Fix: wrap each branch return in `list()`:
```r
tar_target(vtt_entities, list(process_vtt_file(...)), pattern = map(...))
```
`c(list(record1), list(record2))` = `list(record1, record2)` — structure preserved.

### `[[1]]` unwrap in entity_draft/entity_verdict/entity_dispatched branches

When `pattern = map(entity_passages)` branches over a stem that returns an **unnamed list** of records, targets uses single-bracket slicing (`x[i]`), which gives `list(record_i)` — the record wrapped in an outer list. Downstream branches must unwrap with `entity_passages[[1]]` to access the record's fields.

This differs from named-list stems (like `source_b_sections`) where targets extracts directly. The `[[1]]` pattern is now the standard for any branch that maps over an unnamed list stem.

---

## New Files

| File | Purpose |
|---|---|
| `R/source_c.R` | VTT parsing, chunking, entity spotting, aggregation |
| `config/vtt_registry.csv` | Filename → episode_id mapping (7 VTT files, S2e34–S2e40) |
| `tests/testthat/test-source_c.R` | Tests for all source_c functions |

## Modified Files

| File | What changed |
|---|---|
| `R/extract.R` | Added `location_prompt()`, `faction_prompt()`, `generate_entity_note()` |
| `R/merge.R` | Added `supplement_note()` |
| `R/router.R` | Added `.entity_relative_path()`, `dispatch_entity_note()`; moved skip guard before path computation |
| `config.R` | Added `ENTITY_NUM_PREDICT`, `ACTIVE_EPISODES` |
| `_targets.R` | Phase 3 target graph wired after `vault_committed` |

---

## Known Issues

### Entity pipeline runtime is too slow for production use

With default settings (all 7 episodes, `ENTITY_NUM_PREDICT = 2000L`), the pipeline generates notes for ~60+ entities per episode at ~2–3 minutes each. Estimated runtime: 20+ hours for all episodes.

Root causes and options are documented in `docs/phase3_performance.md`. The planned fix is:
1. Minimum chunk frequency filter (only generate notes for entities appearing in ≥3 chunks)
2. R-side sentence-window extraction (pass targeted excerpts rather than full chunks to the generator)

This is the primary outstanding work before Phase 3 can be used in a production weekly run.

### `ENTITY_NUM_PREDICT = 2000L` is a stopgap

qwen3.5:9b exhausts its thinking budget on long source passages and returns an empty `content` field. Raising `num_predict` to 2000 reduces (but doesn't eliminate) this. The correct fix is shorter source passages via R-side extraction — see above.
