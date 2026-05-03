# Barquentine Pipeline — Phase 2 Plan
*Status: in progress — ollama.R complete*

---

## Goals

1. **Generator/Critic pipeline** — local LLMs draft and fact-check notes before anything reaches the vault.
2. **Human review UI** — Shiny app is the review interface only; it does not generate or decide. Shows source, draft, and critic issues side-by-side.
3. **Training data collection** — every human verdict is captured as a structured training signal appended to the existing review log.

Local model usage is preferred. Claude API is the escalation path only, not the default. We will not sacrifice pipeline reliability to avoid a Claude call.

---

## Model Roster

| Model | Role | Trigger |
|---|---|---|
| `llama3.1:8b` | Generator | Always — drafts the note from source |
| `qwen3.5:9b` | Critic | Always (within context limit) — fact-checks draft vs. source |
| `claude-sonnet-4-6` | Escalation | Flagged + confidence < 0.6, OR source section exceeds context limit |
| `nomic-embed-text:latest` | Embeddings | Phase 3+ |

**Role rationale**: The critic task is harder — JSON output, verbatim quoting, source comparison,
structured reasoning. qwen3.5 (more capable) handles the harder task. llama3.1 handles the
simpler structured note generation from a template. Two different model architectures reviewing
each other's work provides genuine independence.

**Routing is pure R logic** — deterministic if-else on `verdict` and `confidence`. No model
is needed for this decision.

**Model swappability**: All model names are config constants (`OLLAMA_MODEL`, `OLLAMA_CRITIC_MODEL`).
Swapping a model is a one-line change in `config.R`. Note: critic prompts may require tuning
for a new model; Ollama JSON Schema enforcement (see below) reduces but does not eliminate
this dependency.

---

## Structured Output — Ollama `format` Parameter

The critic call uses Ollama's `format` parameter with a JSON Schema object. This enforces
the schema at the token level — the model cannot produce output that violates it. Valid JSON
matching the schema is guaranteed; no fence-stripping or JSON extraction is needed.

`ollama_generate()` accepts an optional `format` argument (added in Phase 2 patch to ollama.R).
Pass `NULL` for free-text generation (generator); pass the critic JSON Schema for critic calls.

The critic schema passed to Ollama:

```r
CRITIC_RESPONSE_SCHEMA <- list(
  type = "object",
  required = c("verdict", "confidence", "issues", "source_quotes"),
  properties = list(
    verdict      = list(type = "string", enum = c("approved", "flagged", "rejected")),
    confidence   = list(type = "number", minimum = 0, maximum = 1),
    issues       = list(type = "array",  items = list(type = "string")),
    source_quotes = list(type = "array", items = list(type = "string"))
  )
)
```

`parse_critic_response()` in `critic.R` still validates required fields (schema enforcement
guarantees syntax, not semantic completeness) and handles the `parse_error` fallback for
any remaining failure (e.g. Ollama server returns an error response rather than a model response).

---

## Critic System Prompt

```
You are a fact-checker for a D&D campaign wiki.

You will be given:
- SOURCE: raw session notes written by the Dungeon Master
- DRAFT: a structured wiki entry generated from those notes

Your task: verify every factual claim in the DRAFT against the SOURCE.
Check character names, locations, events, and stated relationships.

Return your verdict as JSON with these fields:
- verdict: "approved" if the draft accurately reflects the source,
           "flagged" if there are minor inaccuracies or unsupported claims,
           "rejected" if the draft contains significant fabrications or contradictions
- confidence: your confidence in your verdict, 0.0 to 1.0
- issues: array of strings describing each inaccuracy found (empty array if approved)
- source_quotes: array of verbatim excerpts from the SOURCE that support your verdict
  (required even if approved — quote the lines that confirm accuracy)

Rules:
- Do not fabricate issues that are not supported by the source
- Quote source text exactly — no paraphrase
- If the source does not mention something, that absence is not an inaccuracy
```

---

## Pipeline Flow

```
Source B section
      │
      ├─ is_sparse()? (< 100 words) ─────────────────────────► skip + log in run header
      │
      ├─ exceeds context limit? (> 3 000 words) ─────────────► Claude path (generate + critique,
      │                                                         two separate calls, same schemas)
      ▼
 Generator (llama3.1)
  drafts note from source
      │
      ▼
 Critic (qwen3.5 + JSON Schema format)
  reviews draft vs. source
  returns schema-validated JSON verdict
      │
      ├─ parse/schema error ──────────────────────────────────► review queue (parse_error)
      │
      ├─ approved + confidence >= 0.85 ──────────────────────► write to vault
      │
      ├─ approved + confidence < 0.85  ──────────────────────► review queue
      │
      ├─ flagged  + confidence >= 0.6  ──────────────────────► review queue
      │
      ├─ flagged  + confidence < 0.6   ─► Claude critique ───► approved → vault
      │                                   (same JSON schema)   flagged/rejected → queue
      │                                                         (Claude verdict appended
      │                                                          to issues for reviewer)
      └─ rejected ───────────────────────────────────────────► review queue
```

**Context-limit path**: Claude generates with the same `session_prompt()` used locally,
then critiques with the same critic system prompt. Two calls. Same JSON schemas. Same
`parse_critic_response()` validation. This matches the local pipeline shape exactly and
produces consistent training data regardless of which path was taken.

**Routing** is `route_verdict(verdict, confidence)` in `router.R` — pure R, no model call.
Returns one of: `"auto_approve"`, `"enqueue"`, `"escalate"`.

`dispatch_note()` in `router.R` is the public-facing orchestrator: calls `route_verdict()`,
then calls `write_note()` or `enqueue_review()` accordingly.

---

## Operational Workflow (tar_make → Shiny → tar_make)

```
1. Run tar_make()
   - Fetches Source B
   - Loads recent SFT examples via tar_files() target (see Level 1 below)
   - Generator drafts notes for each non-sparse, non-overlimit section
   - Critic reviews each draft
   - dispatch_note() routes: vault write or staging file
   - Consolidation target merges staging/ → queue.csv
   - Review log run header written
   - Vault git commit (pipeline repo does not touch vault git directly)

2. User opens Shiny app (shiny/app.R)
   - Reads queue.csv, filters status == "pending"
   - User reviews each item: Accept / Accept-with-Edit / Reject
   - Verdict writes note to vault files (not committed — vault git is the user's concern)
   - Verdict appends to review log (R/review.R audit trail)
   - Verdict writes training pair to training_data/
   - queue.csv status updated to resolved

3. Next run of tar_make()
   - tar_files() detects new SFT files written by Shiny
   - Invalidates sft_example_files target → invalidates session_note_draft
   - Generator re-runs with updated few-shot examples in prompt
```

**Shiny does not generate, re-run the pipeline, or commit to any repo.**
Vault commits after Shiny writes are the user's responsibility (Obsidian Git or manual).

---

## Level 1 Few-Shot Injection — tar_files() Pattern

```r
# In _targets.R — tracks SFT folder; invalidates when Shiny writes new pairs
tar_files(sft_example_files,
  list.files(file.path(TRAINING_DATA_PATH, "sft"), full.names = TRUE)
),

tar_target(session_note_draft,
  ollama_generate(
    session_prompt(section_ids, source_b_sections,
                   few_shot_paths = sft_example_files),
    system_prompt = "...",
    model = OLLAMA_MODEL
  ),
  pattern = map(source_b_sections, section_ids)
)
```

`session_prompt()` in `extract.R` gains an optional `few_shot_paths` argument. When
provided, it loads up to 10 of the most recent SFT pairs and prepends them as examples.
When `few_shot_paths` is empty or NULL, behaviour is identical to Phase 1.

---

## Review Queue

```
review_queue/              ← local only, gitignored
├── queue.csv              ← consolidated manifest
├── staging/               ← one .csv per branch (written by targets, merged post-run)
│   └── S2e33_session.csv
├── drafts/
│   └── S2e33_session.md   ← generated draft awaiting verdict
└── prompts/
    └── S2e33_session.txt  ← exact generator prompt used (captured at enqueue time)
```

### Concurrency — staging file approach

`targets` can execute branches in parallel. Writing directly to `queue.csv` from multiple
branches is unsafe (last writer wins). Solution:

- Each `enqueue_review()` call writes a **single-row CSV** to `review_queue/staging/{id}.csv`.
  File writes are atomic at OS level for small files.
- A **sequential consolidation target** (`queue_consolidated`) runs after all branches finish.
  It reads all files in `staging/`, binds them, merges/appends into `queue.csv`.
- Staging files are retained as a per-run record.

### `queue.csv` columns

| column | type | description |
|---|---|---|
| `id` | chr | stable slug: `{entity_id}_{note_type}` e.g. `S2e33_session`, `Basil_pc` |
| `entity_id` | chr | what the note is *about*: episode slug for sessions, name slug for entities |
| `source_episode_id` | chr | which session(s) sourced the material (always set; may differ from entity_id) |
| `note_type` | chr | `session` \| `npc` \| `pc` \| `location` (Phase 2: session only) |
| `vault_relative_path` | chr | path within vault where accepted note is written |
| `draft_path` | chr | relative path to draft in `review_queue/drafts/` |
| `prompt_path` | chr | relative path to generator prompt in `review_queue/prompts/` |
| `critic_verdict` | chr | `approved`, `flagged`, `rejected`, `parse_error` |
| `confidence` | dbl | critic confidence score (0 for parse_error) |
| `issues` | chr | JSON array serialised as string |
| `source_quotes` | chr | JSON array serialised as string |
| `escalated` | lgl | TRUE if Claude was consulted |
| `claude_verdict` | chr | Claude's verdict if escalated, else NA |
| `status` | chr | `pending`, `accepted`, `accepted_edited`, `rejected` |
| `queued_at` | chr | ISO timestamp |
| `resolved_at` | chr | ISO timestamp, NA until resolved |

**Schema is designed for all future note types.** Phase 2 populates only `session` rows.
NPC, PC, and location rows use the same schema: `entity_id` holds the character/place slug,
`source_episode_id` holds the session it was sourced from.

---

## Review Log (Audit Trail)

Shiny verdicts append to the **existing review log** maintained by `R/review.R`.
No separate file. Pipeline runs and human verdicts share one append-only log.

`format_review_entry()` and `append_review_entry()` are extended to accept an optional
`verdict` field for Shiny-sourced entries.

---

## Training Data

```
training_data/          ← local only, gitignored
├── sft/                ← supervised fine-tuning pairs (accepted notes)
│   └── {id}.jsonl      ← {prompt, completion}
├── dpo/                ← direct preference optimisation pairs (accepted-with-edit)
│   └── {id}.jsonl      ← {prompt, chosen: user_edit, rejected: draft}
└── negatives/          ← rejected notes
    └── {id}.jsonl      ← {prompt, completion, label: "rejected"}
```

**Prompt capture**: The exact generator prompt is stored in `review_queue/prompts/{id}.txt`
at enqueue time. Training pairs reference this file; prompts are never reconstructed.

**Level 2** (future manual trigger): When `dpo/` reaches sufficient pairs, run Unsloth DPO
fine-tuning offline. Out of scope for Phase 2 but the data structure supports it.

---

## Shiny App

Location: `shiny/app.R` (within this repo — open source friendly).
**Shiny is review-only.** Does not call any model. Does not commit to any repo.

### Layout

```
┌─────────────────────────────────────────────────────────────┐
│  Queue: 3 pending          [S2e33 — session]   2 of 3       │
├───────────────────────┬─────────────────────────────────────┤
│  SOURCE TEXT          │  DRAFT NOTE                         │
│  (scrollable)         │  (editable on Accept-with-Edit)     │
│                       │                                     │
├───────────────────────┴─────────────────────────────────────┤
│  CRITIC ISSUES                               [parse_error]  │
│  • issue 1  [source: "exact quote"]                         │
│  • issue 2  [source: "exact quote"]                         │
│  (for parse_error: shows raw critic response)               │
├─────────────────────────────────────────────────────────────┤
│  [Accept]    [Accept with Edit]    [Reject]                 │
└─────────────────────────────────────────────────────────────┘
```

- **Accept**: writes draft to vault at `vault_relative_path`; appends SFT pair to
  `training_data/sft/`; appends to review log; updates queue.csv.
- **Accept with Edit**: textarea becomes editable; on confirm, writes edited note to vault;
  appends DPO pair (draft = rejected, edit = chosen) to `training_data/dpo/`;
  appends to review log; updates queue.csv.
- **Reject**: note not written; appends to `training_data/negatives/`;
  appends to review log; updates queue.csv.

---

## R Modules — Build Order

| # | File | Responsibility |
|---|---|---|
| 1 | `R/ollama.R` ✓ | Ollama chat API; `ollama_generate()`; `format` param for structured output |
| 2 | `R/critic.R` | Critic JSON Schema constant; `review_note()`; `parse_critic_response()` |
| 3 | `R/router.R` | `route_verdict()` (pure R logic); `dispatch_note()` (orchestrator) |
| 4 | `R/queue.R` | `enqueue_review()`, `consolidate_queue()`, `read_queue()`, `resolve_item()` |
| 5 | `R/training.R` | `write_sft()`, `write_dpo()`, `write_negative()` |
| 6 | `shiny/app.R` | Review UI; reads queue, writes verdicts via writer/review/training |
| 7 | `_targets.R` | Wire full Phase 2 graph; add `tar_files(sft_example_files, ...)` |

---

## `_targets.R` Changes (sketch)

```r
# Track SFT examples — invalidates when Shiny writes new pairs
tar_files(sft_example_files,
  list.files(file.path(TRAINING_DATA_PATH, "sft"), full.names = TRUE)
),

# Generator (local)
tar_target(session_note_draft,
  ollama_generate(
    session_prompt(section_ids, source_b_sections, few_shot_paths = sft_example_files),
    system_prompt = GENERATOR_SYSTEM_PROMPT,
    model         = OLLAMA_MODEL
  ),
  pattern = map(source_b_sections, section_ids)
),

# Critic (structured output via JSON Schema)
tar_target(critic_verdict,
  review_note(draft = session_note_draft, source = source_b_sections),
  pattern = map(session_note_draft, source_b_sections)
),

# Route + dispatch (vault write or queue staging)
tar_target(note_dispatched,
  dispatch_note(
    draft             = session_note_draft,
    verdict           = critic_verdict,
    section_id        = section_ids,
    source_text       = source_b_sections,
    dry_run           = DRY_RUN
  ),
  pattern = map(session_note_draft, critic_verdict, section_ids, source_b_sections)
),

# Sequential consolidation — after all branches finish
tar_target(queue_consolidated,
  { note_dispatched; consolidate_queue(REVIEW_QUEUE_PATH) }
),

tar_target(review_header,
  { queue_consolidated; write_run_header(CURRENT_SESSION) }
),

tar_target(vault_committed,
  { review_header; commit_vault(CURRENT_SESSION) }
)
```

---

## Config Additions

```r
# Models
OLLAMA_CRITIC_MODEL <- "qwen3.5:9b"   # critic (more capable → harder task)
# OLLAMA_MODEL stays "llama3.1:8b"     # generator (template-following task)
# To swap a model: change the constant here. Critic prompts may need tuning.

# Routing thresholds
CRITIC_AUTO_APPROVE_THRESHOLD <- 0.85
CRITIC_ESCALATE_THRESHOLD     <- 0.60
CRITIC_CONTEXT_WORD_LIMIT     <- 3000  # sections above this → Claude path

# Review queue and training data (local only — gitignored)
REVIEW_QUEUE_PATH  <- "review_queue"
TRAINING_DATA_PATH <- "training_data"
```

---

## .gitignore Additions

```
review_queue/
training_data/
```

---

## Open Questions (all resolved — ready to code)

- ~~Router model~~ — removed; routing is pure R
- ~~Concurrency~~ — staging file approach
- ~~Level 1 timing~~ — tar_files() pattern; tar_make() time only
- ~~Vault commit from Shiny~~ — no; user's responsibility
- ~~Queue schema gaps~~ — entity_id / source_episode_id / prompt_path added
- ~~Model roles~~ — swapped; qwen3.5 critic, llama3.1 generator
- ~~Structured output~~ — Ollama format param + JSON Schema
- ~~Sparse sections~~ — silently skip, log in run header
- ~~Phase 2 scope~~ — session notes only; schema ready for future note types
- ~~Claude escalation shape~~ — two calls, same schemas as local path
