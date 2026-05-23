# Lessons Learned — Barquentine Pipeline

Non-obvious decisions, debugging findings, and gotchas captured during development.

---

## R / targets

### Named lists from `lapply()` break `data.frame()` column names
`parse_source_b()` returns a named list (`list("S2e32" = "text")`). When targets branches a `pattern = map()` over it, each branch receives `list("S2e32" = "text")`, not `"text"`. Passing this directly to `data.frame(source_text = x)` uses the list element's name as the column name, not its value. Fix: `as.character(x)[[1]]` — coerces to character and drops the name. `unname()` alone is insufficient.

### targets `pattern = map()` over named lists: use `list()` wrapper to prevent key flattening
When a branch target returns a named list (e.g., `list(npcs = ..., locations = ...)`) and targets aggregates multiple branches with `c()`, named keys from all branches get flattened into one flat list — destroying the per-branch structure. Fix: wrap each branch's return value in `list()`:
```r
tar_target(vtt_entities, list(process_vtt_file(...)), pattern = map(...))
```
`c(list(r1), list(r2))` → `list(r1, r2)` — structure preserved.

### targets single-bracket slicing: always use `[[1]]` to unwrap branch stems
When a downstream target branches over an upstream unnamed list stem, targets slices each branch with `x[i]` (single bracket), yielding `list(record)` not `record`. Accessing `entity_passages$note_type` on a `list(record)` returns `character(0)` (empty), not the value. Fix: always unwrap at the top of branch bodies:
```r
ep <- entity_passages[[1]]
ep$note_type  # correct
```

### `tar_files()` errors on empty `character(0)`
`tar_files()` cannot branch over an empty result. Use `tar_target(format = "file")` with an explicit `file.create()` fallback when the file may not exist yet (e.g., `sft.jsonl` before any training data is collected).

### Default arguments resolve at call time in the enclosing environment
`read_queue(.queue_path = REVIEW_QUEUE_PATH)` looks up `REVIEW_QUEUE_PATH` in the function's enclosing environment (where `queue.R` was sourced), not at the call site. This is usually fine but bites you in Shiny.

### targets does not track `readLines()` file loads as dependencies
Skill prompt templates loaded with `readLines()` inside an R function are invisible to targets' dependency tracking. Editing `agents/wiki_skills/*/user_template.md` will not mark any target as outdated — targets sees only the function body, not files read at runtime. Fix: after editing any user_template.md, run `targets::tar_invalidate(starts_with("entity_agentic"))` before `tar_make()` to force re-extraction.

### targets skips downstream when an upstream returns same-shape value
A single-target node whose body is `lapply(seq_along(x), ...)` returning a constant per element (e.g., `dispatch_*()` returning `invisible("enqueued")`) produces the same content hash whenever the input length is stable. Downstream targets that depend only on this node will be SKIPPED on subsequent runs even though the upstream "ran" — targets compares values, not invocations. Symptom on `agentic_dispatched` → `agentic_queue_consolidated`: staging files were written but never rolled into `queue.csv` because the consolidator was skipped. Fix: either return a content-varying value (Sys.time, count, written paths) or attach `cue = tar_cue(mode = "always")` to the downstream side-effect target.

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

### Pass `think = FALSE` for entity note generation; never pass `think` to llama3.1:8b
qwen3.5:9b thinking mode emits `<think>` tokens that count against `num_predict`. With long entity passages the thinking budget exhausts the limit and `message.content` comes back empty. Fix: pass `think = FALSE` explicitly in `generate_entity_note()` — this disables thinking entirely, keeping `num_predict = 800L` sufficient.

llama3.1:8b does not support thinking mode at all. Passing `think = TRUE` (or any non-NULL `think`) to it causes silent failures: Ollama returns 131B responses with zero entities spotted. Fix: `think` defaults to `NULL` in `ollama_generate()` and `.build_ollama_request()` — the field is omitted from the body unless explicitly set by the caller.

Ollama bug #14645: the `format` (JSON Schema) parameter is silently ignored for qwen3.5 series when `think = FALSE`. This is why llama3.1:8b is used for critic and entity spotting (both require structured JSON output), not qwen3.5.

### Use `format` (JSON Schema) for structured critic output
Ollama's `format` parameter enforces the schema at the token level — the model cannot produce output that violates it. Use it for any call that must return machine-readable JSON (critic verdict). Do not use it for free-text generation (session notes).

### Critic failure modes observed in first dry run (s2e34, s2e38, s2e39)
llama3.1:8b ignored its own "do not fabricate" rule in three ways:
1. **Character confusion** — mixed up The Captain with other NPCs (Room, War Saint)
2. **Invented contradictions** — treated consistent paraphrases as conflicts ("commoner's clothes" vs "worn attire")
3. **Paraphrasing flagged** — player recaps in their own words called inaccurate

Fix applied to `CRITIC_SYSTEM_PROMPT`: added character note, required a direct source quote before raising any issue, explicitly permitted consistent paraphrasing.

### Generator model ignores "no preamble" rule — add post-processing strip
qwen3.5:9b frequently prepends "Based on the dialogue provided, here is the note." before the `---` YAML fence, despite explicit rule 6 ("No explanation, no preamble, no code fences"). Two-layer fix required:
1. Strengthen the prompt rule: "Your response must begin with exactly `---` on the first line and nothing before it."
2. Post-process in `generate_entity_note()`: `sub("^[^-]*(?=---)", "", raw, perl = TRUE)` strips any text before the first fence.
The second layer is essential — the model is inconsistent even with strong prompt instruction.

### `supplement_note`: guard against empty `existing_text` before delegating to structure-sensitive helpers
`merge_note` and `append_to_section` both require a parseable Markdown note structure (YAML frontmatter + section headers). When `existing_text` is `""` (0-byte vault file), `.parse_frontmatter` returns `list()`, `merge_note` returns `""` unchanged, and `append_to_section` throws "Section not found". The `tryCatch` rescue then produces `"\n- [[source_id]]"` — not `new_content` — resulting in a 12-byte garbage write.

General rule: any function operating on note structure must guard on empty/whitespace input before calling structural helpers. Add at the top of such functions:
```r
if (nchar(trimws(existing_text)) == 0L) return(new_content)
```

### Frequency filter ordering: filter on raw chunk text, extract sentences after
When building entity passage lists, apply the chunk-count frequency filter (`length(unique(source_passages)) >= min_chunks`) on the full raw chunk text, then run sentence-window extraction on survivors only. Reversing the order (extract first, then count) produces shorter strings that are more likely to collide as duplicates, corrupting the frequency count and dropping entities that should survive.

### Two-chain `pc`/`pc_alias` divergence
The agentic chain's `filter_pc_and_player_npcs()` (`R/agentic_postprocess.R`) drops `pc` and `pc_alias` rows from **the NPC list inside a session recap** — PCs are not NPCs in a recap. The entity chain (`R/source_c.R::load_excluded_entity_slugs`) does **not** drop them — it generates per-character wiki pages, and PCs are the protagonists.

**Do not mirror filters blindly between the two chains.** Commit `47a176f` ported the agentic exclusion list verbatim into the entity chain, which over-excluded — captain / lumi / room never got wiki pages. Commit `a2ad4aa` fixed it: the entity chain drops only `dm_voice` and `player`; `pc` and `pc_alias` flow through, and the Phase 4.5 Merge UI collapses captain + the_captain → basil at review time.

When porting a filter across chains, ask: "is this a *presentation* rule (recap formatting) or an *existence* rule (does this entity get a wiki)?" They diverge.

### Entity-chain `^unnamed ` filter: strip-then-check, not slug-then-check
`R/source_c.R::aggregate_entity_passages()` drops names matching `^unnamed\b` unless the *stripped* slug is in `protected_slugs`. This mirrors `agentic_slug()`'s `^unnamed[ _]+` strip in `R/agentic_postprocess.R`. Without the strip, "unnamed Ted" would map to slug `unnamed_ted` and fail the protected-slug check; with the strip, it maps to `ted` and survives the bypass.

### Edit-distance slug collapse is location-only
`R/postprocess_shared.R::collapse_near_match_slugs()` uses `utils::adist()` + union-find to merge near-typo slugs. The entity chain (and the agentic chain's `collapse_near_match_locations`) apply it **only to `note_type == "location"` records**. NPCs and factions have personal names where small edit distances are too noisy ("Cletus" vs "Cletas" must not auto-merge without reviewer judgment). Locations are typo-tolerant in practice.

### APS model (`gurubot/gemma-2b-aps-it:Q4_K_M`) output format
Output starts with `: PROPOSITIONS:\n<s>\n`, then hyphen-bullet lines, ends with `</s>`. At 3000–7500 words input, model produces ~8 propositions and stops. Not a timeout — just low output volume. Strip the header and sentinel before splitting on newlines.

Proposition content reflects surface utterances verbatim, not structured facts. Identity confusion present: if two characters share a passage the model may emit propositions attributed to the wrong one. APS is useful as a grounding filter, not a fact oracle.

`regex(claim, ignore_case=TRUE)` in `str_detect()` uses claim text as a regex pattern. Claims from draft sentences may contain `()`, `.`, `?` — these are valid regex but match broadly. Acceptable for grounding; do not use for exact equality checks.

### Transcription artifacts in source text
Source text comes from automated transcripts and will contain garbled, split, or misheard words. The generator prompt must instruct the model to write `[unclear]` rather than guess — otherwise it invents plausible-sounding but fabricated content, violating the no-fabrication rule. Reviewers in the Shiny UI should treat `[unclear]` markers as expected, not as model failures.

---

## Testing

---

## Performance

### Parallel entity generation: `tar_make_future()` + `multisession` (deferred to Phase 5)
Entity note generation is the main throughput bottleneck (~10 min for 8 entities sequentially). The targets-native path to parallelize it:
```r
# In _targets.R or a separate run script:
future::plan(future.callr::callr, workers = 4L)
targets::tar_make_future(workers = 4L)
```
Requires adding `future` and `future.callr` as dependencies. Caveat: Ollama on Apple Silicon is single-threaded per model — benchmark before assuming wall-clock speedup. Each `tar_make_future` worker spawns a separate R session, so `config.R` and all sourced files must be self-contained (no interactive setup).

---

## Testing

### testthat stubs must live in `globalenv()` when the function under test was sourced there
testthat 3.x evaluates test files in a local environment. Functions defined via `source()` in the global environment look up their dependencies in `globalenv()`, not in the test's local env. Stubs that shadow those dependencies must be placed with:
```r
assign("enqueue_review", function(...) invisible(NULL), envir = globalenv())
```
A plain `enqueue_review <- function(...) invisible(NULL)` inside a `test_that()` block will not be found.
