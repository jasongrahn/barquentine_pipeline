# Phase 3 — VTT Entity Pipeline

*Status: implemented on `pipeline_phase_3`, PR open. Performance fix applied.*

---

## What Phase 3 Adds

Phases 1 & 2 process Source B (Google Doc) → session notes. Phase 3 adds Source C (VTT transcripts from NAS) → entity notes (NPCs, locations, factions).

**Full Phase 3 flow:**

```
VTT file (NAS)
  → read_vtt()                    strip WEBVTT metadata, collapse to plain text
  → chunk_vtt()                   overlapping 1500-word windows, 150-word overlap
  → spot_entities()               llama3.1:8b + JSON Schema → {npcs, locations, items, factions}
  → aggregate_entity_passages()   deduplicate across episodes, resolve aliases, apply filters
  → generate_entity_note()        qwen3.5:9b → NPC/location/faction markdown
  → review_note()                 llama3.1:8b critic (same as session notes)
  → dispatch_entity_note()        supplement existing note OR create fresh → vault/queue
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

## Files

### New

| File | Purpose |
|---|---|
| `R/source_c.R` | VTT parsing, chunking, entity spotting, aggregation |
| `config/vtt_registry.csv` | Filename → episode_id mapping (7 VTT files, S2e34–S2e40) |
| `tests/testthat/test-source_c.R` | Tests for all source_c functions |

### Modified

| File | What changed |
|---|---|
| `R/extract.R` | Added `location_prompt()`, `faction_prompt()`, `generate_entity_note()` |
| `R/merge.R` | Added `supplement_note()` |
| `R/router.R` | Added `.entity_relative_path()`, `dispatch_entity_note()`; moved skip guard before path computation |
| `config.R` | Added `ENTITY_NUM_PREDICT`, `ACTIVE_EPISODES`, `MIN_ENTITY_CHUNK_COUNT` |
| `_targets.R` | Phase 3 target graph wired after `vault_committed` |

---

## Performance Analysis

### Problem statement

With default settings the entity pipeline produced no usable output in 28 min/episode.

**Observed runtime (S2e34 only, DRY_RUN=TRUE, `num_predict=800`):**

| Stage | Time | Output |
|---|---|---|
| `vtt_entities` — entity spotting (1 VTT, llama3.1:8b) | ~2.5 min | 62 entities spotted |
| `entity_draft` — note generation (62 × ~1.2 min each) | 17m 42s | `""` for all 62 |
| `entity_verdict` — critic (62 × ~8.5s avg) | 8m 48s | ran on empty drafts |
| `entity_dispatched` | ~131ms | nothing written |
| **Total** | **~28 min** | **zero useful notes** |

**Projected runtime if empty-output is fixed with higher `num_predict`:** ~2.75 hours for one episode, ~20 hours for all 7. Not viable for weekly use.

### Root causes

**1. Over-extraction at entity-spotting stage**

62 entities from S2e34 (a single session, ~40 chunks). Any name appearing in even one chunk becomes a draft candidate — minor one-off NPCs, duplicate surface forms, names that appear in only 1 of ~40 chunks. No minimum-frequency filter.

**2. Source passages too long for the generator**

Each entity accumulates up to 5+ full 1500-word chunk windows. Combined context per entity: 7,500–43,000 chars. qwen3.5:9b uses thinking mode. With `num_predict=800`, the model exhausts its token budget on `<think>...</think>` output before producing any content. Ollama returns `""`.

**3. Sequential execution**

targets runs branches sequentially by default. 62 entities × 1 Ollama call each = 62 sequential round-trips.

### Options considered

| Option | Change | Expected gain | Tradeoff |
|---|---|---|---|
| **A — Frequency filter** | Drop entities with < N chunk appearances | ~75% runtime reduction | Misses important NPCs introduced once |
| **B — Sentence-window extraction** | R-side helper extracts only sentences mentioning the entity | Context: 43k → ~1k chars; sub-30s per entity | Pronoun-only mentions missed |
| **C — Combine A+B** *(recommended)* | Filter first, then extract | ~5–8 min/episode | None beyond A+B tradeoffs combined |
| D — Swap generator to llama3.1:8b | Use critic model for generation | 3–4× faster | Violates model-role assignment; quality unvalidated |
| E — Batch entity stubs | 5–10 entities per Ollama call | Largest gain | Significant prompt/parser redesign |
| F — targets parallel workers | `tar_make(workers = N)` | Unknown | Ollama concurrent-request behavior untested |

**Chosen fix: Option C (A+B).**

---

## Fix Execution Brief

### Goal

- Working entity notes per VTT.
- Bootstrap run (all 7 VTTs) under 1 hour.
- Steady-state (1 new VTT/week) under 5 min.
- No fabrication. Source-faithful.

### DO NOT MODIFY

- `_targets.R` — graph is correct.
- `dispatch_entity_note()`, `route_verdict()`, `supplement_note()` — correct.
- `review_note()` (critic) — correct.
- `spot_entities()` prompt — out of scope; tune later if 15-entity output is still noisy.

### Step 0 — Clean residue

- Delete contents of `review_queue/staging/`.
- Delete contents of `review_queue/prompts/`.
- In `review_queue/queue.csv`: remove rows where `status == "pending"` AND draft is empty/whitespace. Keep header. Keep resolved rows.

### Step 1 — Frequency filter

`config.R`:
```r
MIN_ENTITY_CHUNK_COUNT <- 3L
```

`R/source_c.R`, `aggregate_entity_passages()`:
- Filter AFTER cross-episode merge, not before.
- Count distinct `(file_id, chunk_idx)` pairs per entity across ALL processed VTTs.
- Drop entities where cumulative distinct chunk count `< MIN_ENTITY_CHUNK_COUNT`.
- Log: n dropped, n kept, with examples of dropped names.

**Rationale:** campaign-level recurrence, not session-level frequency. An NPC mentioned once in each of 3 episodes hits the threshold. One mentioned once in one episode does not.

**Watch:** variable shadowing in dplyr — don't name params the same as columns.

**Test (`test-source_c.R`):**
- Entity A: 1 chunk in S2e34, 1 in S2e35, 1 in S2e36 → keeps (cumulative 3)
- Entity B: 2 chunks in S2e34 only → drops (cumulative 2)
- Entity C: 4 chunks in S2e34 only → keeps (cumulative 4)

### Step 2 — Empty-string guard in `ollama_generate()`

`R/ollama.R`, after extracting `message.content`:
```r
if (is.null(content) || !nzchar(trimws(content))) {
  warning(sprintf("Empty content from %s (prompt %d chars)", model, nchar(prompt)))
  return(NULL)
}
```

Caller-agnostic. Benefits Phase 2 generator, Phase 2 critic, Phase 3 generator.

**Test:** mock Ollama returning `""`, expect NULL with warning.

### Step 3 — `think` parameter in `ollama_generate()`

`R/ollama.R`:
- Signature: add `think = TRUE` (default preserves Phase 2 behavior).
- Request body: `think = think`.

`R/extract.R`, `generate_entity_note()`:
- Pass `think = FALSE`.
- DO NOT change Phase 2 `generate_note()` — leave default TRUE.

**Rationale:** free-text generation doesn't need JSON Schema, so Ollama bug #14645 doesn't apply here.

### Step 4 — Sentence-window extraction

`R/source_c.R`, new helper:
```r
extract_relevant_sentences <- function(passage, entity_name, window = 2L) {
  sentences <- stringr::str_split(passage, "(?<=[.!?])\\s+")[[1]]
  hits <- which(stringr::str_detect(
    sentences,
    stringr::regex(entity_name, ignore_case = TRUE)
  ))
  if (!length(hits)) return("")
  idx <- unique(sort(c(outer(hits, seq(-window, window), "+"))))
  idx <- idx[idx >= 1 & idx <= length(sentences)]
  paste(sentences[idx], collapse = " ")
}
```

Call in `aggregate_entity_passages()` per passage. Replace raw chunk text with extracted sentences. If all passages return `""` for an entity, drop it.

**Known limitation:** pronoun-only mentions not caught. Accept; revisit if quality suffers.

### Step 5 — Quality gate (DO NOT SKIP)

- `config.R`: `ACTIVE_EPISODES <- c("S2e34")`, `DRY_RUN <- TRUE`.
- `tar_make()`.
- Read 3 generated entity notes from preview output.

**Acceptance criteria (all must hold):**
- Non-empty markdown body
- On-topic to extracted passages
- No claims absent from source passages (no fabrication)
- YAML frontmatter parses
- Wikilinks well-formed (`[[Slug]]` or `[[Basil|the Captain]]`)

If all 3 acceptable → Step 7. Any empty/garbage → Step 6.

### Step 6 — Fallback: swap generator to llama3.1:8b

**ONLY IF Step 5 fails.**

`config.R`:
```r
ENTITY_GENERATOR_MODEL <- "llama3.1:8b"
```

`R/extract.R`, `generate_entity_note()`: use `ENTITY_GENERATOR_MODEL` instead of `OLLAMA_MODEL`.

Re-run Step 5 quality gate. If still failing: STOP. Escalate with sample outputs.

### Step 7 — Reset stopgap

`config.R`:
```r
ENTITY_NUM_PREDICT <- 800L
```

Thinking is off, long context is gone. 2000 budget no longer needed.

### Step 8 — Bootstrap dry-run

- `ACTIVE_EPISODES <- NULL` (all 7).
- `DRY_RUN <- TRUE`.
- `tar_make()`.

Expected: 5–10 min/episode, ≤ 1 hour total. Sample 5 notes/episode against the same acceptance criteria.

If acceptable: `DRY_RUN <- FALSE`, `tar_make()`, vault auto-commits.

### Threshold tuning note

`MIN_ENTITY_CHUNK_COUNT = 3` is a starting value. After Step 8, if the surviving entity list is still noisy, bump to 4 and re-run. Tune after one pass, not in advance.

### Done when

- `tar_make()` on all 7 VTTs < 1 hour, `DRY_RUN=FALSE`.
- All entity notes non-empty.
- Vault diff shows new `npcs/`, `locations/`, `factions/` markdown files.
- `review_queue/queue.csv` contains real review items (not parse_errors, not empties).
- Spot-check 5 notes per VTT — source-faithful, on-topic.

---

## Open Questions

1. Is sentence-window extraction the right granularity, or is there a better R-native text segmentation strategy?
2. Would TF-IDF or keyword scoring work better than proximity-to-name for passage extraction?
3. Is there a batching pattern that keeps per-entity routing tractable (Option E)?
4. Can Ollama serve concurrent requests without degrading per-request throughput? If so, parallel workers (Option F) may be the cheapest remaining optimization.
