# Context Index — Barquentine Pipeline

Master index. Read this first. Load specific docs only when working in that area.

---

## Context docs (numbered = reading order for full orientation)

| # | Doc | Load when... |
|---|---|---|
| 1 | [`context_01_overview.md`](context_01_overview.md) | New session, new contributor, need project orientation |
| 2 | [`context_02_architecture.md`](context_02_architecture.md) | Working on pipeline flows, targets graph, routing logic |
| 3 | [`context_03_models.md`](context_03_models.md) | Changing models, debugging LLM output, escalation paths |
| 4 | [`context_04_entity_chain.md`](context_04_entity_chain.md) | Entity extraction, schemas, Phase 4.2 agentic chain |
| 5 | [`context_05_shiny.md`](context_05_shiny.md) | Review UI, queue.csv, training data capture |
| 6 | [`context_06_backlog.md`](context_06_backlog.md) | Starting a session, picking next work item |

---

## Living operational docs (always current — do not archive)

| Doc | Purpose | Updated by |
|---|---|---|
| [`../LESSONS.md`](../LESSONS.md) | Non-obvious R/targets/Shiny/Ollama gotchas | `/session-close` (append only) |
| [`stack_rank.md`](stack_rank.md) | Single-page P0–P4 priority checklist | `/session-close` (header + items) |
| `../review_queue/queue.csv` | Live review queue | Pipeline + Shiny |
| `../config.R` | All runtime config variables | Manual per-run |

---

## Deep-reference docs (load only when working in that area)

| Doc | Purpose |
|---|---|
| [`architecture.md`](architecture.md) | Full 1,200-line design spec; context_02 condenses it |
| [`architecture_llm_evaluation.md`](architecture_llm_evaluation.md) | Full model evaluation + swap rationale; context_03 condenses it |
| [`phase_agentic_extraction_integration.md`](phase_agentic_extraction_integration.md) | Phase 2–4 session-flow roadmap |
| [`phase_4_2/README.md`](phase_4_2/README.md) | Entity agentic phase index — load first, then drill into phases/ or decisions/ as needed |

---

## Archive (historical — reference only)

`docs/archive/` contains superseded phase designs, model research, and retired UI specs. Browse when you need historical context; do not update.

Key archive entries:
- `archive/phase_gemma4_optimization.md` — Phase F entity chain optimization history
- `archive/phase_recursive_critic_loop.md` — Recursive critic loop design (superseded by agentic)
- `archive/legacy_shiny_app.R` — Retired Shiny app (superseded by `shiny/review_queue/app.R`)
- `archive/ideas.md` — Original brainstorm/research doc
