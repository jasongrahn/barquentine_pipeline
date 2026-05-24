# Stack Rank — Active Backlog

Last updated: 2026-05-23 (session note orientation complete; entity_aliases_file tracker fix landed in _targets.R; pre-fix wet run assessed: lumi+room PASS, basil+giff_flotilla FAIL, attorrnash+ted empty). Next: (1) user approves s02e36__agentic in Shiny → DRY_RUN=FALSE → tar_make() → vault commit → 3/3 gate closes; (2) run tar_invalidate("alias_registry") + tar_make() to get fresh entity extractions with all F-fixes; (3) F0 Bug #15260 verification (manual Ollama run, lowest priority).

Single-page checklist. Detail entries live in `docs/ideas.md`,
`docs/phase_next_backlog.md`, and `docs/phase_agentic_extraction_integration.md` —
this file links to them. Re-rank as work lands. Mark `[x]` when complete and
move to bottom of its section, don't delete.

---

## P0 — Must-do / blockers

- [ ] **Entity-chain generator regression** — root cause is identity confusion:
  Gemma4 writes about the most prominent character in multi-character VTT passages,
  not the target entity. 4/6 entities show this in s02e36. Blocks entity publishing.
  F2a positive focus anchor landed (replaces E3 negation framing; added at start +
  end of prompt for recency bias); F0.5 format=NULL + R-side parse in place;
  F4 APS replaced by substring grounding. F1 wet run validates all three.
  Next lever if F1 < 4/6: F2 vault note prepend (gives model correct gender/role upfront).
  Ruled out: thinking mode, 128K context window, XML tool-calling, APS grounding.
  [phase_gemma4_optimization.md → Phase F]
  [ideas.md → "Feed existing vault note" + "Entity-chain generator produces ungrounded templates"]
- [x] **Best-draft selection picks the worst draft** — fixed commit `300078c`.
  `select_best_draft()` now ranks by verdict tier (approved > flagged > rejected),
  then fewest issues, then latest iteration. Confidence no longer used as tiebreaker
  across verdict classes.
  [ideas.md → "Best-draft selection picks the worst draft (P0)"]
- [x] **Citation scoring broken at model level** — replaced with APS grounding:
  `gurubot/gemma-2b-aps-it:Q4_K_M` extracts propositions from source;
  draft sentences matched by string-detect; coverage_score/matched/unmatched
  written to queue.csv; Shiny grounding panel shows result.
  (Phase C, commit `3a2c83e`, 2026-05-14)

## P1 — Important / ship-quality

- [x] **APS matcher direction bug** — fixed 2026-05-15. `str_detect(claim, proposition)`
  (correct direction). 29/29 tests pass. attorrnash now scores 0.20; others 0.0 (template
  output, not matcher bug). [phase_gemma4_optimization.md → Phase E Findings]
- [x] **Verify Phase D tool-calling fires on live hardware** — confirmed 2026-05-15.
  1/6 entities (ted) fired `tool_calling`; 5/6 fell back. ted's tool_call output is
  all-nulls (Gemma4 emits valid XML but populates arguments with null). Fallback (format=)
  produces better content than tool_calling null-fill. Next: try Ollama native tools
  parameter or defer tool calling. [phase_gemma4_optimization.md → Phase E Findings]
- [x] **F1 wet run — validate E3 focus anchor** — 3/5 dispatched entities correct
  (basil, lumi, room); attorrnash filtered by MIN_ENTITY_CHUNK_COUNT raise (correct);
  ted empty (sparse passages — expected). (2026-05-22)
  [phase_gemma4_optimization.md → Phase F, F1]
- [x] **F2 — Feed existing vault note as identity anchor** — vault note prepend
  implemented; gate on file existence working; identity confusion resolved for all
  3 PCs across 4 wet runs; ted anchor injected, correctly empty. (2026-05-22)
  [phase_gemma4_optimization.md → Phase F, F2] [ideas.md → "Feed existing vault note"]
- [x] **F3 — Tool calling retired** — F3pre: zero tool template hits in gemma4 modelfile.
  3-turn loop + `.entity_tc_system()` removed from `extract_entity()`. (2026-05-15)
- [x] **F4 — APS replaced by source-sentence substring grounding** — `fact_check_entity()`
  now uses `str_detect(source_text, fixed(claim))`. No LLM call; pure R. `aps_proposition_count`
  column preserved (holds source sentence count). (2026-05-15)
- [ ] **Process s02e36 through agentic flow** — session note s02e36__agentic is
  in queue as `pending` (enqueued 2026-05-14); 20 line cites, 8215 chars, proper
  structure, 9 grounding issues (expected false positives). User action required:
  review+approve in Shiny → set DRY_RUN=FALSE in config.R → tar_make() → vault
  commit. This closes the 3/3 gate.
  [phase_agentic_extraction_integration.md → Rollout]
- [x] **Captain row carries stale `merged` status across runs** — investigated
  2026-05-15. Not a bug. Canonical routing merges captain → basil; no
  captain staging file is created; prior UI-set rejected/merged status
  persists correctly. consolidate_queue() logic is correct.
  [phase_gemma4_optimization.md → P1 section]
- [x] **Consolidate the two Shiny apps into one `app.R`** — `shiny/review_queue/app.R`
  is now the single canonical app (port 7474). Added: `R/review.R` + `R/training.R`
  sources, `append_review_entry()` for session approve/reject, `generate_training_data()`
  on all actions, iteration badges in render_session.R, fixed duplicate source pane.
  `shiny/app.R` retired. (2026-05-23) [ideas.md → "Consolidate the two Shiny apps"]
- [x] **`R/git_commit.R` bug** — fixed 2026-05-23. `git_add(".", ...)` in gert
  doesn't recursively stage untracked files. Now enumerates `git_status()$file`,
  filters `.obsidian/`, stages explicitly, and errors if no note paths are staged.
  1219 tests pass. [ideas.md → "Fix `R/git_commit.R`"]
- [x] **`doc_registry.csv` as targets file dependency** — added `tar_target(doc_registry_file, DOC_REGISTRY_PATH, format = "file")` to `_targets.R`; `fetch_all_episode_docs()` now receives the tracked path, so changing the registry correctly invalidates the cache. (2026-05-23) [ideas.md → P1]
- [x] **`entity_aliases.csv` as targets file dependency** — added `tar_target(entity_aliases_file, ENTITY_ALIASES_PATH, format = "file")` to `_targets.R`; `build_alias_registry()` now takes the tracked path, so alias CSV changes (e.g. adding Adernash) correctly invalidate `alias_registry` and all downstream entity targets. Same pattern as doc_registry fix. (2026-05-23)
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

- [x] **Phase F remaining issues** — word-overlap fallback grounding (≥50% content
  words present in source), attorrnash aliases added to entity_aliases.csv,
  the_giff_flotilla system prompt synced to schema v2 (removed `connections` field).
  (commit `780db23`, 2026-05-23)
- [x] **Phase F immediate tasks** — F3pre (zero tool template → tool calling retired),
  F2a (positive focus anchor in all 4 user_templates, head + tail), F0.5 (format=NULL +
  R-side fence-strip/JSON-parse/schema-validate fallback), F4 (APS → substring grounding).
  1204 tests pass. (2026-05-15)
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
