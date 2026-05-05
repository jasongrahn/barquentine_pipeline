# Lessons Learned — Barquentine Pipeline

Non-obvious decisions, debugging findings, and gotchas captured during development.

---

## R / targets

### Named lists from `lapply()` break `data.frame()` column names
`parse_source_b()` returns a named list (`list("S2e32" = "text")`). When targets branches a `pattern = map()` over it, each branch receives `list("S2e32" = "text")`, not `"text"`. Passing this directly to `data.frame(source_text = x)` uses the list element's name as the column name, not its value. Fix: `as.character(x)[[1]]` — coerces to character and drops the name. `unname()` alone is insufficient.

### `tar_files()` errors on empty `character(0)`
`tar_files()` cannot branch over an empty result. Use `tar_target(format = "file")` with an explicit `file.create()` fallback when the file may not exist yet (e.g., `sft.jsonl` before any training data is collected).

### Default arguments resolve at call time in the enclosing environment
`read_queue(.queue_path = REVIEW_QUEUE_PATH)` looks up `REVIEW_QUEUE_PATH` in the function's enclosing environment (where `queue.R` was sourced), not at the call site. This is usually fine but bites you in Shiny.

---

## Shiny

### `setwd()` in `app.R` does not persist into reactive sessions
`shiny::runApp("shiny/")` sets wd to `shiny/` before sourcing `app.R`. The `setwd()` at the top of `app.R` corrects this for the sourcing phase, but Shiny may restore the original wd before reactive handlers fire. Fix: compute absolute paths immediately after `setwd()` and pass them explicitly to every function call inside `server()`. Never rely on relative paths inside reactive context.

```r
PROJECT_ROOT   <- normalizePath(file.path(getwd(), ".."))
setwd(PROJECT_ROOT)
source("config.R")
QUEUE_PATH_ABS <- file.path(PROJECT_ROOT, REVIEW_QUEUE_PATH)
# then in server(): read_queue(.queue_path = QUEUE_PATH_ABS)
```

---

## Ollama / LLM

### Thinking mode needs a high `num_predict` budget; entity notes need more than session notes
qwen3.5:9b with thinking enabled can emit hundreds of tokens of `<think>` output before the actual response. Without a `num_predict` cap the model may time out; with too low a cap the thinking tokens exhaust the budget and `message.content` comes back empty. `num_predict = 800L` worked for session notes (short Google Doc sections). Entity notes pass multiple full VTT chunks as context (~7,500–43,000 chars), so thinking consumes all 800 tokens and produces no output. `ENTITY_NUM_PREDICT <- 2000L` is a stopgap; the real fix is R-side passage extraction to shorten context before the LLM call. See `docs/entity_pipeline_perf.md`.

### Use `format` (JSON Schema) for structured critic output
Ollama's `format` parameter enforces the schema at the token level — the model cannot produce output that violates it. Use it for any call that must return machine-readable JSON (critic verdict). Do not use it for free-text generation (session notes).

### Critic failure modes observed in first dry run (s2e34, s2e38, s2e39)
llama3.1:8b ignored its own "do not fabricate" rule in three ways:
1. **Character confusion** — mixed up The Captain with other NPCs (Room, War Saint)
2. **Invented contradictions** — treated consistent paraphrases as conflicts ("commoner's clothes" vs "worn attire")
3. **Paraphrasing flagged** — player recaps in their own words called inaccurate

Fix applied to `CRITIC_SYSTEM_PROMPT`: added character note, required a direct source quote before raising any issue, explicitly permitted consistent paraphrasing.

### Transcription artifacts in source text
Source text comes from automated transcripts and will contain garbled, split, or misheard words. The generator prompt must instruct the model to write `[unclear]` rather than guess — otherwise it invents plausible-sounding but fabricated content, violating the no-fabrication rule. Reviewers in the Shiny UI should treat `[unclear]` markers as expected, not as model failures.

---

## Testing

### testthat stubs must live in `globalenv()` when the function under test was sourced there
testthat 3.x evaluates test files in a local environment. Functions defined via `source()` in the global environment look up their dependencies in `globalenv()`, not in the test's local env. Stubs that shadow those dependencies must be placed with:
```r
assign("enqueue_review", function(...) invisible(NULL), envir = globalenv())
```
A plain `enqueue_review <- function(...) invisible(NULL)` inside a `test_that()` block will not be found.
