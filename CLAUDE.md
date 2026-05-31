# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Working principles

1. **Think before coding** — state assumptions explicitly; ask rather than guess; name what's unclear before touching code.
2. **Simplicity first** — write the minimum code that solves the problem. No speculative features, no premature abstractions, no error handling for impossible scenarios.
3. **Surgical changes** — only modify what's necessary. Don't improve adjacent code or refactor unbroken things. Match existing style. Note unrelated dead code but don't delete it.
4. **Goal-driven execution** — define verifiable success criteria before starting (e.g. wet run ≥4/6, tests pass, vault file committed). Loop until met.

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

# Launch the review UI (sessions, NPCs, locations, factions — all paths)
shiny::runApp("shiny/review_queue", port = 7474)
```

Before a live run, set `DRY_RUN <- FALSE` in `config.R`. Update `CURRENT_SESSION` to the episode being processed (e.g., `"s02e34"`).

## Key config (`config.R`)

| Variable | Purpose |
|---|---|
| `VAULT_PATH` | Absolute path to the wiki repo |
| `CURRENT_SESSION` | Episode ID to process (update each run) |
| `DRY_RUN` | `TRUE` skips vault writes; flip to `FALSE` for live run |
| `CRITIC_AUTO_APPROVE_THRESHOLD` | Currently `Inf` — auto-approve disabled; all notes go to review |
| `CRITIC_ESCALATE_THRESHOLD` | Confidence < this AND flagged → Claude escalation (default 0.60) |
| `OLLAMA_MODEL` / `OLLAMA_CRITIC_MODEL` | Model names — must match what Ollama has pulled |
| `AGENTIC_VTT_SESSION_IDS` | Per-session opt-in for agentic session flow |
| `AGENTIC_ENTITY_SESSION_IDS` | Per-session opt-in for agentic entity flow (Phase 4.2) |

`ANTHROPIC_API_KEY` lives in `~/.Renviron`, never in the repo. Google Drive auth cached via `googledrive::drive_auth()`.

## Gotchas

→ See `LESSONS.md` for the full list. Critical items:
- `lapply()` named lists: use `as.character(x)[[1]]` before `data.frame()` — `unname()` insufficient
- `tar_files()` crashes on `character(0)` — use `tar_target(format = "file")` with `file.create()` fallback
- `setwd()` in Shiny `app.R` does not persist into reactive handlers — use absolute paths
- llama3.1:8b does not support `think = TRUE` — always pass `NULL` or `FALSE`
- pc/pc_alias filter diverges across chains — entity chain keeps PCs; agentic session recap drops them
- `tests/testthat/test-git_commit.R:204` has a pre-existing test/impl mismatch — investigate only if asked

---

→ **Full context:** `docs/context_index.md`
