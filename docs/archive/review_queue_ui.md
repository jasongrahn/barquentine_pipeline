# Review Queue UI — Design & Patch Reference

App: `shiny/review_queue/` (Barquentine pipeline)

This document consolidates the v1 design brief, v1.1 addendum, and v1.1 patch notes.

---

## Core problem

User does not know what they are validating. Three artifacts on screen (source, draft, critic), no roles, three ambiguous buttons, no preview of vault outcome. Empty drafts shown as if reviewable.

**Fix:** every pane has a clear role. Every action has a clear consequence. Failed generations have a distinct state. User can correct facts once and regenerate, not hand-edit every note.

## Reviewer mental model (build the UI around this)

1. **Identity** — what entity is this, what type, what does it alias?
2. **Evidence** — which VTT sentences mention it?
3. **Draft** — proposed wiki note, rendered as it will appear in Obsidian
4. **Vault state** — does this entity exist already? what changes if I approve?
5. **Issues** — what did the critic flag, with click-through to source and draft

---

## v1 — Must-fix items

### 1. Filter garbage entity names at ingestion

File: `R/source_c.R`, `aggregate_entity_passages()`

Drop entities where name matches:
- `missing`, `not_present`, `not_mentioned`, `implied_but`, `unclear`, `error_from`, `unknown_name`
- Names longer than 50 chars (LLM emitted explanation as name)
- Names with no alphabetic characters

Log dropped names. Do not enqueue. These are LLM refusals, not entities.

### 2. Sidebar restructure

Replace flat alphabetical list with grouped sections:
- **Failed Generation** (`status = "generation_failed"`) — surfaced first, red icon
- **NPCs** — pending notes for `note_type == "npc"`, with critic-flag icon if applicable
- **Locations** — same, `note_type == "location"`
- **Factions** — same
- **Episodes** — pending session notes (existing Phase 2 path)

Each entry shows:
- entity name
- status icon: NEW (no existing vault file) or SUPPLEMENT (vault file exists)
- critic flag icon if `verdict == "flagged"`
- chunk count badge (e.g. "×4")

Use `shiny::tagList()` with collapsible `details` blocks per section. Use Lucide icons via `htmltools::HTML()` or unicode (▲ ⚠ ● ○).

Add at top:
- progress meter: "12 of 47 remaining"
- search box (filter by entity name)

### 3. Markdown preview pane (replace raw textarea as default)

Right pane changes from `textAreaInput()` to a tab pair:
- **Preview** (default) — `htmlOutput()` rendering markdown via `commonmark::markdown_html()`
- **Edit** — `textAreaInput()` for direct markdown edit

Toggle via `tabsetPanel()`. Default to Preview.

Above the tabs, label clearly: **"Will be written to: `vault/npcs/the_flotilla.md`"** — show the actual path. Update label live based on current entity.

### 4. Source text — highlight + sentence-window default

Center pane:
- Default view: only sentence-window extracts (same passages the generator received). Toggle to "Full chunks" available.
- Wrap entity name and known aliases in `<mark>` tags.
- Each passage prefixed with episode and chunk index: `[S2e34, chunk 7]`.

If sentence-window data is not yet stored on the queue row, fall back to highlighted full chunks. Plan for sentence-windows once Phase 3 fix lands.

### 5. Critic findings — structured rendering

Critic returns JSON. Render as structured cards, not flat bullet list:

```
┌─ Issue ─────────────────────────────────────┐
│ Draft incorrectly states player is 'Basil'  │
│                                             │
│ Evidence:                                   │
│   "The Captain: I think I might know..."    │
│   [click to highlight in source]            │
└─────────────────────────────────────────────┘
```

Each issue card is clickable. On click:
- scroll source pane to first matching evidence quote, flash highlight
- scroll draft pane to first matching draft text, flash highlight
- if draft is empty, show "no draft to highlight" inline

Use `shiny::observeEvent()` + JS via `shinyjs::runjs()` for scroll/flash.

### 6. Action set replacement

Remove: Accept as Written / Accept with Edits / Reject

Add (left-to-right, primary to destructive):

| Button | Action | Vault outcome |
|---|---|---|
| **Approve** | Write current draft to vault path | File created or supplemented |
| **Edit & Approve** | Switch to Edit tab; on save, write edited markdown | File created with edits |
| **Regenerate** | Open feedback modal; replace draft | New draft, status back to pending |
| **Merge into existing** | Autocomplete picker against vault entity list; converts row to supplement | Adds session-appearance link |
| **Reject** | Reason dropdown (garbage / duplicate / not-an-entity / out-of-scope); marks resolved | None |
| **Skip** | Marks row `snoozed`, advances to next | None |

Disable Approve and Edit & Approve when draft is empty. Show tooltip: "Draft is empty — Regenerate first."

### 7. Failed-generation state

When `status == "generation_failed"`:
- Sidebar entry shows red icon, "Generation failed"
- Main pane: "No draft was produced for this entity. Regenerate, merge, or reject."
- Only Regenerate / Merge / Reject / Skip available — no Approve

### 8. Regenerate-with-feedback modal

Modal contents:
- text area: "What should the LLM know? (optional but encouraged)"
- checkbox: "Save this as a campaign fact for all future generations"
- buttons: Cancel / Regenerate

On Regenerate:
- if checkbox ticked, append feedback to `config/campaign_facts.md`
- pass `prior_draft + critic_findings + user_feedback + campaign_facts` to `generate_entity_note()`
- replace draft, re-run critic, update row

`config/campaign_facts.md` is plain markdown, prepended to every entity-note generation prompt as a "Known facts about this campaign" section. Persistent across runs. User-curated. Initial seed: file is created on first regenerate-with-feedback (add a `# TODO` comment noting the long-term intent to migrate canonical file to the vault).

### 9. Merge-into-existing action

Modal contents:
- search/autocomplete: "Merge into which existing entity?" (options pulled from vault `npcs/`, `locations/`, `factions/`)
- preview block after target selected:
  ```
  This will:
  - append `- [[S2e37]]` to <chosen_entity>'s Session Appearances
  - register "<surface_form>" as an alias of <chosen_entity>
  - discard the standalone draft
  ```
- buttons: Cancel / Merge

On Merge:
- call `supplement_note()` on the chosen entity's existing file
- append spotted surface form to chosen entity's frontmatter `aliases:`
- mark current row `merged`, set `merged_into = "<chosen_entity>"`
- delete current draft from staging, advance to next row

Auto-alias registration means future runs spotting the same surface form resolve to the canonical entity at `aggregate_entity_passages()` time. If a registered alias is later regretted, user removes it from the canonical entity's frontmatter in Obsidian.

### 10. Vault diff for supplements

When current entity already exists in vault (`status == "supplement"`):

Center pane splits:
- left: existing vault file (read-only, rendered markdown)
- right: proposed supplement — show what `supplement_note()` would add, highlighted

Use `diffr` or simple side-by-side with addition lines flagged. For NEW entities, supplement-diff section is hidden.

---

## v1 — Should-fix (after must-fix lands)

- "What I changed" log — small persistent panel showing last 5 actions with undo on the most recent
- Critic confidence visualization — orange flag at 0.80, red at < 0.5, green tick when approved

## v1 — Nice-to-have

- Export current batch decisions as audit log
- "Similar entities" suggestion — fuzzy match new entity name against vault

---

## v1 — Files

### Create / modify

| File | Change |
|---|---|
| `shiny/review_queue/app.R` | Restructure UI tabs, panels, actions |
| `shiny/review_queue/server.R` | New observers for regenerate, merge, action set |
| `shiny/review_queue/R/sidebar.R` | NEW — grouped sidebar rendering logic |
| `shiny/review_queue/R/critic_card.R` | NEW — structured finding rendering |
| `shiny/review_queue/R/diff_view.R` | NEW — supplement diff rendering |
| `shiny/review_queue/R/regenerate.R` | NEW — regenerate-with-feedback flow |
| `shiny/review_queue/R/merge_action.R` | NEW — merge-into-existing flow |
| `R/source_c.R` | Garbage name filter in `aggregate_entity_passages()` |
| `config/campaign_facts.md` | NEW — created on first regenerate-with-feedback |
| `R/extract.R` | Prepend `campaign_facts.md` content to entity-note prompts |
| `R/router.R` | Status enum extended: `generation_failed`, `merged`, `snoozed`, `rejected_<reason>` |
| `review_queue/queue.csv` | Schema additions: `status_detail`, `merged_into`, `last_action_at` |

### Do not touch

- Phase 3 entity pipeline targets graph (independent change)
- `R/merge.R` `supplement_note()` (correct, reused by merge action)
- `R/critic.R` (correct; UI just renders its output better)

## v1 — Done when

- Garbage entity names never appear in sidebar
- Reviewer can approve/edit/regen/merge/reject/skip on every entity in the queue
- No accept option on empty drafts; clear regenerate path
- Markdown renders as preview by default; raw edit available
- Source text shows highlighted entity mentions in sentence-window context
- Critic findings click through to source and draft
- Supplements show diff against vault
- One full pass through ~15 entities can be done in under 20 minutes

## v1 — Decisions confirmed with Jg

- **`config/campaign_facts.md` location:** repo for v1. Long-term intent is for the canonical file to live in the vault and be read into the repo at run time, but defer the vault-as-source migration until v2. Note the future direction in a `# TODO` comment at the top of the seeded file.
- **Merge action — alias auto-registration:** auto-register, with the registered alias shown explicitly in the merge confirmation modal. Skipping auto-registration means the same surface form gets re-spotted every session and the user re-merges it forever. Showing the registration in the modal preserves user veto — they can cancel if the alias is wrong.

---

## v1.1 — Additions

*Trigger: three screenshots (S2e41 session, the_flotilla location, geronimo NPC) revealed three distinct review modes being squeezed into one template.*

### 11. Mode-aware rendering by note_type

Queue rows have a `note_type` field (`session` | `npc` | `location` | `faction`). UI currently ignores it.

File: `shiny/review_queue/R/render_dispatch.R` (NEW)
- `render_review_pane(row)` switches on `row$note_type`, calls one of:
  - `render_session_review()`
  - `render_npc_review()`
  - `render_location_review()`
  - `render_faction_review()`
- Action set and critic card rendering are shared across modes (call from a partial).

#### Session recap mode (`render_session.R`)

Source pane splits left/right:
- left: Source B Google Doc recap (prose, what was generated)
- right: raw VTT for that episode (collapsible, default collapsed)

Draft pane: markdown preview + raw-edit toggle (per v1 item 3).

Critic findings link to (a) the draft line disputed and (b) the VTT line supporting the dispute. Two scrolls per click. The session-note critic compares draft against VTT, not against Google Doc.

Vault path label: `vault/sessions/S2e41.md`.

**Mode-specific:** session recaps do NOT use the merge action. Hide Merge for session rows.

#### NPC mode (`render_npc.R`)

Source pane: sentence-windowed VTT excerpts around name mentions. Episode + chunk index prefix each excerpt. Entity name and known aliases highlighted.

Draft pane: structured card (frontmatter shown as labeled fields, body as markdown):
- Name (editable inline — see item 13)
- Aliases (chip list)
- Role / Faction
- First seen
- Disposition to party
- Summary (markdown body)
- Session appearances (auto, derived)

Toggle to "Raw markdown" view for direct edit. Vault path label: `vault/npcs/{slug}.md`.

#### Location mode (`render_location.R`)

Source pane: sentence-windowed VTT excerpts, location name and known aliases highlighted.

Draft pane: structured card:
- Name (editable inline)
- Type (ship / region / chamber / planet / etc.)
- Region / parent location
- Controlling faction (linked)
- Description (markdown)
- Key events (auto-populated list of episode links)

**Mode-specific check:** locations frequently overlap with factions in this campaign (the_flotilla is both place and organization). Render a "This might also be a faction" hint when the location's controlling-faction field matches its own name.

Vault path label: `vault/locations/{slug}.md`.

#### Faction mode (`render_faction.R`)

Source pane: sentence-windowed VTT excerpts around faction mentions.

Draft pane: structured card:
- Name (editable inline)
- Aliases
- Goals (markdown list)
- Members (linked NPCs)
- Structure / hierarchy
- Disposition to party
- Summary (markdown)

**Mode-specific check:** scan draft for `[unclear]`, `[unknown]`, `[needs context]` placeholders. If present, show prominent banner: "Draft contains unresolved placeholders — Regenerate recommended."

Vault path label: `vault/factions/{slug}.md`.

### 12. Rejected-verdict state (critic confidence ≥ 0.95 OR verdict = "rejected")

When the critic returns a high-confidence rejection:
- Sidebar: red-bordered icon, label "Critic rejected"
- Main pane: top banner reads "The critic rejected this draft with high confidence. Recommended actions: Regenerate or Reject."
- **Hide Approve and Edit & Approve buttons entirely** — do not just disable.
- Available actions: Regenerate / Merge / Reject / Skip only.

The flagged state (0.5 ≤ confidence < 0.95) keeps Approve and Edit & Approve available — flagged drafts are often salvageable.

Thresholds in `config.R`:
```r
CRITIC_FLAG_THRESHOLD   <- 0.5
CRITIC_REJECT_THRESHOLD <- 0.95
```

### 13. Inline rename on Approve (slug + display name)

For all entity modes (NPC, location, faction), Approve opens a confirmation modal:
- "Display name" — editable, default = current name from frontmatter
- "Slug (filename)" — editable, default = current slug, auto-derived from display name as user types (with manual override toggle)
- Shows final vault path: `vault/npcs/the_giff.md`
- Validates: slug must match `^[a-z0-9_-]+$`, no collision with existing vault file unless mode is supplement
- Buttons: Cancel / Confirm & Write

**Why:** the_gif screenshot showed a faction whose canonical slug should be `the_giff` but came out as `the_gif`. Without inline rename, reviewer either accepts wrong slug or loses the draft.

For session-recap mode, slug is auto-generated from episode_id and not editable. Skip the rename modal for sessions.

### 14. One-time queue cleanup for residual garbage rows

Not a UI feature. Operations task before v1.1 ships.

Existing `review_queue/queue.csv` contains rows from before the ingestion-stage filter was added (`attor_missing_name_not_present_in_the_text_but_at...`, etc.).

Script: `scripts/cleanup_queue_residue.R` (new, one-shot, not part of pipeline)
- Read `queue.csv`
- Drop rows where entity name matches the refusal-phrase blacklist
- Drop rows whose draft files are missing or empty (orphans)
- Write back, preserve resolved rows
- Report counts

Run once. Future runs are protected by the ingestion-stage filter.

---

## v1.1 — Should-fix additions

- **Per-critic-finding actions.** Each finding card gets two inline buttons: "Dismiss" (mark not-an-issue, persists with queue row) and "Address via Regenerate" (opens regenerate modal pre-populated with this finding).
- **`[unclear]` placeholder scanner across all modes.** Surface a banner on any draft containing bracket-placeholder patterns — not just factions.

## v1.1 — Files (additions to v1 list)

| File | Change |
|---|---|
| `shiny/review_queue/R/render_dispatch.R` | NEW — switches on note_type |
| `shiny/review_queue/R/render_session.R` | NEW — session recap mode |
| `shiny/review_queue/R/render_npc.R` | NEW — NPC mode |
| `shiny/review_queue/R/render_location.R` | NEW — location mode |
| `shiny/review_queue/R/render_faction.R` | NEW — faction mode |
| `shiny/review_queue/R/rejected_state.R` | NEW — handles ≥0.95 confidence rejection layout |
| `shiny/review_queue/R/rename_modal.R` | NEW — inline rename on Approve |
| `shiny/review_queue/R/placeholder_scan.R` | NEW — detects `[unclear]` / `[unknown]` / `[needs_X]` |
| `shiny/review_queue/R/finding_actions.R` | NEW — Dismiss / Address-via-Regenerate per finding |
| `scripts/cleanup_queue_residue.R` | NEW — one-shot bulk cleanup |
| `config.R` | Add `CRITIC_FLAG_THRESHOLD`, `CRITIC_REJECT_THRESHOLD` |
| `R/router.R` | Status enum extended: `critic_rejected` distinct from `flagged` |
| `review_queue/queue.csv` | Schema additions: `dismissed_findings` (JSON array), `slug_override` (string, nullable) |

## v1.1 — Done when

- Reviewer sees a different layout for sessions vs NPCs vs locations vs factions
- Rejected (≥0.95) drafts cannot be accepted with one click
- Approving an entity prompts for slug confirmation / rename before commit
- Existing residual garbage rows are gone from the queue (one-shot cleanup ran)
- `[unclear]` placeholders surface a banner before approval is possible

## v1.1 — Scope creep shipped in `pipeline_phase_4_5`

### Queue-to-queue merge

The Merge modal now shows a "Pending queue items" optgroup (same `note_type`, excluding the current item) above vault entities. Selecting a queue target combines the absorbed item's source passages into the surviving item's `source_text`, marks the absorbed item as `merged`, and leaves the surviving item pending with the fuller evidence set.

Files: `shiny/review_queue/R/merge_action.R` (`list_queue_items()`, updated `merge_modal_ui()`), `shiny/review_queue/R/server.R` (queue-path branch in `merge_confirm_btn`), `R/queue.R` (`merge_queue_items()`).

### Sidebar similarity hints

`.similar_ids()` in `sidebar.R` runs a prefix/suffix check against all pending section IDs. Matching entries show a small `⚠ Similar: the_admiral` line in orange below the entity name link.

### `played_by` field on PC notes (planned, not yet built)

Each PC vault note should carry a `played_by` YAML frontmatter field. Seed from a new `played_by` column in `config/protected_entities.csv`. Generator must treat the field as immutable — never infer or overwrite from transcript text.

Known roster: Room → John, Lumi → Chase, The Admiral → Jason, Basil/The Captain → David.

## v1.1 — Decisions pending Jg confirmation

- Mode-aware rendering creates four new render files. Accept this maintenance cost, or roll into a generic prose-mode + entity-mode split (two files)?
  - **Recommendation:** four files. Sessions and entities have genuinely different evidence panes.
- Rejected-state threshold of 0.95 — calibration is a guess.
  - **Recommendation:** ship at 0.95, adjust after first weekly run.

---

## v1.1 Patch Brief — Blocking issues and gaps

*Apply before any further feature work.*

### BLOCKING — `.confidence_badge` undefined

**Error:** `could not find function ".confidence_badge"`

**Fix:**
1. `grep -rn "confidence_badge" shiny/review_queue/` — find where it's called.
2. Define it. Expected signature:
   ```r
   .confidence_badge <- function(score, verdict) {
     label <- switch(verdict,
       "rejected" = sprintf("Critic: rejected (%.2f)", score),
       "flagged"  = sprintf("Critic: flagged (%.2f)", score),
       sprintf("Critic: approved (%.2f)", score)
     )
     color <- switch(verdict,
       "rejected" = "#dc3545",
       "flagged"  = "#e67e22",
       "#28a745"
     )
     htmltools::tags$span(label, style = sprintf("color: %s; font-weight: bold;", color))
   }
   ```
3. Place in `render_dispatch.R` or a shared `utils.R`. Ensure it's sourced at app startup.
4. Restart app. Confirm main pane renders.

**Do this first.** Nothing else matters until the main pane works.

### BLOCKING — Main pane renders nothing

After fixing `.confidence_badge`, verify:
1. `render_review_pane()` in `render_dispatch.R` is called from `server.R` when a sidebar item is clicked.
2. The `observeEvent()` for sidebar clicks passes the correct queue row to the dispatcher.
3. Each `render_*_review()` function returns valid Shiny UI (not NULL, not an error).

Test: click one entity from each section (Failed, NPC, Location). All three must render source + draft + critic + actions.

If the dispatcher works but individual renderers fail, **fall back to a single generic renderer** for all types until per-type renderers are debugged. A broken dispatcher ships worse than a working generic view.

### GAP — Protected entities exclusion list

Problem: player characters (Room, The Captain, Lumi) and player real names (John, Chase, David, Jason) appear as NPC entity candidates. OOC table-talk references (Dilbert, TED 2) also leak through.

File: `config/protected_entities.csv`
```csv
entity_name,entity_type,played_by,exclude_from_spotting
Room,pc,John,true
The Captain,pc,David,true
Basil,pc_alias,David,true
Captain,pc_alias,David,true
Lumi,pc,Chase,true
The Admiral,npc,,false
John,player,,true
Chase,player,,true
David,player,,true
Jason,player,,true
```

`R/source_c.R`, `aggregate_entity_passages()` — after cross-episode merge, before frequency filter:
```r
protected <- read_csv("config/protected_entities.csv") |>
  filter(exclude_from_spotting) |>
  pull(entity_name) |>
  tolower()
entities <- entities |>
  filter(!tolower(entity_name) %in% protected)
```

Use word-boundary regex for fuzzy match: `paste0("\\b", protected, "\\b")` — catches "Room's" and "captain_unnamed" without catching unrelated "captain" references.

### GAP — Similarity hints not showing

Debug:
1. Check `.similar_ids()` — is it prefix/suffix matching only? "Captain" and "The Captain" share a suffix but may not meet the minimum overlap ratio.
2. Test: call `.similar_ids("captain", c("the_captain", "basil", "admiral"))` manually. Expected: returns `"the_captain"`.
3. If function works but UI doesn't show hints, check the sidebar renderer calls and renders the output.
4. If function doesn't match these, lower the threshold or switch to `stringdist::stringdist()` with Jaro-Winkler (handles prefix additions like "The ").

### OBSERVATION — Entity spotter noise (not blocking)

Even after protected-entity exclusion and frequency filter, the sidebar may still contain Dilbert (×6), TED 2 (×4), Robert (×5), Frank (×5) — unclear if campaign NPCs or OOC references.

Reviewer uses the Reject button with reason "not-an-entity." Consider auto-adding rejected entity names to `config/entity_blacklist.csv` that the spotter checks on future runs — same pattern as auto-alias from merge. Prompt-engineering work; defer until UI is stable.

### Patch priority order

1. Fix `.confidence_badge` — unblocks everything
2. Verify main pane renders for all three entity types
3. If main pane still broken, fall back to generic renderer — DO NOT ship a broken dispatcher
4. Add `config/protected_entities.csv` + exclusion filter in `aggregate_entity_passages()`
5. Debug similarity hints
6. Entity-spotter noise is a reviewer workflow issue, not a code fix — defer

### Patch — Done when

- Clicking any sidebar entity renders source + draft + critic + action buttons (no error)
- Player names (John, Chase, David, Jason) never appear in entity queue
- PC names (Room, The Captain/Basil/Captain, Lumi) never appear in entity queue
- "Captain" and "The Captain" show similarity hint if both are pending
