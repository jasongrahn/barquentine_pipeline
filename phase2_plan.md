# Barquentine Pipeline — Phase 2 Plan
*Status: planning — no code written yet*

---

## Goals

1. **Generator/Critic pipeline** — local LLMs draft and fact-check notes before anything reaches the vault.
2. **Human review UI** — Shiny app for notes the critic flags; shows source, draft, and issues side-by-side.
3. **Training data collection** — every human verdict is captured as a structured training signal.

Local model usage is preferred throughout. Claude API is the escalation path only, not the default.

---

## Model Roster

| Model | Role | Trigger |
|---|---|---|
| `qwen3.5:9b` | Generator | Always — drafts the note |
| `llama3.1:8b` | Critic | Always — fact-checks draft vs. source |
| `qwen2.5-coder:1.5b-base` | Router | Always — reads critic JSON, decides action |
| `claude-sonnet-4-6` | Escalation | Flagged + confidence < 0.6 only |
| `gemma4:latest` | Heavy fallback | TBD — reserved for tasks that need it |
| `nomic-embed-text:latest` | Embeddings | Phase 3+ |

---

## Pipeline Flow

```
Source B section
      │
      ▼
 Generator (qwen3.5)
  drafts note
      │
      ▼
 Critic (llama3.1)
  reviews draft vs. source
  returns JSON verdict
      │
      ├── approved + confidence >= 0.85 ──────────────────► write to vault
      │
      ├── approved + confidence < 0.85  ──────────────────► review queue
      │
      ├── flagged  + confidence >= 0.6  ──────────────────► review queue
      │
      ├── flagged  + confidence < 0.6   ──► Claude ──┬────► write to vault
      │                                              └────► review queue
      │
      └── rejected ───────────────────────────────────────► review queue
```

**Router** (qwen2.5-coder:1.5b-base) reads the critic JSON and emits one of four actions:
`auto_approve`, `enqueue`, `escalate`, `enqueue_after_escalation`.

Claude's escalation verdict follows the same approved/flagged/rejected schema as the critic.
If Claude approves → vault. If Claude flags or rejects → human queue (with Claude's verdict
appended to the issues list so the reviewer sees it).

---

## Critic JSON Schema

```json
{
  "verdict": "approved",
  "confidence": 0.91,
  "issues": [],
  "source_quotes": ["exact line(s) from source the critic used to judge"]
}
```

- `verdict`: one of `"approved"`, `"flagged"`, `"rejected"`
- `confidence`: float 0.0–1.0
- `issues`: array of strings; empty if approved
- `source_quotes`: array of verbatim excerpts from the source document the critic
  cited when forming its verdict. Required even for approvals — gives the reviewer
  (and future training) the grounding line.

The critic prompt instructs the model to quote sparingly and exactly — no paraphrase.

---

## Review Queue

```
review_queue/
├── queue.csv          ← manifest (one row per pending item)
└── drafts/
    └── S2e33_session.md   ← generated note draft, awaiting verdict
```

### `queue.csv` columns

| column | type | description |
|---|---|---|
| `id` | chr | `{episode_id}_{note_type}` e.g. `S2e33_session` |
| `episode_id` | chr | e.g. `S2e33` |
| `note_type` | chr | `session`, `npc`, `location` |
| `draft_path` | chr | relative path to draft in `review_queue/drafts/` |
| `verdict` | chr | critic verdict: `approved`, `flagged`, `rejected` |
| `confidence` | dbl | critic confidence score |
| `issues` | chr | JSON array serialised as string |
| `source_quotes` | chr | JSON array serialised as string |
| `escalated` | lgl | TRUE if Claude was consulted |
| `claude_verdict` | chr | Claude's verdict if escalated, else NA |
| `status` | chr | `pending`, `accepted`, `accepted_edited`, `rejected` |
| `queued_at` | chr | ISO timestamp |
| `resolved_at` | chr | ISO timestamp, NA until resolved |

Queue items are never deleted — `status` moves from `pending` to a resolved state.
The Shiny app filters to `status == "pending"`.

---

## Training Data

```
training_data/
├── sft/               ← supervised fine-tuning pairs (accepted notes)
│   └── {id}.jsonl     ← {prompt, completion}
├── dpo/               ← direct preference optimisation pairs (accepted-with-edit)
│   └── {id}.jsonl     ← {prompt, chosen: user_edit, rejected: draft}
└── negatives/         ← rejected notes
    └── {id}.jsonl     ← {prompt, completion, label: "rejected"}
```

One `.jsonl` file per verdict. The `prompt` field is always the generator prompt
(source text + instructions) so pairs are self-contained for fine-tuning.

**Level 1 improvement** (ships with the UI): on each Shiny session start, load
the 10 most recent accepted SFT pairs and inject them as few-shot examples into
the generator prompt. No retraining required.

**Level 2** (manual trigger): when `dpo/` has >= 50 pairs, run Unsloth DPO
fine-tuning offline. This is out of scope for Phase 2 code but the data structure
is designed for it.

---

## Shiny App

Location: `shiny/app.R` (within this repo).

### Layout

```
┌─────────────────────────────────────────────────────────────┐
│  Queue: 3 pending          [S2e33 — session]   2 of 3       │
├───────────────────────┬─────────────────────────────────────┤
│  SOURCE TEXT          │  DRAFT NOTE                         │
│  (scrollable)         │  (editable textarea)                │
│                       │                                     │
├───────────────────────┴─────────────────────────────────────┤
│  CRITIC ISSUES                                              │
│  • issue 1  [source: "exact quote"]                        │
│  • issue 2  [source: "exact quote"]                        │
├─────────────────────────────────────────────────────────────┤
│  [Accept]    [Accept with Edit]    [Reject]                 │
└─────────────────────────────────────────────────────────────┘
```

- **Accept**: writes draft as-is to vault; logs SFT pair to `training_data/sft/`.
- **Accept with Edit**: textarea is editable; on confirm, writes edited note to vault;
  logs DPO pair (draft = rejected, edit = chosen) to `training_data/dpo/`.
- **Reject**: note is not written; logs to `training_data/negatives/`.

All three verdicts update `queue.csv` (`status`, `resolved_at`).

---

## R Modules — Build Order

Build and test one module at a time before proceeding.

| # | File | Responsibility |
|---|---|---|
| 1 | `R/ollama.R` | Ollama API client (httr2); `ollama_generate()`, `ollama_chat()` |
| 2 | `R/critic.R` | Critic prompt builder; JSON verdict parser; `review_note()` |
| 3 | `R/router.R` | Routing logic; `route_verdict()` → action string |
| 4 | `R/queue.R` | Queue management; `enqueue_review()`, `read_queue()`, `resolve_item()` |
| 5 | `R/training.R` | Training data writer; `write_sft()`, `write_dpo()`, `write_negative()` |
| 6 | `shiny/app.R` | Review UI; reads queue, writes verdicts, calls training.R |
| 7 | `_targets.R` | Wire generator → critic → router → vault/queue |

---

## `_targets.R` Changes

Phase 2 replaces `claude_generate_note()` with the local generator and adds
critic/router targets. Rough shape:

```r
# Generator (local — replaces claude_generate_note)
tar_target(session_note_draft,
  ollama_generate_note(session_prompt(section_ids, source_b_sections)),
  pattern = map(source_b_sections, section_ids)
),

# Critic
tar_target(critic_verdict,
  review_note(draft = session_note_draft, source = source_b_sections),
  pattern = map(session_note_draft, source_b_sections)
),

# Router — emits action string
tar_target(route_action,
  route_verdict(critic_verdict),
  pattern = map(critic_verdict)
),

# Write auto-approved notes
tar_target(session_notes_written,
  write_note_if_approved(
    content       = session_note_draft,
    action        = route_action,
    relative_path = file.path("sessions", paste0(section_ids, ".md")),
    dry_run       = DRY_RUN,
    overwrite     = TRUE
  ),
  pattern = map(session_note_draft, route_action, section_ids)
),

# Enqueue flagged/rejected notes
tar_target(session_notes_queued,
  enqueue_if_flagged(
    draft   = session_note_draft,
    verdict = critic_verdict,
    action  = route_action,
    id      = section_ids
  ),
  pattern = map(session_note_draft, critic_verdict, route_action, section_ids)
)
```

`write_note_if_approved()` and `enqueue_if_flagged()` are thin wrappers that
check `action` and call `write_note()` or `enqueue_review()` accordingly.
They return `invisible(NULL)` for the non-matching path so targets has a clean
return value in all branches.

---

## Config Additions

Add to `config.R`:

```r
# Critic routing thresholds
CRITIC_AUTO_APPROVE_THRESHOLD <- 0.85
CRITIC_ESCALATE_THRESHOLD     <- 0.60   # flagged + below this → Claude

# Review queue
REVIEW_QUEUE_PATH <- "review_queue"    # relative to pipeline repo root

# Training data
TRAINING_DATA_PATH <- "training_data"  # relative to pipeline repo root
```

---

## Open Questions (decide before coding each module)

- **ollama.R**: streaming vs. non-streaming responses? Non-streaming is simpler and
  sufficient for batch pipeline use. Streaming would only matter for the Shiny live
  preview (future).
- **Critic prompt**: zero-shot or few-shot from the start? Propose zero-shot first;
  Level 1 improvement adds few-shot once SFT pairs exist.
- **Queue location**: `review_queue/` lives in the pipeline repo (not the vault).
  Training data likewise. Neither gets committed to the vault.
- **Shiny auth**: none for now — local use only. If this becomes a multi-user tool,
  add Posit Connect or shinyapps.io auth in a later phase.
