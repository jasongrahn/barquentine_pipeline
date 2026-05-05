# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

Barquentine Pipeline reads D&D session notes from a Google Doc, generates structured wiki entries via local LLMs (Ollama), fact-checks them, routes results through a Shiny review UI, and commits approved notes to the `barquentine_wiki` vault repo. Human review decisions are captured as JSONL training data for future fine-tuning.

## Commands

All commands run from an R console in the project root.

```r
# Run the full pipeline
targets::tar_make()

# Visualize the dependency graph
targets::tar_visnetwork()

# Run all tests
testthat::test_dir("tests/testthat/")

# Run a single test file
testthat::test_file("tests/testthat/test-critic.R")

# Launch the Shiny review UI
shiny::runApp("shiny", port = 7474)
```

Before a live run, set `DRY_RUN <- FALSE` in `config.R`. Update `CURRENT_SESSION` to the episode being processed (e.g., `"S2e34"`).

## Architecture

The pipeline flows in five phases defined in `_targets.R`:

1. **Source fetch** (`R/source_b.R`) — Pulls the Google Doc (ID in `config.R`), parses tabs into named episode sections. Sections under 100 words are skipped; sections over `CRITIC_CONTEXT_WORD_LIMIT` (3000 words) are routed to Claude instead of local Ollama.

2. **Generate** (`R/extract.R` + `R/ollama.R`) — qwen3.5:9b drafts structured markdown from source text. Uses `num_predict = 800L` to accommodate thinking-mode output without timeouts.

3. **Critic** (`R/critic.R`) — llama3.1:8b fact-checks the draft against the source, returning a JSON verdict `{verdict, confidence, issues, quotes}` enforced via Ollama's `format` schema parameter. Router (`R/router.R`) then directs:
   - `approved` + confidence ≥ 0.85 → auto-write to vault
   - `approved` + confidence < 0.85 → review queue
   - `flagged` + confidence < 0.60 → Claude escalation tiebreak
   - `flagged`/`rejected` → review queue

4. **Review queue + Shiny UI** (`R/queue.R`, `shiny/app.R`) — Pending items land in `review_queue/queue.csv`. The Shiny app (port 7474) shows source vs. draft side-by-side with critic issues and supporting quotes. Reviewers accept, accept-with-edit, or reject.

5. **Training data capture** (`R/training.R`) — Accepted-as-is → `training_data/sft.jsonl`; accepted-with-edit → `training_data/dpo.jsonl` (chosen/rejected pair); rejected → negative examples.

After review, `R/writer.R` writes markdown to the vault and `R/git_commit.R` commits.

## Model roles

- **qwen3.5:9b** — generator only (session note drafting)
- **llama3.1:8b** — critic only (fact-checking, JSON structured output)
- **claude-sonnet-4-6** — escalation tiebreak only (high word count or low-confidence flagged)

Never swap generator and critic models without explicit instruction.

## Key config (`config.R`)

| Variable | Purpose |
|---|---|
| `VAULT_PATH` | Absolute path to the wiki repo |
| `CURRENT_SESSION` | Episode ID to process (update each run) |
| `DRY_RUN` | `TRUE` skips vault writes; flip to `FALSE` for live run |
| `CRITIC_AUTO_APPROVE_THRESHOLD` | Confidence ≥ this → auto-approve (default 0.85) |
| `CRITIC_ESCALATE_THRESHOLD` | Confidence < this AND flagged → Claude escalation (default 0.60) |
| `OLLAMA_MODEL` / `OLLAMA_CRITIC_MODEL` | Model names — must match what Ollama has pulled |

`ANTHROPIC_API_KEY` lives in `~/.Renviron`, never in the repo. Google Drive auth is cached in the OS keychain via `googledrive::drive_auth()`.

## Gotchas (from LESSONS.md)

**R / targets**
- `lapply()` returns named lists; `as.character(x)[[1]]` is needed to drop the name before passing to `data.frame()`. `unname()` alone is insufficient.
- `tar_files()` crashes on `character(0)`. Use `tar_target(format = "file")` with a `file.create()` fallback for outputs that may not exist yet.

**Shiny**
- `setwd()` in `app.R` does not persist into reactive handlers. Compute absolute paths immediately after `setwd()` and pass them explicitly to every function inside `server()`. Never use relative paths in reactive context.

**Ollama / LLM**
- Always use `format` (JSON Schema) for critic calls; never for free-text generation.
- Source text comes from automated transcripts — instruct models to write `[unclear]` rather than guess. Reviewers should treat `[unclear]` markers as expected output, not model failures.
- The critic prompt requires a direct source quote before raising any issue; consistent paraphrasing must be permitted. See `CRITIC_SYSTEM_PROMPT` in `R/critic.R`.

**Testing**
- testthat stubs for globally-sourced functions must be placed in `globalenv()`:
  ```r
  assign("my_fn", function(...) invisible(NULL), envir = globalenv())
  ```
  A plain assignment inside `test_that()` will not be found by the function under test.
