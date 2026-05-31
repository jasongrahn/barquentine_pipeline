# Context 04 — Entity Agentic Chain (Phase 4.2)

Schema-enforced extraction replaces the generator-critic loop for entity wiki pages. Ships behind a per-session opt-in. Phase 0 shipped; 3/3 gate closed.

→ Full spec + decisions: `docs/phase_4_2/`
→ Load order for implementation: `docs/phase_4_2/README.md`

---

## Opt-in

```r
# config.R
AGENTIC_ENTITY_SESSION_IDS <- c("s02e36", "s02e37")  # episodes to run through agentic entity chain
```

Any entity whose `source_episode_ids` overlaps this vector uses the agentic chain. All others use the legacy critic loop.

---

## Four entity types + schemas

All schemas in `R/agentic_entity_schemas.R`. Skill prompts in `agents/wiki_skills/05–08`.

| Type | Skill | Key schema fields | Required field |
|---|---|---|---|
| PC | `05_extract_pc` | bio, description, aliases, exhibited_personality, role_in_story | `description` |
| NPC | `06_extract_npc` | description, aliases, exhibited_personality, role_in_story, affiliations | `description` |
| Location | `07_extract_location` | description, region, notable_features, events_witnessed | `description` |
| Faction | `08_extract_faction` | description, goals, known_members, allies, enemies | `description` |

**All non-trivial fields use `{value, line}` pairs** for line-citation grounding. Null defaults reduce fabrication — model returns `null` when evidence absent rather than inventing content.

**Always include ≥1 required field.** `required=character(0)` lets Ollama emit `{}` → NULL abort in `.parse_entity_json()`.

---

## Agentic entity chain flow

```
aggregate_entity_passages()          R/source_c.R
        │
        ▼
extract_entity_agentic()             R/agentic_entity_extract.R
  - reads existing vault note (.read_vault_note) as identity anchor
  - calls gemma4 with format=entity_schema()
  - R-side JSON parse + schema validate
        │
        ▼
assemble_entity_markdown()           R/agentic_entity_writer.R
  - assembles frontmatter + sections from extracted fields
  - one Synopsis LLM call for prose description
        │
        ▼
fact_check_entity()                  R/agentic_entity_fact_check.R
  - existing_note appended to source_text (vault-derived claims count as grounded)
  - substring grounding: str_detect(source_text, fixed(claim))
  - word-overlap fallback (≥50% content words ≥4 chars)
  - returns coverage_score, matched, unmatched
        │
        ▼
dispatch_agentic_entity()            R/agentic_entity_dispatch.R
  - verdict = "agentic_no_critic" → always review queue
  - writes to review_queue/queue.csv
```

---

## Canonical routing (alias collapse)

At passage aggregation, alias slugs from `config/protected_entities.csv` merge into their canonical slug **before** any chain runs. This is not gated on `AGENTIC_ENTITY_SESSION_IDS` — fires for every run.

Example: `captain` + `the_captain` passages → merged into `basil` record; `entity_name` set to "Basil"; `note_type` enriched to `"pc"`.

→ Full routing logic: `docs/phase_4_2/decisions/alias_routing.md`

---

## PC/pc_alias two-chain divergence (CRITICAL — do not mirror filters)

| `entity_type` | Agentic session (recap NPC list) | Entity chain (wiki page) |
|---|---|---|
| `pc` | **DROP** — PCs not in recap NPC list | **KEEP** — protagonists need wikis |
| `pc_alias` | **DROP** | **KEEP** — Merge UI collapses into canonical PC |
| `player` | drop | drop |
| `dm_voice` | drop | drop |

The agentic chain's `filter_pc_and_player_npcs()` (`R/agentic_postprocess.R`) drops `pc`/`pc_alias` from the session recap. The entity chain (`R/source_c.R`) does NOT — it generates per-character wiki pages. Do not blindly port filters across chains.

---

## Key files

| File | Purpose |
|---|---|
| `R/agentic_entity_extract.R` | Extraction + vault note anchor injection |
| `R/agentic_entity_schemas.R` | Four JSON schemas (npc, pc, location, faction) |
| `R/agentic_entity_writer.R` | R-assembled markdown from extracted fields |
| `R/agentic_entity_fact_check.R` | Substring + word-overlap grounding check |
| `R/agentic_entity_dispatch.R` | Queue row creation + dispatch |
| `agents/wiki_skills/05–08` | System prompts + user templates per entity type |
| `config/protected_entities.csv` | PC/NPC roster; `entity_type` column controls routing |
| `config/entity_aliases.csv` | Name variant → canonical slug bootstrap |

---

## Phase roadmap

| Phase | Status | Description |
|---|---|---|
| 0 — Foundation | ✅ Shipped | Schemas, prompts, extraction, R-assembly, fact-check, dispatch, targets wiring |
| 1 — Refinements | ✅ Shipped | Vault anchor, schema v2 (dropped alignment/affiliations/connections), substring grounding |
| 2 — Training capture | Planned | Per-entity SFT capture for extraction step |
| 3 — Observability | Planned | Shiny badges + run summary |
| 4 — Rollout | Planned | Default flip (remove opt-in requirement) |

→ Phase detail: `docs/phase_4_2/phases/`
