# Phase 2: Simple Human Review & Training
*Status: ollama.R done. Ready to build critic.R.*

---

## What we build
1. **Generator/Critic loop**: qwen3.5 writes draft. llama3.1 checks it. Verdict routes note to vault or review queue.
2. **Human Review UI**: Shiny app. Source vs Draft side-by-side. Click Accept / Fix / Reject.
3. **Training Store**: Verdicts go to `training_data/` for future fine-tuning.

---

## Models
| Model | Role |
|---|---|
| `qwen3.5:9b` | Generator — writes the note |
| `llama3.1:8b` | Critic — checks facts, returns JSON |
| `claude-sonnet-4-6` | Escalation only — flagged + confidence < 0.60, OR section > 3000 words |

Routing is **pure R if-else**. No model needed to decide.

---

## How it works
```
Source B section
  → sparse? (< 100 words)     → SKIP. Log it.
  → too long? (> 3000 words)  → CLAUDE path (generate + critique, 2 calls)
  → otherwise:
      qwen3.5 writes draft
      llama3.1 checks draft vs source → JSON verdict
        approved + confidence >= 0.85 → VAULT
        approved + confidence < 0.85  → QUEUE
        flagged  + confidence >= 0.60 → QUEUE
        flagged  + confidence < 0.60  → Claude tiebreak → vault or queue
        rejected                      → QUEUE
        parse error                   → QUEUE (show raw response in Shiny)
```

---

## Critic JSON (llama3.1 returns this)
Ollama `format` param enforces schema at token level. No JSON extraction needed.
```json
{
  "verdict": "approved|flagged|rejected",
  "confidence": 0.0-1.0,
  "issues": ["problem description"],
  "source_quotes": ["exact verbatim line from source"]
}
```
`parse_critic_response()` validates fields. On any failure → `parse_error` verdict → queue.

---

## Critic System Prompt (key rules)
- Check every factual claim in DRAFT against SOURCE
- verdict: approved / flagged / rejected
- Quote source exactly — no paraphrase
- Empty issues array if approved
- Source quotes required even when approved
- Absence from source ≠ inaccuracy

---

## Run cycle
```
1. tar_make()
   - Fetch Source B
   - Load recent SFT examples (tar_files tracks training_data/sft/)
   - generate_note(): sparse→NULL, overlimit→Claude, else→qwen3.5
   - review_note(): NULL draft→skipped, overlimit→Claude critique, else→llama3.1
   - dispatch_note(): vault write OR write staging file to review_queue/staging/
   - consolidate_queue(): merge staging/ → queue.csv (sequential, after all branches)
   - write_run_header(), commit_vault()

2. User opens shiny/app.R
   - Shows pending queue items (Source + Draft + Critic issues)
   - Accept → write to vault, save SFT pair
   - Accept & Edit → write edited note, save DPO pair
   - Reject → don't write, save negative
   - All verdicts append to review log (R/review.R)

3. Next tar_make()
   - tar_files() sees new SFT files → invalidates generator → re-runs with few-shot examples
```

**Shiny never commits to any repo. Never calls any model.**

---

## Queue files
```
review_queue/          ← gitignored
├── queue.csv
├── staging/           ← one .csv per branch; merged after all branches done
│   └── S2e33_session.csv
├── drafts/
│   └── S2e33_session.md
└── prompts/
    └── S2e33_session.txt  ← exact generator prompt stored at enqueue time
```

### queue.csv columns
`id, entity_id, source_episode_id, note_type, vault_relative_path, draft_path, prompt_path, critic_verdict, confidence, issues (JSON string), source_quotes (JSON string), escalated, claude_verdict, status, queued_at, resolved_at`

- `entity_id` = what the note is *about* (episode slug for sessions; name slug for NPCs/PCs/locations)
- `source_episode_id` = which session sourced the material
- `note_type` = `session` | `npc` | `pc` | `location` (Phase 2: session only)
- `status` = `pending` | `accepted` | `accepted_edited` | `rejected`

---

## Training data
```
training_data/         ← gitignored
├── sft/               ← accepted notes → {prompt, completion}
├── dpo/               ← edited notes  → {prompt, chosen: edit, rejected: draft}
└── negatives/         ← rejected notes → {prompt, completion, label: "rejected"}
```
`prompt` = exact generator prompt from `review_queue/prompts/`. Never reconstructed.

**Level 1** (ships now): `session_prompt()` loads ≤10 recent SFT pairs as few-shot examples at tar_make() time.
**Level 2** (future): Unsloth DPO fine-tuning when dpo/ has enough pairs.

---

## Shiny layout
```
[ Queue: N pending ]  [ S2e33 — session ]  [ 2 of N ]
┌─ SOURCE TEXT ──────┬─ DRAFT NOTE ────────────────────┐
│  (scrollable)      │  (editable on Accept & Edit)    │
├────────────────────┴─────────────────────────────────┤
│ CRITIC ISSUES                                        │
│ • issue  [source: "exact quote"]                    │
│ (parse_error: shows raw response)                   │
├──────────────────────────────────────────────────────┤
│ [Accept]   [Accept & Edit]   [Reject]               │
└──────────────────────────────────────────────────────┘
```

---

## New files to build (in order)
1. `R/ollama.R` ✓ — Ollama API client, `ollama_generate()`, `format` param
2. `R/critic.R` — `CRITIC_RESPONSE_SCHEMA`, `review_note()`, `parse_critic_response()`
3. `R/router.R` — `route_verdict()` (pure R); `dispatch_note()` (orchestrator)
4. `R/queue.R` — `enqueue_review()`, `consolidate_queue()`, `read_queue()`, `resolve_item()`
5. `R/training.R` — `write_sft()`, `write_dpo()`, `write_negative()`
6. `shiny/app.R` — review UI
7. `_targets.R` — wire everything

## Existing files to update
- `R/extract.R` — add `generate_note()` wrapper; add `few_shot_paths` arg to `session_prompt()`
- `R/review.R` — add optional `verdict` field to `format_review_entry()` / `append_review_entry()`
- `config.R` — add `OLLAMA_CRITIC_MODEL`, `GENERATOR_SYSTEM_PROMPT`, thresholds, queue/training paths
- `.gitignore` — add `review_queue/` and `training_data/`

---

## Key rules
1. **No git commits from Shiny.** User handles vault commits.
2. **Staging files** for queue writes — atomic, concurrency-safe.
3. **Skip sparse sections** (< 100 words). Log in run header.
4. **Long sections** (> 3000 words) → Claude. Two calls. Same schemas.
5. **Prompts captured at enqueue time.** Never reconstructed later.
6. **Shiny is review-only.** No models. No pipeline runs.
