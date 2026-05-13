# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

Barquentine Pipeline reads D&D session notes from a Google Doc, generates structured wiki entries via local LLMs (Ollama), fact-checks them, routes results through a Shiny review UI, and commits approved notes to the `barquentine_wiki` vault repo. Human review decisions are captured as JSONL training data for future fine-tuning.

## Commands

All commands run from an R console in the project root.

```r
# Run the full pipeline with automatic retry for Ollama timeouts
source("scripts/run_pipeline.R")
run_pipeline()

# Or directly, if you just want one pass (error="continue" is set in tar_option_set):
targets::tar_make()

# Visualize the dependency graph
targets::tar_visnetwork()

# Run all tests
testthat::test_dir("tests/testthat/")

# Run a single test file
testthat::test_file("tests/testthat/test-critic.R")

# Launch the session-note review UI (Path 1 / Path 3 agentic session rows)
shiny::runApp("shiny", port = 7474)

# Launch the entity-note review UI (Path 2 NPC / location / faction rows)
shiny::runApp("shiny/review_queue", port = 7475)
```

Before a live run, set `DRY_RUN <- FALSE` in `config.R`. Update `CURRENT_SESSION` to the episode being processed (e.g., `"s02e34"`).

### Opting an episode into the agentic VTT flow

The new agentic flow (per-chunk schema-enforced extraction → R-assembled markdown → one Synopsis LLM call) ships behind a per-session opt-in. To run an episode through it:

1. Add the episode id to `AGENTIC_VTT_SESSION_IDS` in `config.R`, e.g. `AGENTIC_VTT_SESSION_IDS <- c("s02e34")`. Default is `character(0)`.
2. Run `targets::tar_make()` as usual. The agentic chain produces a queue row with `section_id = "<sid>__agentic"`; the existing doc-prep flow keeps its row at `section_id = "<sid>"`.
3. On reviewer accept, the writer routes:
   - `<sid>__agentic` → `vault/sessions/<sid>.md` (canonical VTT recap)
   - `<sid>` for opt-in episodes → `vault/dm_prep/<sid>.md` (DM prep sidecar)
   - `<sid>` for non-opt-in episodes → `vault/sessions/<sid>.md` (existing behavior, unchanged)
4. Keep the opt-in vector small until 3 sessions have shipped with approved output; do not flip agentic to default before then.

### Opting entities into the agentic entity flow (Phase 4.2)

The entity-agentic flow (per-entity schema-enforced extraction → R-assembled markdown → line-citation fact-check, no critic loop) ships behind `AGENTIC_ENTITY_SESSION_IDS`. Default is `character(0)` (no opt-in).

1. Add the episode id to `AGENTIC_ENTITY_SESSION_IDS` in `config.R`. Any entity whose `source_episode_ids` overlaps this vector will be routed through the new chain; all others use the legacy critic loop.
2. Run `targets::tar_make()` as usual. The agentic entity chain produces queue rows with `note_type` set to the entity type (`npc`, `location`, `faction`, or `pc`).
3. Canonical-routing merges PC aliases before extraction: `captain` and `the_captain` passages are merged into the `basil` record, and `note_type` is enriched to `"pc"`. This happens in `aggregate_entity_passages()` and is not gated on the opt-in vector.
4. Do not populate `AGENTIC_ENTITY_SESSION_IDS` until at least one session has been validated end-to-end.

## Architecture

The pipeline has **three parallel input/output paths**, all dispatched from `_targets.R`:

**Path 1 — Google Doc prep flow** (`R/source_b.R`). Pulls DM's pre-game prep tabs.
For non-agentic episodes, writes the per-session note to `vault/sessions/<id>.md`.
For episodes in `AGENTIC_VTT_SESSION_IDS`, writer redirects this output to
`vault/dm_prep/<id>.md` as a sidecar (preserves DM intent without polluting the
canonical VTT recap).

**Path 2 — Entity-spotting flow** (`R/source_c.R::process_vtt_file` →
`aggregate_entity_passages` → either the legacy critic loop or the new agentic entity chain).
Spots names in the VTT, accumulates passages per slug, then:
- **Legacy path** (default): `R/extract.R::draft_with_refinement` runs the recursive generator-critic loop to draft per-entity wiki pages.
- **Agentic path** (opt-in via `AGENTIC_ENTITY_SESSION_IDS`): `R/agentic_entity_extract.R` + `R/agentic_entity_writer.R` + `R/agentic_entity_fact_check.R` + `R/agentic_entity_dispatch.R` perform schema-enforced extraction → R-assembled markdown → line-citation grounding check (no critic loop). Verdict is always `agentic_no_critic` → review queue.
Output for both paths: `vault/npcs/<slug>.md`, `vault/locations/<slug>.md`, `vault/factions/<slug>.md` (PCs route to `vault/npcs/`).

**Path 3 — Agentic session flow** (`R/agentic_extract.R` + `R/agentic_postprocess.R`
+ `R/agentic_writer.R` + `R/agentic_dispatch.R`). Per-chunk schema-enforced
extraction with line citations → R-frontloaded markdown assembly with one Synopsis
LLM call → mechanical line-citation fact-check (no critic loop). Writes the
canonical VTT recap to `vault/sessions/<id>.md` for opt-in episodes. Phase 0
shipped on `feature/recursive-critic-loop`; rollout is per-session opt-in until
3 sessions have been approved.

Per-stage internals (paths 1 and 2 only — path 3 bypasses generator + critic):

1. **Source fetch** — Sections under 100 words are skipped; sections over
   `CRITIC_CONTEXT_WORD_LIMIT` (800 words) are routed to Claude instead of local Ollama.

2. **Generate** (`R/extract.R` + `R/ollama.R`) — `OLLAMA_MODEL` (currently `gemma4:latest`)
   drafts structured markdown. Entity notes pass `think = FALSE` and `num_predict = 800L`.

3. **Critic** (`R/critic.R`) — `OLLAMA_CRITIC_MODEL` (currently `llama3.1:8b`)
   fact-checks the draft against the source, returning a JSON verdict
   `{verdict, confidence, issues, quotes}` enforced via Ollama's `format` schema
   parameter. Router (`R/router.R`) then directs:
   - `approved` + confidence ≥ `CRITIC_AUTO_APPROVE_THRESHOLD` → auto-write to vault
     (currently `Inf`, so auto-approve is disabled; all notes go to review queue)
   - `approved` + confidence < threshold → review queue
   - `flagged` + confidence < `CRITIC_ESCALATE_THRESHOLD` (0.60) → Claude tiebreak
   - `flagged`/`rejected` → review queue
   - `agentic_no_critic` (path 3 only) → always review queue, no auto-approve

4. **Review queue + Shiny UIs** — Pending items land in `review_queue/queue.csv`.
   Two Shiny apps coexist:
   - `shiny/app.R` (port 7474) — original session-note review UI.
   - `shiny/review_queue/app.R` — Phase 4.5 entity-note review UI with sidebar
     groups (Failed Generation, NPCs, Locations, Factions), regenerate modal,
     Merge action (collapses captain + the_captain → basil and writes an alias
     into the target's frontmatter), diff view, and per-entity critic-finding cards.

   Entity notes are checked against `config/entity_exclusions.csv` (legacy slug
   drop list) and a new entity-type drop list (rows where
   `entity_type %in% c("dm_voice", "player")`) before passage aggregation. Known
   PCs/key NPCs in `config/protected_entities.csv` bypass the chunk-frequency
   filter. `R/source_c.R` also filters `^unnamed *` names at aggregation time
   (protected-slug bypass remaps "unnamed Ted" → "ted") and collapses near-typo
   *location* slugs via `R/postprocess_shared.R::collapse_near_match_slugs()`.
   The alias registry is seeded from `config/entity_aliases.csv` before scanning
   vault YAML; vault YAML takes precedence on collision.

5. **Training data capture** (`R/training.R`) — Accepted-as-is → `training_data/sft.jsonl`;
   accepted-with-edit → `training_data/dpo.jsonl`; rejected → negative examples. Agentic
   rows do not produce DPO pairs (the markdown is R-assembled, not LLM-generated). Phase 2
   of the agentic plan covers chunk-level extraction SFT capture (not yet shipped).

After review, `R/writer.R` writes markdown to the vault and `R/git_commit.R` commits.

## Model roles

- **`OLLAMA_MODEL`** (currently `gemma4:latest`) — generator for session/entity note drafting (legacy paths); also drives `AGENTIC_ENTITY_MODEL` for schema-enforced entity extraction in the Phase 4.2 agentic chain
- **`OLLAMA_CRITIC_MODEL`** (currently `llama3.1:8b`) — critic only (fact-checking, JSON structured output); not used in agentic entity chain
- **claude-sonnet-4-6** — escalation only (cap-hit revision after `DRAFT_MAX_ITERATIONS`, high-word-count routing, or low-confidence flagged tiebreak)

Always read `config.R` for current model bindings rather than quoting a hardcoded name. Never swap generator and critic models without explicit instruction.

## Key config (`config.R`)

| Variable | Purpose |
|---|---|
| `VAULT_PATH` | Absolute path to the wiki repo |
| `CURRENT_SESSION` | Episode ID to process (update each run) |
| `DRY_RUN` | `TRUE` skips vault writes; flip to `FALSE` for live run |
| `CRITIC_AUTO_APPROVE_THRESHOLD` | Confidence ≥ this → auto-approve (currently `Inf`, disabled) |
| `CRITIC_ESCALATE_THRESHOLD` | Confidence < this AND flagged → Claude escalation (default 0.60) |
| `OLLAMA_MODEL` / `OLLAMA_CRITIC_MODEL` | Model names — must match what Ollama has pulled |
| `AGENTIC_VTT_SESSION_IDS` | Per-session opt-in vector for the agentic session flow (path 3) |
| `AGENTIC_ENTITY_SESSION_IDS` | Per-session opt-in vector for the agentic entity flow (Phase 4.2); default `character(0)` |
| `AGENTIC_ENTITY_MODEL` | Model for schema-enforced entity extraction; defaults to `OLLAMA_MODEL` |
| `AGENTIC_ENTITY_PASSAGE_WORD_LIMIT` | Max words of source passages fed to entity extractor (default 4000L) |
| `AGENTIC_ENTITY_SCHEMA_VERSION` | Schema version tag written to iteration log (default `"v1"`) |
| `ENTITY_EXCLUSIONS_PATH` | CSV of slugs to drop from entity note generation (DM narrator role tags) |
| `PROTECTED_ENTITIES_PATH` | CSV of known PCs/key NPCs; `entity_type` column drives drop/keep (see below) |
| `ENTITY_ALIASES_PATH` | CSV bootstrap for alias registry before vault notes exist (unambiguous name variants only) |

`config/protected_entities.csv` schema:
`slug, canonical_name, entity_type, played_by, exclude_from_spotting`. The
`entity_type` column controls behavior across both chains:

| `entity_type` | Agentic (recap NPC list) | Entity chain (wiki page) |
|---|---|---|
| `npc` | keep (in protected bypass) | keep |
| `pc` | **drop** (PCs not in recap NPC list) | **keep** (protagonists need wikis) |
| `pc_alias` | **drop** | **keep** (Merge UI collapses into canonical PC) |
| `player` | drop | drop (real human, no wiki) |
| `dm_voice` | drop | drop (DM persona, no wiki) |

**The two chains intentionally diverge on `pc`/`pc_alias`.** Do not mirror filters
blindly — see `LESSONS.md` "Two-chain pc/pc_alias divergence".

`ANTHROPIC_API_KEY` lives in `~/.Renviron`, never in the repo. Google Drive auth is cached in the OS keychain via `googledrive::drive_auth()`.

## Gotchas (from LESSONS.md)

**R / targets**
- `lapply()` returns named lists; `as.character(x)[[1]]` is needed to drop the name before passing to `data.frame()`. `unname()` alone is insufficient.
- `tar_files()` crashes on `character(0)`. Use `tar_target(format = "file")` with a `file.create()` fallback for outputs that may not exist yet.
- targets `pattern = map()` over an unnamed list-stem slices each branch with `x[i]`, yielding `list(record)` not `record`. Unwrap at the top of branch bodies: `ep <- entity_passages[[1]]`.

**Shiny**
- `setwd()` in `app.R` does not persist into reactive handlers. Compute absolute paths immediately after `setwd()` and pass them explicitly to every function inside `server()`. Never use relative paths in reactive context.

**Ollama / LLM**
- Always use `format` (JSON Schema) for critic calls; never for free-text generation.
- Source text comes from automated transcripts — instruct models to write `[unclear]` rather than guess. Reviewers should treat `[unclear]` markers as expected output, not model failures.
- The critic prompt requires a direct source quote before raising any issue; consistent paraphrasing must be permitted. See `CRITIC_SYSTEM_PROMPT` in `R/critic.R`.
- llama3.1:8b does **not** support thinking mode — passing `think = TRUE` produces 131-byte empty responses. Pass `think = FALSE` (or leave `NULL`) for it. qwen3.5 + thinking + `format` is silently broken (Ollama bug #14645), which is why critic and entity-spotting both use llama3.1:8b.

**Pipeline filters**
- The agentic chain (`R/agentic_postprocess.R`) and the entity chain (`R/source_c.R`) **diverge intentionally on `pc`/`pc_alias`**. Agentic drops them from the session-recap NPC list; entity chain keeps them so PCs get character wiki pages. Do not mirror filters blindly across the two chains. See `LESSONS.md`.
- `^unnamed ` names are dropped at entity-passage aggregation unless the stripped slug is protected ("unnamed Ted" → "ted" → kept).
- Edit-distance slug collapse via `R/postprocess_shared.R::collapse_near_match_slugs()` applies only to `note_type == "location"` records — NPC/faction names cluster too aggressively for unsupervised merge.
- **Canonical routing** (`R/source_c.R::load_canonical_routing_map()`): at passage aggregation, alias slugs (rows in `protected_entities.csv` where `make_slug(canonical_name) != slug`) are merged into their canonical slug. Example: `captain` + `the_captain` passages merge into `basil`; `entity_name` is set to the canonical_name ("Basil"); `note_type` is enriched to `"pc"` if the canonical entity_type is `"pc"`. This fires for every run (not gated on `AGENTIC_ENTITY_SESSION_IDS`), ensuring both the legacy and agentic entity chains see merged records.

**Testing**
- testthat stubs for globally-sourced functions must be placed in `globalenv()`:
  ```r
  assign("my_fn", function(...) invisible(NULL), envir = globalenv())
  ```
  A plain assignment inside `test_that()` will not be found by the function under test.
- `tests/testthat/test-git_commit.R` has pre-existing errors that depend on the fixture path `/the/vault` existing. Not a regression; not in current scope. Investigate only if asked.
