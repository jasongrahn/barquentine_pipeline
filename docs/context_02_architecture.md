# Context 02 — Architecture

Three parallel paths, all dispatched from `_targets.R`. Each path ends at the Shiny review queue.

→ Full design spec: `docs/architecture.md`

---

## Three paths

### Path 1 — Google Doc prep flow (`R/source_b.R`)
Pulls DM's pre-game prep tabs from the campaign Google Doc.
- Non-agentic episodes → `vault/sessions/<id>.md`
- Agentic opt-in episodes (`AGENTIC_VTT_SESSION_IDS`) → `vault/dm_prep/<id>.md` (sidecar)

### Path 2 — Entity-spotting flow (`R/source_c.R` → entity chain)
Spots character/location names in VTT, aggregates passages per slug, then:
- **Legacy path** (default): `R/extract.R` runs generator-critic loop
- **Agentic path** (opt-in via `AGENTIC_ENTITY_SESSION_IDS`): schema-enforced extraction → R-assembled markdown → grounding check
- Output: `vault/npcs/<slug>.md`, `vault/locations/<slug>.md`, `vault/factions/<slug>.md`

→ Entity chain detail: `docs/context_04_entity_chain.md`

### Path 3 — Agentic session flow (`R/agentic_extract.R` + writer + dispatch)
Per-chunk schema-enforced extraction with line citations → R-assembled markdown → one Synopsis LLM call.
- Opt-in: add episode id to `AGENTIC_VTT_SESSION_IDS` in `config.R`
- Writes canonical VTT recap to `vault/sessions/<id>.md` for opt-in episodes
- **3/3 gate CLOSED** — all three sessions shipped; this is now the canonical session path

---

## Per-stage internals (Paths 1 + 2 legacy only)

### 1. Source fetch
- Sections < 100 words → skipped
- Sections > `CRITIC_CONTEXT_WORD_LIMIT` (800 words) → routed to Claude instead of Ollama

### 2. Generate (`R/extract.R` + `R/ollama.R`)
- `OLLAMA_MODEL` (gemma4:latest) drafts structured markdown
- Entity notes: `think = FALSE`, `num_predict = 800L`
- `format = NULL` + R-side fence-strip/JSON-parse/schema-validate fallback

### 3. Critic (`R/critic.R`)
- `OLLAMA_CRITIC_MODEL` (llama3.1:8b) fact-checks draft vs. source
- Returns `{verdict, confidence, issues, quotes}` via Ollama `format` schema
- Router (`R/router.R`) directs:
  - `approved` + confidence ≥ `CRITIC_AUTO_APPROVE_THRESHOLD` → auto-write (currently `Inf`, disabled)
  - `approved` + confidence < threshold → review queue
  - `flagged` + confidence < `CRITIC_ESCALATE_THRESHOLD` (0.60) → Claude tiebreak
  - `flagged`/`rejected` → review queue
  - `agentic_no_critic` → always review queue

### 4. Review queue + Shiny (`shiny/review_queue/app.R`, port 7474)
- Pending items land in `review_queue/queue.csv`
- Single canonical app handles all entity types + sessions
- → Detail: `docs/context_05_shiny.md`

### 5. Training data (`R/training.R`)
- Accepted-as-is → `training_data/sft.jsonl`
- Accepted-with-edit → `training_data/dpo.jsonl`
- Rejected → negative examples
- Agentic rows skip DPO (markdown R-assembled, not LLM-generated)

### 6. Vault write + commit
- `R/writer.R` writes markdown to vault
- `R/git_commit.R` stages via `git_status()$file` (explicit enumeration required — `git_add(".")` does not recursively stage untracked files in gert)
- `R/validator.R` runs pre/post-write format checks

---

## Key targets graph entry points

| Target | Purpose |
|---|---|
| `vtt_files` | Tracked VTT file list |
| `entity_passages` | Aggregated per-slug passage lists |
| `entity_agentic_extracted` | Agentic entity extraction results |
| `entity_agentic_fact_checked` | Grounding check results |
| `agentic_queue_consolidated` | Merged queue rows (cue = always) |
| `doc_registry_file` | Tracked `config/doc_registry.csv` |
| `entity_aliases_file` | Tracked `config/entity_aliases.csv` |

---

## Config files

| File | Contents |
|---|---|
| `config/protected_entities.csv` | Known PCs/key NPCs; entity_type controls keep/drop per chain |
| `config/entity_exclusions.csv` | Slug drop list (dm_voice, player roles) |
| `config/entity_aliases.csv` | Name variant → canonical slug bootstrap |
| `config/doc_registry.csv` | Episode → Google Doc tab mapping |
