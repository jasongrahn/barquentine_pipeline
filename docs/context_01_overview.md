# Context 01 — Project Overview

**What:** R pipeline that reads D&D session notes + VTT transcripts, drafts Obsidian wiki entries via local LLMs, fact-checks them, routes through human review, and commits approved notes to the vault.

**Two repos:**
- `barquentine_pipeline` — all R code, this repo
- `barquentine_wiki` (`BarquentineWiki/`) — Obsidian vault, git-committed after each approved note

**Campaign:** Barquentine — Spelljammer D&D. Sessions run weekly/biweekly.

---

## Critical constraints

1. **Never fabricate.** Every prompt explicitly forbids it. Every claim must be traceable to a source line. This is the most important rule in the project.
2. **Dry run first.** `DRY_RUN <- TRUE` in `config.R` before any live vault write.
3. **Never swap models** without reading `docs/context_03_models.md` first.
4. **Auto-approve is disabled.** `CRITIC_AUTO_APPROVE_THRESHOLD = Inf` — all notes go to human review regardless of critic verdict.

---

## Data flow

```
Source B (Google Doc)          Source C (VTT transcripts, NAS)
   DM session notes               table talk (WebVTT format)
        │                                    │
        ▼                                    ▼
  parse sections               chunk → entity-spot
        │                                    │
        └──────────────┬─────────────────────┘
                       ▼
             draft note (gemma4:latest)
                       │
             fact-check (llama3.1:8b)
                       │
                  Shiny review UI (port 7474)
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

---

## Vault structure

```
BarquentineWiki/
├── sessions/          ← per-session recap notes
├── npcs/              ← NPC wiki pages (PCs also route here)
├── locations/         ← location wiki pages
├── factions/          ← faction wiki pages
├── dm_prep/           ← DM prep sidecars (agentic opt-in episodes)
└── review/review_log.md
```

---

## PC player roster

| Character | Player | Notes |
|---|---|---|
| Room | John | |
| Lumi | Chase | |
| The Admiral | Jason | |
| Basil / The Captain | David | `captain` + `the_captain` → merge to `basil` |

PCs route to `npcs/` in the vault. `played_by` frontmatter field is a planned P2 addition.

---

## Source precedence

```
VTT transcript > "Previously on" intro > prep notes
```

Conflicts flagged for DM review; never silently resolved.

---

## Key paths

| Resource | Path |
|---|---|
| Pipeline config | `config.R` |
| Vault root | `/Users/jasongrahn/R-projects/barquentine_wiki/BarquentineWiki/` |
| Review queue | `review_queue/queue.csv` |
| Shiny UI | `shiny/review_queue/app.R` (port 7474) |
| Training data | `training_data/sft.jsonl`, `training_data/dpo.jsonl` |
| NAS mount | `/Volumes/share/videos/` via `smb://LS220D43E.local/share` |

→ Architecture detail: `docs/context_02_architecture.md`
→ Active priorities: `docs/context_06_backlog.md`
