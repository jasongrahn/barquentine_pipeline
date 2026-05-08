# barquentine_pipeline

> *"The wiki doesn't write itself." — Every GM, eventually.*

An automated R pipeline that reads D&D session notes and VTT transcripts, drafts structured Obsidian wiki entries using local LLMs, fact-checks them, and commits the survivors to the vault. Human review happens in a Shiny app. Rejected drafts become training data.

Built for the [Barquentine](https://github.com/jasongrahn/barquentine_wiki) Spelljammer campaign. Probably generalizable. Definitely over-engineered.

---

## What it does

```
Source B (Google Doc)          Source C (VTT transcripts, NAS)
   session notes                  episode table talk
        │                                    │
        ▼                                    ▼
  parse sections               chunk → entity-spot (qwen3.5:9b)
        │                                    │
        └──────────────┬─────────────────────┘
                       ▼
             draft note (gemma4:latest)
                       │
             fact-check (qwen3.5:9b)
                       │
                  Shiny review UI
                       │
              approve / edit / reject
                       │
              ┌────────┴────────┐
          accepted           rejected
              │                  │
         vault write        training_data/dpo.jsonl
         + git commit
         training_data/sft.jsonl
```

Session notes land in `sessions/`. Entity notes land in `npcs/`, `locations/`, or `factions/`. All notes pass through the Shiny review UI — auto-approve is currently disabled. Approved notes are git-committed to the vault automatically.

---

## Stack

| Thing | What it does here |
|---|---|
| [`targets`](https://docs.ropensci.org/targets/) | Pipeline orchestration — incremental, cached, reproducible |
| [Ollama](https://ollama.com/) | Local LLM server — gemma4:latest (generator) + qwen3.5:9b (critic/entity-spot) |
| Claude API | Escalation tiebreak for low-confidence flagged notes |
| Google Drive API | Pulls session notes from the campaign doc |
| Shiny | Human review UI (port 7474) |
| Obsidian + git | The wiki vault — `barquentine_wiki` repo |

---

## Quick start

```r
# 1. Mount the NAS (Finder → Go → Connect to Server → smb://LS220D43E.local/share)
# 2. Set the episode in config.R
CURRENT_SESSION <- "S2e42"
ACTIVE_EPISODES <- c("S2e42")   # NULL for all episodes
DRY_RUN         <- TRUE         # flip to FALSE when ready

# 3. Run
targets::tar_make()

# 4. Review
shiny::runApp("shiny", port = 7474)
```

See `CLAUDE.md` for full commands and architecture details.

---

## Docs

| Doc | What's in it |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Full design spec — sources, vault structure, note templates, all phases |
| [`docs/architecture_llm_evaluation.md`](docs/architecture_llm_evaluation.md) | Model evaluation notes — why each model is assigned its role |
| [`docs/phase3.md`](docs/phase3.md) | VTT entity pipeline — design decisions, performance analysis, and fix execution brief |
| [`docs/review_queue_ui.md`](docs/review_queue_ui.md) | Shiny review UI — v1 design, v1.1 additions, and patch notes |
| [`docs/phase_next_backlog.md`](docs/phase_next_backlog.md) | Confirmed feature requests for future phases |
| [`LESSONS.md`](LESSONS.md) | Non-obvious gotchas in R, targets, Shiny, and Ollama |

---

## Rules

1. **Never fabricate.** Every prompt explicitly forbids it. Every note is traceable to a source line.
2. **Dry run first.** `DRY_RUN <- TRUE` writes to `/tmp/barquentine-preview/` instead of the vault.
3. **Don't swap models** without reading `docs/architecture_llm_evaluation.md` first.
