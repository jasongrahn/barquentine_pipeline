# Stack Rank — Active Backlog

Last updated: 2026-05-15 (Phase D shipped: tool-calling loop + fallback in extract_entity(); captain P1 closed — not a bug).

Single-page checklist. Detail entries live in `docs/ideas.md`,
`docs/phase_next_backlog.md`, and `docs/phase_agentic_extraction_integration.md` —
this file links to them. Re-rank as work lands. Mark `[x]` when complete and
move to bottom of its section, don't delete.

---

## P0 — Must-do / blockers

- [ ] **Entity-chain generator regression** — gemma4 produces ungrounded
  templates; critic rewards compression. Blocks any entity publishing.
  Candidate fix: rewrite extraction prompt in Gemma4-native style (not
  Claude-shaped); raise `AGENTIC_ENTITY_PASSAGE_WORD_LIMIT` to use Gemma4's
  128K context for holistic (no-chunk) extraction; test `think = TRUE` on
  gemma4:latest via Ollama.
  [ideas.md → "Entity-chain generator produces ungrounded templates (P0)"]
  [oss_wiki_tools_investigation.md → Gemma4 capability audit]
- [ ] **Best-draft selection picks the worst draft** — contaminates every
  entity critic-loop run. Downstream of P0 #2 (both entity-chain).
  [ideas.md → "Best-draft selection picks the worst draft (P0)"]
- [x] **Citation scoring broken at model level** — replaced with APS grounding:
  `gurubot/gemma-2b-aps-it:Q4_K_M` extracts propositions from source;
  draft sentences matched by string-detect; coverage_score/matched/unmatched
  written to queue.csv; Shiny grounding panel shows result.
  (Phase C, commit `3a2c83e`, 2026-05-14)

## P1 — Important / ship-quality

- [ ] **Process s02e36 through agentic flow** — completes 3/3 gate; agentic
  can become default. [phase_agentic_extraction_integration.md → Rollout]
- [x] **Captain row carries stale `merged` status across runs** — investigated
  2026-05-15. Not a bug. Canonical routing merges captain → basil; no
  captain staging file is created; prior UI-set rejected/merged status
  persists correctly. consolidate_queue() logic is correct.
  [phase_gemma4_optimization.md → P1 section]
- [ ] **Consolidate the two Shiny apps into one `app.R`** — reviewer friction
  before broader rollout. [ideas.md → "Consolidate the two Shiny apps"]
- [ ] **`R/git_commit.R` bug** — vault commits don't include note files;
  worked around manually on the s02e34 publish.
  [ideas.md → "Fix `R/git_commit.R`"]
- [ ] **`doc_registry.csv` as targets file dependency** — [ideas.md → P1]
- [ ] **Markdown format validation (pre/post-write)** —
  [phase_next_backlog.md §1]

## P2 — Quality / phased work

- [x] **`pipeline_path` column on `queue.csv`** — done; values: `critic_loop`,
  `aps_grounding`, `aps_error`. Legacy rows backfilled `critic_loop`.
  (Phase C, commit `3a2c83e`, 2026-05-14)
- [ ] **Session-ingest skill (Gemma4 or Claude Code)** — adapt second-brain's
  ingest pattern for session recaps only (not entity pages). Adds
  takeaway-approval gate, wikilink generation, and index/log update to the
  session path. Two options: (a) Claude Code slash command (hand-written or
  generated via AgentHandover by recording a manual ingest demo; runs on API
  credits) or (b) Gemma4 function-calling chain in R via Ollama (tools:
  `propose_takeaways`, `write_session_page`, `update_vault_index`,
  `inject_wikilinks`; no API cost; requires `<tool_call>` XML parser in R on
  top of `call_ollama()`). Option (b) preferred given current credit situation.
  [oss_wiki_tools_investigation.md → Addendum]
- [ ] **Acknowledge critic loop is non-functional** — `CRITIC_AUTO_APPROVE_THRESHOLD: Inf`
  means every note goes to human review regardless of verdict; citation scoring
  is broken at the model level. Either fix or disable before Phase 4.2 resumes;
  don't carry it as paid latency overhead. [oss_wiki_tools_investigation.md → Consensus]
- [ ] **Phase 4.2 decision** (gated on 3/3): should agentic subsume the
  entity-note critic loop? More attractive if P0 #2 is hard to fix.
  [phase_agentic_extraction_integration.md → Phase 4]
- [ ] **Phase 2: chunk-extraction SFT capture** — agentic training data.
  [phase_agentic_extraction_integration.md → Phase 2]
- [ ] **Phase 3: Shiny agentic-flow badge + chunk inspector** — overlaps
  with P1 Shiny consolidation. [phase_agentic_extraction_integration.md → Phase 3]
- [ ] **`parse_error` iterations consume cap slots** — [ideas.md → P2]
- [ ] **Conditional generator prompt for prep vs play sources** —
  [ideas.md → P2]
- [ ] **Background regeneration queue (non-blocking UI)** —
  [phase_next_backlog.md §2]
- [ ] **`played_by` frontmatter on PC notes** —
  [phase_next_backlog.md §3]

## P3 — Backlog

- [ ] Open-source Claude Code subagents/skills survey
  (gated until after 3/3). [ideas.md → "Open-source Claude Code subagents"]
- [ ] Auto-evolving rejection-category chips — [ideas.md]
- [ ] YouTube transcript fetcher — [ideas.md → P2 there, P3 here]
- [ ] Run Pipeline button in Shiny — [phase_next_backlog.md §4]

## P4 — Deferred / not-yet-justified

- [ ] Document-store as generator/critic intermediate — [ideas.md]
- [ ] Phase 4.1 entity mining from DM prep sidecars —
  [phase_agentic_extraction_integration.md → Phase 4]
- [ ] `test-git_commit.R` fixture path issue (pre-existing, non-blocking) —
  [CLAUDE.md gotchas]

---

## Completed (recent)

- [x] **Phase D — Gemma4 tool-calling loop** — `parse_tool_calls()` added to
  `R/ollama.R`; `extract_entity()` rewritten as 3-turn tool-call loop with
  `format=` fallback; `pipeline_path` field on extraction result.
  D0 wet run (s02e36): all 6 entities coverage_score=0, identity confusion
  dominant; APS matcher direction bug noted; D proceeded per threshold rules.
  (2026-05-15)
- [x] **Fix `agentic_queue_consolidated` skip bug** — agentic dispatch
  returns same-shape list across runs, so targets skipped consolidation
  and the s02e35 agentic row sat orphaned in staging until manual
  consolidate_queue(). Now cue=always. (commit `0f0d720`, 2026-05-12)
- [x] **Final verdict's `issues` array doesn't propagate to queue.csv** —
  agentic-flow specific: `dispatch_agentic_session` hardcoded
  `issues = list()`; reviewer flies blind. Fixed by rendering unsupported
  fact_check rows into kind+line+claim strings; `.frame_results` retains
  claim text. (commit `0f0d720`, 2026-05-12)
- [x] Process s02e35 through agentic flow — published to vault commit
  `57aaece`; pipeline commit `483b884`. 2/3 toward session-note gate.
  (2026-05-12)
- [x] Phase 5 — Port agentic noise filters into entity chain
  (commits `47a176f` + `a2ad4aa`, 2026-05-11)
- [x] First live agentic publish — s02e34 session note + ted skeleton to vault
  (commit `8a1041d` vault, `4d1add9` pipeline, 2026-05-11)
- [x] Phase 0 — Foundation: agentic flow shipped behind per-session opt-in
- [x] Phase 1 — Quality fixes from prototype (filter dm_voice/unnamed,
  collapse near-typo locations)
