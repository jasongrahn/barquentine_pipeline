# Implementation Plan — Recursive Critic Loop
**Status:** Ready to implement  
**Created:** 2026-05-09  
**Design doc:** `docs/recursive_critic_loop_design.md`

Track progress with checkboxes. Mark a step `[x]` when the implementation is merged and
validated on at least one real section. Leave sub-bullets as implementation notes.

---

## Resolved Open Questions

**Session list:** Available by pulling the Google Doc tab list programmatically. Not a
blocker — `source_b.R` already fetches this; the ordered list is implicit in tab order.
Apply `s01e01` zero-padded format at vault wipe time.

**Story So Far — Key Entities section:** YES. Include at minimum the current PCs:
- Basil / The Captain (same character; "The Captain" is the current name)
- Room
- Lumi

The Key Entities section summarizes PC status, not vault entity files — the two are
different audiences (narrative summary vs. structured wiki). Not a duplication concern.

**Inner loop — sync vs async:** The inner loop waits **synchronously** for Claude when
escalating. The loop needs Claude's verdict to pick the best draft and record the DPO
pair; async would create an unresolvable race. Batch API applies only to calls that
happen *outside* the loop (Story So Far updates, which run after a session is fully
human-approved).

---

## Rollout Constraint

Ship Phase 0 with `DRAFT_MAX_ITERATIONS = 1L`. Validate revision prompt behavior on real
data. Raise to `5L` only after confirming no drift. This is enforced in `config.R`, not
in the function — no code change needed to raise the cap.

---

## Phase 0 — Foundation (P0)

All steps in Phase 0 must ship together. The loop is broken without any one of them.

---

### Step 0.1 — `config.R`: New config variables

- [x] Add `DRAFT_MAX_ITERATIONS <- 1L` (rollout value)
- [x] Add `PROCESS_ONE_SESSION <- TRUE`
- [x] Add `OLLAMA_TIMEOUT_BACKOFF_SECONDS <- 30L` (see Step 0.3)

No dependencies.

---

### Step 0.2 — `router.R`: Disable auto-approve path

- [x] Remove or gate the `approved + confidence ≥ 0.85 → auto-write` routing branch
- [x] All drafts route to the Shiny review queue regardless of confidence
- [x] `CRITIC_AUTO_APPROVE_THRESHOLD` remains in `config.R` but has no routing effect
  (it is preserved for re-enablement after 5 sessions are validated)

No dependencies.

---

### Step 0.3 — `critic.R` + `ollama.R`: Timeout handling + degraded-Ollama guard

This step has three sub-concerns: exposing Claude for direct use, handling the timeout
itself, and preventing the timed-out Ollama instance from causing cascading failures.

#### 3a — Expose `claude_review_note()` for direct loop use

`claude_review_note()` is defined in `R/claude.R` and currently called only from
`review_note()` when word count exceeds `CRITIC_CONTEXT_WORD_LIMIT`. The inner loop
needs to call it directly for escalation. No signature change needed — it is already
a top-level function. Document it as part of the public API surface.

- [x] Confirm `claude_review_note()` is exported / accessible from `extract.R` context
  (in targets pipelines, `R/*.R` files are all sourced globally — this is likely fine
  already; verify and note in code)

#### 3b — Catch timeout errors in `review_note()`

Currently `ollama_generate()` calls `req_perform()` with no error handling. A timeout
throws `httr2_error` (curl class: `curl_error`), which propagates as an unhandled
condition and crashes the target.

- [x] Wrap `req_perform()` in `tryCatch` in `ollama_generate()`, catching
  `httr2_error` specifically (not all errors — malformed JSON, schema violations, and
  empty content are distinct failure modes that should not trigger Claude escalation)
- [x] On timeout: return a sentinel value the caller can detect, e.g.:
  ```r
  list(timed_out = TRUE, verdict = NULL)
  ```
  Do NOT silently return NULL — the caller must be able to distinguish timeout from
  empty content.

#### 3c — Degraded-Ollama guard (zombie prevention)

**What happens on timeout:** `httr2` closes R's TCP socket when `req_timeout()` fires.
Ollama sees a broken pipe on its end. Most Ollama backends stop generating on broken
pipe — but not all. Even if Ollama stops, it may have a second or two of cleanup.
The risk is **resource starvation**: if the pipeline immediately calls Ollama again, it
hits an instance still unwinding the ghost request, and that call may also time out
(cascading failure). Ollama cannot "reinject" a response into R after timeout — R's
socket is gone and any data Ollama sends hits a broken pipe and is discarded. The zombie
is Ollama's problem, not R's.

**Guard design:**

- [x] `draft_with_refinement()` tracks `ollama_critic_degraded <- FALSE` in local scope
- [x] When `review_note()` returns the timeout sentinel:
  - Set `ollama_critic_degraded <- TRUE`
  - Record `escalation_reason = "ollama_timeout"` in the iteration log entry
  - Call `claude_review_note()` for the current critic call
- [x] All **subsequent** critic calls in that section's loop check `ollama_critic_degraded`
  first; if `TRUE`, route directly to Claude without attempting Ollama
- [x] After the section's loop completes (success or cap), `ollama_critic_degraded`
  is reset to `FALSE` for the next section — the guard is scoped to one
  `draft_with_refinement()` invocation, not the whole session
- [x] After a section that had a timeout, `Sys.sleep(OLLAMA_TIMEOUT_BACKOFF_SECONDS)`
  before starting the next section — gives Ollama time to finish the ghost request
  and return to idle before the next call lands

**What this prevents:**
- Cascading timeouts from hitting a still-busy Ollama server
- Ambiguity in training records (timeout escalations tagged separately)
- Any chance of acting on a late Ollama response (impossible architecturally, but
  the degraded flag makes intent explicit)

**What this does NOT prevent:**
- Ollama continuing to run internally (no Ollama-side abort API is available without
  streaming mode; `stream = FALSE` means no request ID to cancel)
- Resource consumption on the Ollama host until its generation finishes naturally

**Dependencies:** Step 0.1 (`OLLAMA_TIMEOUT_BACKOFF_SECONDS` config var)

---

### Step 0.4 — `claude.R`: Switch non-blocking Claude calls to Batch API

Batch API applies to calls where the pipeline can continue without the result:
- Story So Far updates (happen after session is fully approved; see Phase 2)
- Any future tiebreak calls that are not inside the inner loop

The inner loop escalation (Step 0.3c) is **synchronous** — the loop cannot proceed
without the verdict to pick the best draft and record the DPO pair. Do NOT batch
inner-loop escalation calls.

- [x] Add `claude_batch_review_note()` for out-of-loop escalation use cases
- [x] Implement poll-until-complete pattern (Batch API is async; call to create,
  then poll `/v1/message_batches/{id}/results` until `processing_status == "ended"`)
- [x] Inner-loop `claude_review_note()` remains synchronous — do not change it

**Dependencies:** Step 0.3 (understand which Claude calls are blocking vs non-blocking)

---

### Step 0.5 — `extract.R`: Add `revise_note(draft, issues, quotes, source_text)`

New function in `extract.R`. Constructs the revision prompt and calls `OLLAMA_MODEL`
(qwen3.5:9b — same model as generation).

- [x] Signature: `revise_note(draft, issues, quotes, source_text)`
- [x] Revision prompt (middle-ground stance):
  > "Correct the specific issues listed below. You may rephrase immediately surrounding
  > sentences for readability, but do not add new facts, remove sections, or change
  > anything not adjacent to a listed issue."
- [x] Both `issues` and `quotes` (source quotes) go into the prompt. Passing issues
  without quotes means the generator revises blind — this is a P0 requirement.
- [x] Uses `ollama_generate()` with `think = FALSE`, no `format` schema (free text output)
- [ ] Falls back to conservative fix-only prompt if middle-ground causes drift in practice
  (document the fallback prompt here when it becomes relevant)

No dependencies. Build in parallel with 0.1–0.4.  
**Step 0.6 cannot be written until this exists.**

---

### Step 0.6 — `extract.R`: Add `draft_with_refinement()` (inner loop wrapper)

The core function. Owns the entire generate → critic → revise cycle.

- [x] Signature: `draft_with_refinement(source_text, section_id, note_type, ...)`
- [x] Return value:
  ```r
  list(
    best_draft      = "...",      # highest-confidence draft seen across all iterations
    best_confidence = 0.88,
    final_verdict   = list(...),
    iteration_log   = list(...),  # one record per iteration (see schema below)
    iteration_count = 3L,
    claude_used     = FALSE,
    escalation_reason = NULL      # "ollama_timeout" | "cap_hit" | NULL
  )
  ```
- [x] Iteration log record schema (one entry per iteration):
  ```r
  list(
    section_id        = "s01e03_1",
    iteration         = 2L,
    model             = "qwen3.5:9b",
    verdict           = "flagged",
    confidence        = 0.74,
    issues_count      = 2L,
    escalated_to_claude = FALSE,
    escalation_reason = NULL,
    timestamp         = Sys.time()
  )
  ```
- [x] Loop logic:
  1. Call `generate_note()` → `review_note()`
  2. Track `best_draft` / `best_confidence` — update only when confidence improves
  3. If `approved` OR `iteration_count == DRAFT_MAX_ITERATIONS`: break
  4. If `flagged`/`rejected`: call `revise_note(draft, issues, quotes, source_text)`
  5. Check `ollama_critic_degraded` before each subsequent `review_note()` call
  6. On cap hit: call `claude_review_note()` for a full revision attempt; set
     `claude_used = TRUE`, `escalation_reason = "cap_hit"`; record DPO pair
     (best Ollama draft = rejected, Claude revision = chosen)
  7. On timeout (sentinel return from `review_note()`): set `ollama_critic_degraded`,
     call `claude_review_note()`, set `escalation_reason = "ollama_timeout"`
- [x] Write each iteration's draft to a temp file: `temp/section_id_iter_N.md`
  - Allows restart mid-loop without losing earlier iterations
  - Clean up temp files on successful completion
  - Leave temp files on failure so a retry can inspect state

**Dependencies:** Step 0.3 (timeout handling + Claude exposure), Step 0.5 (`revise_note`)

---

### Step 0.7 — `queue.R`: Add columns to queue schema

- [x] Add `iteration_count` (integer) to `queue.csv` schema
- [x] Add `claude_used` (logical) to `queue.csv` schema
- [x] Add `iteration_log` (JSON string — serialize with `jsonlite::toJSON()`) to schema
- [x] Update all functions that read/write queue rows to handle new columns
- [x] Existing queue rows without these columns: default `iteration_count = 1L`,
  `claude_used = FALSE`, `iteration_log = "[]"`

No dependencies. Build in parallel with 0.5–0.6.

---

### Step 0.8 — `router.R`: Update `dispatch_note()` to receive `iteration_log`

- [x] `dispatch_note()` now accepts the full `draft_with_refinement()` return value
- [x] Extracts `best_draft` as the draft to queue (not the latest draft)
- [x] Writes `iteration_count`, `claude_used`, `iteration_log` to the queue row
- [x] Auto-approve path remains disabled (from Step 0.2) — confidence is surfaced
  as a reviewer signal only

**Dependencies:** Step 0.6 (return structure), Step 0.7 (queue columns)

---

### Step 0.9 — `_targets.R`: Replace 3 flat targets with 1 `draft_with_refinement` target

Highest-risk change in Phase 0. Do this last.

Current flat targets: `session_draft`, `critic_verdict`, generation portion of `dispatch_note`  
New: single target per section calling `draft_with_refinement()`

- [x] Replace the three targets with one target per section type
- [x] `pattern = map()` branching is preserved — loop is internal to the function,
  invisible to targets
- [x] Verify targets cache behavior: a timeout at iteration 4 should not lose
  iterations 1–3 (temp files from Step 0.6 are the recovery mechanism here, not
  targets cache)
- [x] Run `tar_manifest()` before and after to confirm graph structure is correct
  (session_draft + critic_verdict → session_refined; dispatched maps over session_refined)

**Dependencies:** Step 0.6, Step 0.8

---

## Phase 1 — Full Note-Type Scope (P1)

**Prerequisite:** All Phase 0 steps merged and validated on at least one real session.

### Step 1.1 — All entity note types through inner loop

- [x] Extend `draft_with_refinement()` to accept `note_type` parameter:
  `"session"` | `"pc"` | `"npc"` | `"faction"` | `"location"`
- [x] `note_type` controls which generation and revision prompts are used
  (or dispatches to the correct `generate_*` function)
- [x] Wire all entity note targets in `_targets.R` through `draft_with_refinement()`
- [x] Verify entity note critic calls use `format = CRITIC_RESPONSE_SCHEMA`
  (not free-text — same as session notes)

---

## Phase 2 — Session Ordering + Outer Loop (P2)

**Prerequisite:** Phase 0 complete. Answer the session list question before 2.1.

### Step 2.1 — `source_b.R` + `config.R`: Zero-padded session ID format

- [x] Update section ID generation in `source_b.R` to emit `s01e01`-style IDs
- [x] Update `CURRENT_SESSION` default in `config.R`
- [x] Apply at vault wipe — no migration of existing files needed
- [x] Update any string comparisons / sort logic that assumes old format

**Note:** The ordered session list is available from the Google Doc tab list. Pull it
programmatically from `source_b.R` to confirm order before wipe.

### Step 2.2 — `writer.R`: Add `write_placeholder_note(session_id)`

- [x] Writes a gap-session placeholder with `gap: true` frontmatter
- [x] Called when a session has no source notes
- [x] Placeholder content: `"No session notes available for {session_id}."`

### Step 2.3 — `story.R`: New file — Story So Far

New file `R/story.R`.

- [x] `read_story_so_far(current_session)`: finds the highest-numbered snapshot with
  session ID less than `current_session`; returns file content or `NULL` if none exists
- [x] `update_story_so_far(through_session)`: Claude call (Batch API — non-blocking,
  runs after full session approval) with prompt:
  > "Update this campaign summary to incorporate the events of the new session.
  > Preserve all prior context, compress where appropriate, highlight new developments,
  > active threads, and unresolved plot points."
- [x] Prompt must include a **Key Entities** section summarizing current PC status at
  minimum: Basil / The Captain, Room, Lumi. This is narrative state (wounds, goals,
  relationships), not a duplicate of vault entity files.
- [x] Writes versioned snapshot: `vault/story_so_far/through_{session_id}.md`
- [x] Frontmatter schema:
  ```yaml
  ---
  type: campaign_summary
  through_session: s01e13
  generated_at: 2026-05-09T14:32:00
  sessions_covered: [s01e01, s01e02, ..., s01e13]
  gaps: [s01e07]
  ---
  ```
- [x] Story So Far generator is instructed to skip `gap: true` entries rather than
  fabricate content

### Step 2.4 — `extract.R`: Update `generate_note()` for outer loop context

- [x] Accept optional `story_so_far` parameter
- [x] When provided, prepend Story So Far to generator context (before source text)
- [ ] Add targeted entity note injection: pull only vault entity files for entities
  directly mentioned in the current source text (not full vault dump)
  *(Deferred: not blocking; revisit when entity vault grows enough to matter.)*
- [x] `read_story_so_far()` is called by the pipeline runner, not inside
  `generate_note()` — context is passed in, not fetched internally

**Dependencies:** Step 2.3

### Step 2.5 — `run_pipeline.R` + `_targets.R`: Session ordering guard

- [x] `run_pipeline()` checks vault for session note or placeholder for the previous
  session before proceeding
- [x] Hard stop with informative message if previous session is missing
- [x] Respect `PROCESS_ONE_SESSION = TRUE` from config
- [x] Document that vault can be wiped and rebuilt from scratch — this is expected
  for the initial run under the new system

**Dependencies:** Step 2.2 (placeholder mechanism must exist)

### Step 2.6 — `source_b.R` / `config.R`: `next_unprocessed_session()` auto-detection

- [x] Helper reads the source doc's tab list and returns the first session not yet
  present in the vault
  *(Implementation note: reads from `DOC_REGISTRY_PATH` rather than re-fetching
  the multi-tab Drive doc. The registry is populated by `fetch_all_episode_docs()`
  on the prior run, so it is the authoritative local list of available sessions.)*
- [x] `CURRENT_SESSION` in `config.R` remains as explicit override
- [x] `run_pipeline()` uses `next_unprocessed_session()` when `CURRENT_SESSION` is
  not explicitly set (or is set to a sentinel like `NULL`)

**Dependencies:** Step 2.1 (session ID format must be settled)

---

## Phase 3 — Training Data (P3)

**Prerequisite:** Phase 0 complete and `iteration_log` schema stable.

### Step 3.1 — `training.R`: Intermediate DPO pairs from iteration log

- [x] Walk `iteration_log` for each section
- [x] For each iteration where critic flagged and a revision improved confidence:
  write DPO pair (`rejected` = pre-revision draft, `chosen` = post-revision draft)
- [x] Where confidence stayed flat or dropped: write negative example instead
- [x] Only pairs where confidence improved are written as DPO

### Step 3.2 — `training.R`: Claude escalation DPO pairs with `source` field

- [x] When Claude produces a revision after cap: `rejected` = best Ollama draft,
  `chosen` = Claude revision
- [x] Write to `dpo.jsonl` with `source: "claude_escalation"` field for separate
  weighting during fine-tuning

### Step 3.3 — `story.R` or standalone: `refresh_few_shots()`

- [x] Pulls recent high-confidence approved vault notes into the few-shot pool
- [x] Low urgency; implement after 3–4 sessions under new system when vault has
  enough approved content to be useful
  *(Implemented in `R/training.R`; cross-references `sft.jsonl` with
  `queue.csv` confidence and writes to `training_data/few_shots_pool.jsonl`.)*

---

## Phase 4 — Observability + UI (P4)

### Step 4.1 — `run_pipeline.R`: Post-run summary table

Print after each `run_pipeline()` call:

| Metric | Value |
|---|---|
| Sections processed | N |
| Passed first attempt | N |
| Avg iterations (flagged sections) | N.N |
| Hit iteration cap | N |
| Claude escalations | N |
| Est. Claude cost | $N.NN |

- [ ] Aggregate from `iteration_log` records written during the run

**Dependencies:** Phase 0 (iteration_log must be populated)

### Step 4.2 — `shiny/app.R`: Iteration metadata on review card

- [ ] Surface `iteration_count` on the review card (e.g., "3 drafts before routing")
- [ ] Surface `claude_used` (e.g., "Claude revised" badge)
- [ ] Surface `escalation_reason` when relevant ("timed out" vs "cap hit")

**Dependencies:** Step 0.7 (queue columns must exist)

### Step 4.3 — (Deferred decision) `update_story_so_far()` as Shiny button

- [ ] Decide after Phase 2 is running: does this belong in the UI or stay console-only?
- [ ] Not blocking anything; revisit during Phase 2 review

---

## Dependency Graph

```
0.1, 0.2              — no deps; do first
0.3                   — no deps → unblocks 0.4, 0.6
0.4                   — needs 0.3
0.5                   — no deps → unblocks 0.6
0.7                   — no deps → unblocks 0.8
0.6                   — needs 0.3, 0.5
0.8                   — needs 0.6, 0.7
0.9                   — needs 0.6, 0.8  ← highest-risk; do last in Phase 0

Phase 1               — all Phase 0 done
Phase 2               — Phase 0 done; session list confirmed; open questions resolved
Phase 3               — Phase 0 done; iteration_log schema stable
Phase 4               — Step 0.7 done (for queue columns); Phase 0 done (for log data)
```
