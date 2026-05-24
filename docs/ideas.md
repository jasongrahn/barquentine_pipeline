# Ideas Backlog

Ideas worth revisiting but not yet justified by current pain points.

---

## TODO: Feed existing vault note into extraction prompt (Phase F candidate)

**Status:** TODO (P1 once identity confusion is stabilized).
**Origin:** 2026-05-15 — raised during Phase E analysis of what happens when
player-written first-drafts exist for PCs and regular NPCs.

**Problem:** The extraction prompt currently ignores `existing_note` entirely — it
drafts from scratch every run. With player-written content in the vault, the
current behavior is "generate a competing full draft, show diff, reviewer decides."
This has two failure modes that get worse with existing notes:

1. Identity confusion drafts (4/6 in s02e36) propose overwriting correct player
   lore with wrong-character facts. Reviewer must read every diff line carefully.
2. Tool calling null-fill (if that path fires) would overwrite existing content
   with null fields — must verify writer skips nulls before processing any entity
   with an existing note.

**Fix:** Feed the existing vault note into the extraction prompt as context:
*"Here is the current wiki page. Extract only information from these new passages
that adds to or contradicts it. Do not re-draft sections already present."*
This shifts the model's job from full-draft generation to delta-detection.
Side benefit: the existing note gives the model correct identity facts (gender,
role, aliases) upfront — directly fights identity confusion without relying on
the focus anchor alone.

**Section-level authorship split (follow-on):** For PCs with rich player-written
backstory, mark certain sections (e.g. "Background", "Personality") as player-owned
in the frontmatter. Extraction only proposes updates to session-derived sections
("Recent Events", "Role in Story"). This is a distinct concern from delta-detection
and should be a separate ticket.

**Why deferred:** Identity confusion must be resolved first (E3 focus anchor
pending validation). Feeding a confused draft into an already-confused extraction
pass doubles the damage. Validate E3 → then implement feed-in.

**When to implement:** After focus anchor (E3) shows measurable improvement on
lumi and basil. First-pass implementation: read existing_note in
`agentic_entity_extract.R` and append it to the user prompt before SOURCE PASSAGES.

---

## Document Store as Generator/Critic Intermediate Layer

**Idea:** Write generator drafts to a local document store (SQLite via DBI/RSQLite)
keyed by section_id/entity_id, rather than passing text blobs through targets'
object cache. The critic reads from the DB by key; dispatcher reads draft + verdict
by key.

**Why it was considered:** Performance, reliability, memory consumption, and
parallel vs serial processing concerns during pipeline development (2026-05).

**Why we held off:** Ollama's single-threaded inference is the real bottleneck —
a DB layer wouldn't enable parallel Ollama calls. targets already writes RDS
to disk so large strings aren't purely in-memory. The reliability wins from
`error="continue"` + `run_pipeline()` retry loop addressed the actual pain points.

**When to revisit:**
- Running multiple Ollama instances (local + cloud) that need coordination
- Scaling to a second machine where a shared DB becomes the coordination layer
- targets RDS cache causing measurable memory pressure during a run (`top` during
  run would confirm this first)
- Wanting record-level resume granularity within a single target's branches

---

## Auto-Evolving Rejection Category Chips

**Idea:** As rejection notes accumulate in `negatives.jsonl`, periodically cluster
the free-text `reject_reason` field and graduate high-frequency clusters into named
quick-select chips in the Shiny review UI.

**Mechanism:**
1. **Base chips** — a hardcoded floor set (e.g., "Hallucination", "Wrong session",
   "Off-topic", "Fabricated NPC detail") always present in the UI.
2. **Cluster pass** — triggered automatically after every N rejections (e.g., 10),
   embed all `reject_reason` strings (via a small local model or Claude) and run
   k-means / HDBSCAN. Clusters with ≥ threshold members (e.g., 5) that don't
   already match a base chip get named by Claude and written to
   `config/rejection_categories.json`.
3. **UI reads on load** — Shiny reads `rejection_categories.json` at startup;
   learned chips appear alongside base chips. Free-text input remains available
   for novel cases.
4. **Chip label generation** — pass 3–5 representative notes from the cluster to
   Claude with: "Name this rejection category in 3–5 words." Store the label +
   representative examples in the JSON for auditability.

**Why it was considered:** Rejection notes are only useful for fine-tuning if the
*type* of failure is labeled. Manual taxonomy doesn't scale; emergent categories
from real reviewer behavior are more honest.

**Why we held off:** Need a critical mass of rejections first (~30–50) before
clustering is meaningful. Implement basic reject+note UI first.

**When to revisit:**
- `negatives.jsonl` has 30+ entries with free-text notes
- Reviewer is copy-pasting the same reason repeatedly (signal that a chip would help)
- Want to slice fine-tuning data by failure type

---

## Recursive Critic-Guided Drafting (Priority) → see `recursive_critic_loop_design.md`

**Idea:** Feed the critic's structured findings back to the generator as revision
instructions before the draft ever reaches the human reviewer. Run this as a bounded
loop (generate → critic → revise → critic → …) and only surface the result once the
critic approves or the iteration cap is hit. Process one session at a time so each
published session can inform the next.

**Two nested loops:**

1. **Inner loop (intra-session refinement):**
   - Generator produces draft
   - Critic evaluates; returns `{verdict, confidence, issues, quotes}`
   - If `flagged` or `rejected`, pass issues back to generator with a constrained
     revision prompt: *"Revise only to address these specific findings; do not change
     anything not mentioned"*
   - Repeat up to `DRAFT_MAX_ITERATIONS` (proposed default: 3)
   - Break early if critic returns `approved` with confidence ≥ threshold
   - Send final draft + full iteration history to review queue

2. **Outer loop (inter-session context):**
   - Each session is processed one at a time (not batched)
   - After a session is approved and published to the vault, the next session's
     generator reads the vault as grounding context — established entity names,
     relationships, and facts carry forward
   - This is a more systematic version of the existing `existing_note` mechanism

**Training data implications:**
- Each intermediate draft + critic verdict = a DPO pair (earlier draft = rejected,
  revised draft = chosen), even if both came from the model
- The iteration count per section is signal: high iteration = harder section, useful
  metadata for fine-tuning curriculum

**Why it matters:** The critic's structured output (`issues` + `quotes`) is already
exactly the right format to drive a revision prompt. Currently that signal goes to
the human; routing it back to the generator first reduces reviewer cognitive load and
produces tighter drafts.

**Resolved design decisions (2026-05-09):**

- **Revision prompt scope:** Middle ground — *"Correct the specific issues listed.
  You may rephrase immediately surrounding sentences for readability, but do not add
  new facts, remove sections, or change anything not adjacent to a listed issue."*
  Fall back to conservative fix-only if this produces drift in practice.

- **Iteration cap + escalation:** `DRAFT_MAX_ITERATIONS = 5`. After 5 failed
  attempts, escalate to Claude for the revision (not just tiebreak — full rewrite
  attempt). Capture the Claude output as a DPO pair: final Ollama draft = rejected,
  Claude revision = chosen. This feeds Claude-quality corrections back into training.

- **Session ordering:** Strictly one session at a time. Each session must be fully
  approved and published before the next is processed. Gap sessions (missing source
  notes) get a placeholder vault entry: *"No session notes available for [episode]."*
  Placeholder can be written manually by the DM or auto-generated. Vault can be
  wiped and rebuilt from scratch to enforce correct ordering.

**When to implement:** Now — this is the highest-priority pipeline improvement as of
2026-05-09.

---

## TODO: Fix `R/git_commit.R` — vault commits do not include note files

**Status:** TODO (real bug, not aspirational)
**Discovered:** 2026-05-09 during pre-validation vault inspection.

**Symptom:** `barquentine_wiki/BarquentineWiki` had three commits in its history:
```
d1fe0f1 Session S2e42 — auto-generated [2026-05-08]
b964455 Session S2e42 — auto-generated [2026-05-07]
f304aeb init vault
```
Both `Session S2e42 — auto-generated` commits only changed `.obsidian/workspace.json`
and `review/review_log.md`. They did **not** include any session notes or entity notes.
Meanwhile the working tree contained eight uncommitted untracked notes
(`sessions/S1e5.md`, `sessions/S1e9.md`, `sessions/S1e10.md`, `sessions/S2e9.md`,
`npcs/the_admiral.md`, `factions/giff.md`, `Room.md`, `lion-handed.md`) — all written
by the pipeline but never staged.

**Root cause hypothesis (not yet confirmed):** `R/git_commit.R` is likely doing a
narrow `git add` (e.g. of only `review/review_log.md`) instead of staging the new note
files written by `R/writer.R` in the same run. Or the working directory at the time
of `git add` doesn't include the note paths.

**Why this matters:**
- All published notes were silently lost from version history. Recovery is
  working-tree-only — one `git checkout` or one accidental `rm` permanently destroys
  reviewer-approved content.
- The Story So Far / outer loop design assumes the vault's git log is the campaign's
  authoritative history. If commits don't include the actual content, that assumption
  is broken from day one of the recursive-loop rollout.
- Auto-generated commit messages naming `S2e42` while changing only Obsidian state is
  actively misleading.

**Fix sketch:**
1. Read `R/git_commit.R` and identify the `git add` invocation.
2. Stage all changes in `sessions/`, `npcs/`, `locations/`, `factions/`, and any
   top-level note paths the writer produces. Avoid staging `.obsidian/` (Obsidian
   working state — not authoritative).
3. Add a post-commit assertion: `git show --stat HEAD` must report at least one path
   under `sessions/` or an entity directory for any commit titled `Session ...`.
   If not, throw — bad commit shape should fail loudly, not pass silently.
4. Add a test: write a fake note via `write_note()` to a temp git repo, call
   `git_commit_session()`, then assert the resulting commit's `git show --stat`
   includes the note path.

**When to implement:** Before the recursive critic loop ships any approved notes from
the validation pass forward. Otherwise the loop's training-data and outer-loop
correctness story sits on a broken foundation.

---

## TODO: Best-draft selection picks the worst draft (P0)

**Status:** TODO. Surfaced 2026-05-09 during s01e01 validation run.

**Symptom:** After 6 inner-loop iterations + 1 Claude escalation, the queue's
`final_draft` sent to the reviewer was **3724 chars, rejected at confidence 0.97** —
identical to iteration 1's draft. Iteration 6 produced a tighter 524-char draft with
fewer issues (4 vs 9), but the wrapper selected iter 1.

**Root cause hypothesis:** `draft_with_refinement()` tracks "best draft = highest
critic confidence." When all iterations are `rejected`, "highest confidence" picks
the draft the critic was *most certain was bad*. The reviewer ends up with the
worst-quality draft from the loop instead of the least-bad one.

**Fix:** The selection function needs to score by `confidence × is_approved` — or
equivalently:
1. Among `approved` iterations, pick highest confidence.
2. If no iteration approved, fall back among `flagged` (lowest-issue-count, then
   highest confidence).
3. If all rejected, fall back among `rejected` (lowest-issue-count, then lowest
   confidence — confidence-in-rejection is the *opposite* signal of "best").

**Why this matters now:** Until this is fixed, the reviewer cannot meaningfully
evaluate the loop's output — they're shown the *most confidently flawed* draft, not
the *closest-to-acceptable* one. Even with `DRAFT_MAX_ITERATIONS = 6L` doing useful
refinement work, the reviewer only sees the worst version.

**When to implement:** Before any further validation runs. Without this fix every
"the loop produced a bad draft" observation is contaminated by the selection bug.

---

## TODO: Entity-chain generator produces ungrounded templates (P0)

**Status:** TODO. Surfaced 2026-05-11 during s02e34 entity-row QA (post-fix wet run).

**Symptom:** 5 of 7 entity rows (`lumi`, `room`, `the_captain`, `the_giff_flotilla`,
`attorrnash`) have approved/flagged drafts that contain **no session-specific
content** despite source passages containing usable play material. Drafts are
generic personality templates with invented sample dialogue and placeholder
text (e.g. `"On a scale of one to ten, and what metrics define the 'seven'?"`,
`[name of flotilla/city]`, fabricated quotes like `"Man, does this place have an
OSHA report?"`). Only `ted` (1-chunk protected-bypass row) uses the wiki
frontmatter template properly.

**Root cause hypothesis:** Two-stage failure:
1. **Iter 1 generator (gemma4:latest)** produces generic templates instead of
   grounding in the passed `source_text`. Iter 1 of `the_captain` (3081 chars,
   rejected) is just as ungrounded as the eventually-approved iter 4 (785 chars).
   So the regression is in the generator at draft-1, not introduced by the loop.
2. **The critic loop compresses rather than re-grounds.** When the generator
   can't address a flagged issue factually, removing the claim satisfies the
   critic. Successive iterations of `room` (2012 → 1452 → 1345 → 1412 → 1293
   chars) and `the_giff_flotilla` (2131 → 1079 → 1805) shed concrete content
   until the critic has nothing left to flag. Critic approves an emptier
   draft, reviewer sees a thin generic page.

**Why this matters:** The entity-note critic loop's success metric (critic
approval) is decoupled from "draft contains actual session content." Until
both halves are fixed, the entity chain cannot publish meaningful wikis at
scale — every approved row needs reviewer rewrite-from-scratch, which is
below the `feedback_publish_bar.md` "good enough, players can edit" bar.

**Note on the `attorrnash` sub-case:** the name spotter correctly identified
Attorrnash as an NPC (real character — the Astral Cartomancer "dowar"), but
the literal name only appears once in the VTT, in the DM-prep block at the
file head. The aggregated passages don't contain the name, so the generator
had no anchor. This is a related but distinct issue: passage-aggregation
sometimes pulls chunks that don't contain the entity reference. Worth tracking
as a sub-fix.

**Fix sketch:**
- Audit `R/extract.R::generate_entity_note()` prompt — confirm it actually
  passes `source_text` and instructs the model to quote from it.
- Add a hard rule in the prompt: *"Every personality / relationship / role
  claim must cite a passage by speaker + verb. Refuse to make a claim that
  cannot be cited."* — modeled on `CRITIC_SYSTEM_PROMPT`'s quote requirement.
- Consider a generator-side "quote density" check before critic invocation:
  if draft has < N direct quotes from `source_text`, force a regeneration with
  stronger grounding pressure rather than burning a critic slot.
- For the `attorrnash`-style "name in prep but not in play" case: pass the
  prep block (where the name is defined) as additional context to the
  generator when an entity has < N source-text occurrences of its own name.
- Re-evaluate the critic-loop incentive: if the critic rewards content
  removal, it's optimizing for the wrong objective. Consider a min-quote-count
  floor that the critic enforces alongside accuracy.

**When to implement:** Before resuming entity-chain publishing. The agentic
session-note flow is unaffected (different code path, no generator-loop). For
the current s02e34 publish, reject all entity rows except `ted` and ship only
the session note. Phase 4.2 (route agentic-extracted entities into the
entity-note critic loop) becomes more attractive if this generator regression
is hard to fix — gated on 3 approved sessions either way.

---

## TODO: parse_error iterations consume cap slots (P2)

**Status:** TODO. Surfaced 2026-05-09 during s01e01 validation run.

**Symptom:** Iteration 5 returned `verdict = "parse_error", confidence = 0` —
the critic's JSON output was malformed. That iteration burned one of the 6 cap slots
without producing any actionable signal. The loop ran 5 useful iterations (1, 2, 3,
4, 6) and one wasted slot.

**Fix sketch:** In `draft_with_refinement()`, when the critic returns `parse_error`,
either (a) retry the critic call once with a slightly-jittered seed/temperature
before incrementing iteration count, or (b) record the parse error in
`iteration_log` for diagnostics but don't increment `iteration` for cap purposes.
Option (a) is more honest; option (b) is simpler.

**Why deferred:** This is a tax on every loop invocation, but a small one
(1-in-N iterations parse-fail). Bug 1 (best-draft selection) is the actual blocker.

---

## TODO: Final verdict's `issues` array doesn't propagate to queue.csv (P1)

**Status:** TODO. Surfaced 2026-05-09 during s01e01 validation run.

**Symptom:** Iteration 7's verdict (Claude cap-hit revision) reported 9 issues, but
the queue row's `issues` column is empty. Reviewer opens the Shiny card and sees
"no critic findings" — which is wrong; there are 9, the data just didn't flow
through.

**Suspect:** The `dispatch_note()` path in `R/router.R` likely copies issues from
the original Ollama critic call to the queue, then overwrites/skips on the Claude
escalation path. Or `consolidate_queue()` truncates the field. Need to trace from
`final_verdict` in `draft_with_refinement()` through to the queue write.

**Why this matters:** Issues are the reviewer's primary diagnostic. Without them
visible in the UI, the reviewer is making approve/reject decisions blind even when
the system has the data.

**When to implement:** After Bug 1. They're often co-located in the same
dispatch path.

---

## TODO: Conditional generator prompt for prep-source vs play-source documents

**Status:** TODO (P2 — improves output quality for pre-VTT sessions).
**Origin:** s01e01 validation revealed source-content mismatch — that doc is the
DM's pre-session outline, not session play notes. The default generator prompt
asks for a session summary, the source describes plans, the critic correctly
rejects every attempt because the source has no factual ground for "what happened."

**Fix sketch:**
- Add a soft prompt variant: *"This document **may be** the DM's pre-session
  outline rather than play notes. If the source describes what was *planned* (NPCs
  to introduce, scenes to run, encounters to set up) without describing what
  actually happened, label the output as `source_kind: prep` and capture the
  planned content as 'Adventure Outline' rather than 'Session Summary'. Mark
  `[unclear]` for any element that isn't grounded in the source. If the source
  describes actions the PCs took, label as `source_kind: play` and write a session
  summary as normal. Hybrid sources (some prep, some play) use
  `source_kind: hybrid`."*
- Output schema gains a `source_kind` field that the reviewer sees on the Shiny card.
- No router change needed — the generator self-classifies and reviewers know what
  they're looking at.

**Why deferred:** Validating against play data (s02e34+) is the higher-priority
unblocker. Once the loop is known to work on real play sources, this prompt variant
unlocks early sessions for automation. Until transcripts arrive for s01e01–s02e33,
or this prompt variant ships, those sessions stay manually authored.

---

## TODO: YouTube transcript fetcher for pre-VTT sessions

**Status:** TODO (P3 — unlocks early-session automation if YouTube has them).
**Origin:** User noted (2026-05-09) that pre-VTT sessions (s01e01–s02e33) might be
recoverable from YouTube — old streams may have auto-generated captions or community
transcripts. Not guaranteed.

**Goal:** Build a fetcher that, given a session ID and a YouTube URL, downloads the
transcript (e.g. via `yt-dlp --write-auto-sub --skip-download` or YouTube's official
transcript API), normalizes it into the same VTT shape `R/source_c.R` consumes, and
writes it to `/Volumes/share/videos/` (or wherever `NAS_MOUNT` points) with the
filename convention the existing `vtt_registry.csv` expects.

**Where it fits:** Becomes a new `R/source_d.R` (or extends `R/source_c.R`).
Pipeline-wise, sessions with a YouTube transcript become equivalent to sessions
with a VTT — same Phase 3 entity-spotting path runs over them.

**Open questions:**
- Auto-captions vs human transcripts — quality varies wildly. May need a manual
  cleanup step before they hit `process_vtt_file()`.
- Speaker diarization — Zoom VTTs label speakers; YouTube auto-captions don't.
  Entity-spotting may suffer without speaker context.
- Cost / rate limits if using a paid transcription API as a fallback.

**When to implement:** After validating the loop on s02e34 (which has a real Zoom
VTT). If the loop performs well there, the YouTube transcript path is the obvious
extension to backfill early sessions. If the loop performs poorly, fix the loop
first before adding more sources.

---

## TODO: Track `doc_registry.csv` as a targets file dependency (P1)

**Status:** TODO. Surfaced 2026-05-09 when re-running on s02e34 after a prior s01e01 run.

**Symptom:** Changing `CURRENT_SESSION` from `s01e01` to `s02e34` and re-seeding
`config/doc_registry.csv` did not cause `source_b_sections_all` to re-run. Targets
served the cached value from the s01e01 run (one section, `s01e01`). The downstream
filter `source_b_sections_all[names(...) == CURRENT_SESSION]` then yielded an empty
list and the pipeline failed at `session_refined`'s pattern with
`cannot branch over empty target (source_b_sections)`.

**Root cause:** `source_b_sections_all` calls `fetch_all_episode_docs(...)` which
reads `config/doc_registry.csv` from disk. Targets only tracks function code and
argument hashes — file reads inside the function body are invisible to the cache
invalidation logic, so the result is treated as deterministic when it isn't.

**Workaround in use:** Manually run `targets::tar_invalidate(everything())` before
each pipeline run that touches the registry. Wasteful (re-fetches everything) and
easy to forget.

**Fix:** Make the registry a tracked file dependency of the fetch target.

```r
tar_target(doc_registry_file, DOC_REGISTRY_PATH, format = "file"),

tar_target(source_b_sections_all,
           fetch_all_episode_docs(EPISODE_NOTES_FOLDER_ID,
                                  doc_registry_file,   # consumes tracked path
                                  VAULT_PATH),
           format = "rds"),
```

The `format = "file"` target tracks the registry file's hash; any edit to the CSV
(seeding, manual additions) invalidates `doc_registry_file` and cascades to
`source_b_sections_all`. Same pattern is already used in `_targets.R` for
`vtt_registry_path` and `sft_example_files`.

**Why P1:** Until this is fixed, every change to the registry needs a manual
`tar_invalidate()` call, and forgetting one produces a confusing empty-branch error.
Worse, in a future run with multiple sessions in the registry, a stale cache could
silently process the wrong session set.

**When to implement:** Before the next validation run after s02e34. Same path
applies to `protected_entities.csv`, `entity_exclusions.csv`, and `entity_aliases.csv`
— they're all read-from-disk inside functions targets can't see.

---

## Open-source Claude Code subagents / skills survey

**Idea:** Audit community-maintained Claude Code subagent and skill catalogs to
see if any drop-in agents could replace or augment work the pipeline currently
asks the local Ollama loop to do. Reference catalog:
`https://github.com/VoltAgent/awesome-claude-code-subagents`.

**What to look for specifically:**
- A **structured-extraction agent** that does what `R/agentic_extract.R` does
  (per-chunk schema-enforced extraction with line citations) but better, or
  with prompt patterns we can lift into our own skill prompts.
- A **fact-check / verification agent** that could replace
  `R/agentic_fact_check.R::verify_line_citations` or the LLM critic in
  `R/critic.R` — Claude Code subagents that already enforce "cite-or-die"
  semantics may outperform our llama3.1:8b critic for difficult sections.
- A **markdown-validator agent** for the format-validation backlog item in
  `project_barquentine_backlog.md`. The pre-write / post-write validator we
  sketched could plausibly be a Claude Code skill we configure rather than
  R code we maintain.
- A **review-queue / triage agent** that could mediate between the Shiny UI
  and the reviewer for batch actions ("merge all PC aliases into their
  canonical slug", "regenerate everything flagged with confidence < 0.5").
- An **R/data-pipeline agent** that knows targets idioms — could shorten the
  ramp time for future contributors editing `_targets.R`.

**Why it matters:** Two of our most expensive maintenance lines are
(a) prompt engineering for entity / critic / synthesis skills, and (b) the
recurring "8B-model fabrication" failure mode that drove the agentic flow
pivot in the first place. If a vetted community subagent already encodes a
better prompt pattern, copying it is cheaper than re-deriving it. Worst case
we learn the failure modes others hit and avoid them.

**Why we're not doing this yet:** No evidence-based comparison method exists
in-repo. Adopting an external agent without an A/B against our current
prompts risks swapping a known-good failure mode for an unknown one. Need
the agentic rollout to reach 3/3 first so we have a stable baseline to
compare against.

**Fix sketch / first steps when revisited:**
1. Read the README index of `VoltAgent/awesome-claude-code-subagents` and
   pick at most 3 candidates whose stated function maps onto a pipeline
   skill we currently own.
2. For each candidate, run it side-by-side with our current skill on the
   s02e34 corpus (the now-stable validation fixture). Compare extraction
   recall, hallucination rate, and runtime.
3. Adopt only if the candidate strictly dominates on at least two of the
   three axes. Otherwise document the comparison in `LESSONS.md` so future
   visits don't re-evaluate the same candidate.

**When to revisit:**
- After the 3-session agentic rollout gate (Phase 4 in
  `docs/phase_agentic_extraction_integration.md`).
- When prompt-engineering changes start producing regressions instead of
  improvements (signal that we've hit the ceiling of in-house prompt work).
- When onboarding a contributor unfamiliar with R / targets — borrowed
  agents may be more discoverable than bespoke prompts.

---

## Consolidate the two Shiny apps into a single `app.R`

**Status:** DONE (2026-05-23). `shiny/review_queue/app.R` is the canonical app (port 7474); `shiny/app.R` archived to `docs/archive/legacy_shiny_app.R`.

**Symptom:** There are two distinct Shiny apps:
- `shiny/app.R` (port 7474) — session-note review UI (handles both
  Doc-prep flow rows and `s02e34__agentic` agentic session rows).
- `shiny/review_queue/app.R` (port 7475) — Phase 4.5 entity-note review UI
  with sidebar grouping, regenerate modal, Merge action, diff view.

The reviewer has to launch two processes, watch two ports, and remember
which UI handles which `note_type`. After 1.5 sessions of reviewing s02e34,
the friction is noticeable.

**Goal:** One `app.R` that auto-routes each queue row to the right renderer
based on `note_type`. Sidebar groups by note type (Sessions / NPCs /
Locations / Factions) so the reviewer sees the full queue in one pane.

**Approach sketch:**
1. Promote `shiny/review_queue/` into the canonical app. Its existing
   sidebar.R already groups by note type — extend the grouping to include
   a "Sessions" group at the top.
2. Add a session-note renderer that mirrors the original `shiny/app.R`
   layout (source-on-left / draft-on-right, agentic badge per Phase 3.1).
   `render_dispatch.R` already picks renderers by `note_type`; add a
   `render_session.R` case.
3. Move/repurpose useful pieces of `shiny/app.R` (e.g. the source-text
   read-only display, the iteration-history viewer for the critic-loop
   path) into the unified app.
4. Once parity is reached, archive `shiny/app.R` to
   `docs/archive/legacy_shiny_app.R` and remove its mention from `CLAUDE.md`.

**Why deferred to a small QoL:** Functionally both UIs work today. The
consolidation is reviewer-experience work, not pipeline correctness work.
Worth doing before broader agentic rollout (paths 1 + 3 both feed sessions;
two UIs for one note type is the worst combination).

**When to implement:**
- Before the 3-session agentic gate, ideally as part of Phase 3 (Shiny
  observability) in `docs/phase_agentic_extraction_integration.md`.
- Co-located with Phase 3.1 (agentic-flow badge in the session-note card) —
  same file edits, one PR.

---

## Reframe pipeline as a dbt-style staged transform DAG

**Status:** Lower priority than the post-rollout cleanup branch.
Captured 2026-05-12. Reaffirmed 2026-05-12: cleanup work (Shiny
consolidation + general tech-debt sweep) lands first; this dbt-style
reframe sits behind it.

**Idea:** Once the agentic methodology is shipped and stable (3/3 gate
cleared, Phase 4.2 decided), revisit reframing the pipeline as a dbt-style
staged transform DAG:

```
stg_vtt (raw lines)
  → stg_speaker_segments
  → int_entity_mentions
  → int_entity_passages
  → int_entity_interactions
  → mart_entity_profile
  → mart_session_recap
```

LLM only consumes `mart_*` rows; per-entity-type prompts are driven by
per-type mart shapes — NPC = description + dialogue, location = setting +
events, faction = membership + conflict. This directly attacks the
"one generic prompt for all entity types" root of the entity-chain
regression (`## TODO: Entity-chain generator produces ungrounded templates (P0)`
above).

**Wins:**
- Per-stage tests — every transform has a documented input/output shape
  and can be unit-tested without invoking Ollama.
- Column-type contracts as data-quality gates — a row that fails the
  contract never reaches an LLM.
- Incremental materialization — re-run only downstream of changed VTTs;
  no need for the targets-style "everything is cached by content hash"
  approach for the deterministic-transform half of the pipeline.
- Lineage — given a bad recap, walk back to the row in `int_*` that
  poisoned it.

**Gating:**
- (a) 3/3 agentic session-note gate must have shipped.
- (b) Phase 4.2 decision (does agentic subsume the entity-note critic
  loop?) must be made first. If Phase 4.2 lands and the critic loop dies,
  much of this DAG already exists in `R/agentic_*.R` — the question
  becomes "port for lineage / test wins" rather than "rebuild."
- (c) The post-rollout cleanup branch must have shipped (Shiny
  consolidation + dead-code sweep). Do not stack a new SQL/dbt runtime
  on top of pipeline tech debt that we already know we want to retire.

**Risk:** Introduces SQL + a dbt runtime alongside R + targets. New
dependency, new failure mode. Most of the lift is reframing existing
logic, not adding new capability — so the value proposition is
maintainability and test coverage, not new features. Worth a design pass
before committing to the new runtime; an R-only "frame-as-DAG" rewrite
(e.g., using `dplyr` + a thin contract layer) may capture most of the
wins without the dependency cost.
