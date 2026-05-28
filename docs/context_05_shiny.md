# Context 05 — Shiny Review UI

Single canonical app at `shiny/review_queue/app.R`, port 7474.

```r
shiny::runApp("shiny/review_queue", port = 7474)
```

---

## Sidebar layout

```
Sessions
  └── [session items by episode]
Failed Generation
  └── [parse_error items]
NPCs
  └── [npc items]
Locations
  └── [location items]
Factions
  └── [faction items]
```

Iteration badges show critic-loop pass count per item. Agentic items show `agentic_no_critic` pipeline path.

---

## Actions per item

| Action | Effect |
|---|---|
| **Approve** | Writes to vault via `R/writer.R`, captures `sft.jsonl` training row |
| **Approve (with edit)** | Writes edited draft, captures `dpo.jsonl` pair (original vs. edited) |
| **Reject** | Marks rejected, captures negative training example |
| **Regenerate** | Re-runs generator + critic synchronously (blocks UI — P2 fix pending) |
| **Merge** | Collapses `captain` + `the_captain` → `basil`; writes alias into target's frontmatter |

Reviewer decisions also written to `review_log.md` in vault via `append_review_entry()`.

---

## queue.csv schema

Key columns:

| Column | Values |
|---|---|
| `section_id` | `<episode_id>` or `<episode_id>__agentic` |
| `note_type` | `session`, `npc`, `location`, `faction`, `pc` |
| `status` | `pending`, `approved`, `rejected`, `merged`, `skipped` |
| `verdict` | `approved`, `flagged`, `rejected`, `agentic_no_critic`, `parse_error` |
| `confidence` | 0–1 (critic output; not calibrated — do not use for auto-approve) |
| `pipeline_path` | `critic_loop`, `agentic_no_critic`, `aps_error` |
| `coverage_score` | 0–1 (grounding check; agentic chain only) |
| `issues` | JSON array of critic issues |

---

## Training data capture

All review actions captured by `R/training.R`:

| Action | Output |
|---|---|
| Approved as-is | `training_data/sft.jsonl` — source → accepted draft |
| Approved with edit | `training_data/dpo.jsonl` — original (rejected) vs. edited (chosen) |
| Rejected | Negative example appended to sft.jsonl |
| Agentic rows | No DPO pairs (markdown R-assembled, not LLM output) |

---

## Shiny gotchas

**`setwd()` does not persist into reactive handlers.** `shiny::runApp("shiny/")` sets wd before sourcing `app.R`, but Shiny may restore the original wd before reactives fire. Fix: compute absolute paths immediately after `setwd()` and pass explicitly to every reactive. Never use relative paths inside `server()`.

```r
PROJECT_ROOT   <- normalizePath(file.path(getwd(), ".."))
setwd(PROJECT_ROOT)
source("config.R")
QUEUE_PATH_ABS <- file.path(PROJECT_ROOT, REVIEW_QUEUE_PATH)
# in server(): use QUEUE_PATH_ABS, not REVIEW_QUEUE_PATH
```

**`shiny/app.R` is archived.** Legacy app lives at `docs/archive/legacy_shiny_app.R`. Do not use it.

---

## Format validation in UI

`R/validator.R::validate_note_format(content, note_type)` checks:
- YAML frontmatter present + required fields
- No duplicate H1 headers
- Section headers match expected template for `note_type`
- No redundant slug H1

Fires pre-write on approve. Shows inline warn panel with "Write anyway" override. Post-write re-reads file and logs `[format-warn]` on mismatch.
