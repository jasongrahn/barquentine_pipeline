# Barquentine Wiki Pipeline — Design Document
*Version 4.3 — Complete*

## Changelog
- v4.3: Local-only model architecture — `gemma4:latest` promoted to generator, `qwen3.5:9b` to critic, `llama3.1:8b` retired; `CRITIC_AUTO_APPROVE_THRESHOLD` set to `Inf` (all notes go through human review queue); Claude escalation paths removed from `R/critic.R` and `R/router.R`; see `docs/architecture_llm_evaluation.md` for the full analysis behind this decision
- v4.2: HTML export fix documented; plain-text truncation finding recorded; `overwrite = TRUE` decision noted in _targets.R
- v4.1: Basil corrected to PC; `aliases.json` replaced by vault-derived registry; `display_as` frontmatter field introduced

---

## ☑ To-Do List (Complete in Order)

- [x] **Create Obsidian vault folder** — `/Users/jasongrahn/R-projects/barquentine_wiki/BarquentineWiki/` ✓
- [x] **Init vault as git repo** — `barquentine_wiki` repo created, pulled, aligned with Positron ✓
- [x] **Create `barquentine_pipeline` GitHub repo** — cloned to `/Users/jasongrahn/R-projects/barquentine_pipeline`; on branch `pipeline_phase_1` ✓
- [x] **Install Obsidian Git plugin** — installed ✓
- [x] **Confirm Qwen model string** — `qwen3.5:9b` confirmed ✓
- [x] **Confirm VTT cutover episode** — S2e34 ✓
- [x] **Confirm VTT path on NAS** — `/Volumes/share/videos/` directly, no subdirectory ✓
- [x] **Mount NAS** — `/Volumes/share/` via `smb://LS220D43E.local/share` ✓
- [x] **Authorize Google Drive in R** — `drive_auth()` run; token cached ✓
- [x] **Install R packages** — installed ✓
- [x] **Populate `config.R`** — complete; download and place in `/Users/jasongrahn/R-projects/barquentine_pipeline/` ✓

### Repo Structure (two repos — confirmed)
Pipeline code and vault are intentionally separated. This mirrors professional practice: generated artifacts (the wiki) live in their own repo with a clean, auto-committed session history; source code (the pipeline) lives separately with human-authored commit messages. Two Positron project windows, one for each repo.

```
barquentine_wiki/               ← GitHub repo (vault only)
└── BarquentineWiki/            ← Obsidian vault
    ├── sessions/
    ├── pcs/
    ├── npcs/
    ├── locations/
    └── review/

barquentine_pipeline/           ← GitHub repo (all R code) ← create next
├── _targets.R
├── config.R
├── config/
│   └── source_a_registry.csv
└── R/
```

---

## 1. Project Goal

Build an automated R-based pipeline that extracts structured knowledge from existing Barquentine campaign materials and writes it as interlinked Obsidian markdown notes — producing a navigable GM reference wiki covering NPCs, locations, factions, sessions, items, and mechanics.

The pipeline runs after each session. It appends new information to existing notes and flags contradictions for DM review. It never overwrites without review, and never fabricates — all output is traceable to a source line.

### Learning Objective

This project is also explicitly a learning exercise in routing work intelligently between local and cloud AI models. The same architectural pattern — cheap local model for bulk entity spotting, cloud model for quality structured output — applies directly to analytics work at scale:

| This project | Analytics equivalent |
|---|---|
| VTT transcripts | dbt model SQL + YAML files, PR descriptions |
| NPCs, locations, factions | dbt models, sources, metrics, owners |
| Obsidian wiki | Internal data catalog / knowledge base |
| Ollama/Qwen entity spotting | Local model for column/model name extraction |
| Claude structured note writing | Cloud model for documentation generation |
| `review_required` flag | Stale doc detection, breaking change alerts |

Tools involved here (Positron, Ollama, Claude API, `targets`) map cleanly onto what you're already navigating with Positron Assistant, Snowflake Cortex, and GitHub Copilot across your dbt and analytics repos.

---

## 2. Source Inventory

### Source A — Individual Google Drive Prep Docs
- **Coverage:** Early sessions (~S1e0 through ~S1e15), scattered
- **Format:** Unstructured GM prep notes. Mix of read-aloud prose, NPC bullets, encounter DCs, table-talk notes. No consistent schema.
- **Access:** `googledrive` R package, fetching by doc ID extracted from `.gdoc` shortcut files
- **Fidelity:** Low — GM intent, not ground truth. Default to `unknown` for any detail not explicitly stated.

### Source B — Multi-Tab Google Doc
- **Doc ID:** `1m5xXbEsPBFdTZAUoUAgj6a14I7aF8LcszCmX-r1mBbs`
- **Coverage:** S2e14 through current (updated each session)
- **Format:** Drive API flattens all tabs into one document. Tab boundaries are `#`-level headings (e.g., `# Barquentine S2e14`). Content ranges from sparse prep stubs to polished "Previously on Barquentine" narrative intros (S2e33+).
- **Access:** `googledrive` R package (confirmed working via Drive API)
- **Fidelity:** Mixed. "Previously on" intros → near-VTT quality. Raw prep sections → low-fidelity GM intent.
- **Known issue:** Some sections (e.g., S2e26) are near-empty stubs. Extraction produces minimal stubs without fabricating detail.

### Source C — VTT Transcript Files
- **Coverage:** S2e33 or S2e34 onward (⬜ confirm by checking NAS for earliest file)
- **Format:** WebVTT — timestamped, speaker-attributed lines
- **Access:** NAS mounted at `/Volumes/share/videos/` via `smb://LS220D43E.local/share`
- **Fidelity:** Highest — ground truth of what was said at the table
- **Known issue:** Files are large. Full-file single-pass extraction is inadvisable. See Section 6 for chunking strategy.

### Source Precedence
```
VTT transcript > "Previously on" intro > prep notes
```
Conflicts between sources are flagged for DM review rather than silently resolved.

---

## 3. Output: Obsidian Vault Structure

```
barquentine-wiki/               ← git repo
├── sessions/
│   └── S2e33_Something_In_The_Dark.md
├── pcs/
│   └── Basil.md
├── npcs/
│   └── Attorrnash.md
├── locations/
│   └── The_Giff_Flotilla.md
├── factions/
│   └── Giff_Military.md
├── items/
│   └── Sphere_of_Annihilation.md
├── mechanics/
│   └── Slaad_Infection.md
├── review/
│   └── review_log.md           ← DM attention items; updated each run
└── _index.md
```

> **First step before any pipeline work:** create this folder, open it in Obsidian as a vault, `git init`, and push to a new GitHub repo (`barquentine-wiki`). The pipeline writes into this folder — it must exist first.

### Note Templates

#### Session Note
```markdown
---
tags: [session]
episode: S2e33
title: "Something In The Dark"
date_played:
source: vtt | recap_intro | prep_notes
review_required: false
---

## Summary

## Key Events
-

## NPCs Present
- [[Basil|the Captain]]

## Locations
-

## Items / Artifacts
-

## Open Threads
-

## GM Notes
```

#### PC Note
```markdown
---
tags: [pc]
name: Basil
aliases: [Basil, the Captain, Nameless Captain]
display_as: the Captain
status: alive | dead | unknown
first_seen:
review_required: false
---

## Overview

## Appearance & Vibe

## Motivation

## Relationships

## Quotes
>

## Session Appearances
-

## GM Notes
```

#### NPC Note
```markdown
---
tags: [npc]
name: Attorrnash
aliases: []
status: alive | dead | unknown
faction:
first_seen:
review_required: false
---

## Overview

## Appearance & Vibe

## Motivation

## Relationship to Party

## Quotes
>

## Session Appearances
-

## GM Notes
```

#### Location Note
```markdown
---
tags: [location]
type: unknown
region: unknown
review_required: false
---

## Description

## Notable Features

## NPCs Here
-

## Sessions
-
```

#### Faction Note
```markdown
---
tags: [faction]
disposition_to_party: unknown
review_required: false
---

## Overview

## Key Members
-

## Goals

## Sessions
-
```

#### Item / Artifact Note
```markdown
---
tags: [item, artifact]
status: unknown
review_required: false
---

## Description

## Properties / Mechanics

## History

## Sessions
-
```

---

## 4. Name Normalization & Alias Registry

### The Captain ("Basil")
The Captain's original name (Basil) is canonical for his PC note filename and title. In all *other* notes, the pipeline outputs the Obsidian display-alias syntax: `[[Basil|the Captain]]` — renders as "the Captain" in reading view, resolves to the Basil note. The `display_as: the Captain` field in his PC note frontmatter drives this automatically.

### Alias Registry (vault-derived)
The alias registry is built dynamically at pipeline runtime by scanning all notes in `pcs/` and `npcs/` and extracting their frontmatter `aliases:` fields. This means `aliases.json` does not exist — the vault itself is the single source of truth. When a character's name changes, the DM updates the note's `aliases:` frontmatter field in Obsidian and the next pipeline run picks it up automatically.

The `display_as:` field in a note's frontmatter provides the wikilink display text. When present, `[[slug|display_as]]` syntax is used automatically. When absent, `[[slug]]` is used.

**Example: Basil's PC note frontmatter:**
```yaml
---
tags: [pc]
name: Basil
aliases: [Basil, the Captain, Nameless Captain]
display_as: the Captain
status: alive
first_seen: S1e00
review_required: false
---
```

When the pipeline encounters an unresolvable name, it logs it to `review/review_log.md` and skips wikilink creation for that mention. The DM adds an `aliases:` entry to the relevant note in Obsidian and reruns.

---

## 5. Toolchain Architecture

```
┌──────────────────────────────────────────────────────────┐
│            targets pipeline (R, runs in Positron)        │
│            orchestrates all steps; incremental runs      │
└──────────┬───────────────────────┬───────────────────────┘
           │                       │
    ┌──────▼──────┐       ┌────────▼───────────────────┐
    │ googledrive  │       │  /Volumes/share/videos/ (NAS SMB) │
    │ R package    │       │  VTT files, local read     │
    └──────┬──────┘       └────────┬───────────────────┘
           │                       │
    ┌──────▼───────────────────────▼─────────────────────┐
    │                  GENERATION LAYER                  │
    │  Ollama / gemma4:latest (local, $0)                │
    │    → session + entity note drafting (all sources)  │
    │    → entity spotting on VTT chunks                 │
    └──────────────────────────┬─────────────────────────┘
                               │
    ┌──────────────────────────▼─────────────────────────┐
    │                   CRITIC LAYER                     │
    │  Ollama / qwen3.5:9b (local, JSON schema enforced) │
    │    → fact-checks draft vs source                   │
    │    → all verdicts → review queue (auto-approve off)│
    └──────────────────────────┬─────────────────────────┘
                               │
    ┌──────────────────────────▼─────────────────────────┐
    │               SHINY REVIEW QUEUE                   │
    │  Human reviews every note; critic issues inline    │
    │  Accept / Accept with Edits / Reject               │
    │  Decisions captured as SFT / DPO training pairs   │
    └──────────────────────────┬─────────────────────────┘
                               │
    ┌──────────────────────────▼─────────────────────────┐
    │                   OUTPUT LAYER                     │
    │  Dry-run: writes to /tmp/barquentine-preview/      │
    │  Live: writes to Obsidian vault                    │
    │  gert::git_commit() after each successful run      │
    └────────────────────────────────────────────────────┘
```

### Why `targets`?
`targets` is R's pipeline orchestration package (tidyverse-adjacent). It tracks which steps have already run and only re-executes what's changed — so running the pipeline after session 42 doesn't reprocess sessions 1–41. This is the right tool for an incremental, session-by-session workflow and eliminates the need to write that bookkeeping logic manually.

### Project Structure

```
barquentine-pipeline/           ← git repo (separate from vault)
├── _targets.R                  # pipeline definition (targets entry point)
├── config.R                    # vault path, NAS mount, model names, doc IDs
├── config/
│   └── source_a_registry.csv   # static registry of Source A doc IDs
├── R/
│   ├── gdrive.R                # Google Drive fetch functions
│   ├── source_a.R              # individual prep doc processing
│   ├── source_b.R              # multi-tab doc parsing
│   ├── source_c.R              # VTT chunking + cleaning
│   ├── ollama.R                # Ollama/Qwen entity spotting
│   ├── claude.R                # Claude API note generation
│   ├── extract.R               # extraction prompt templates
│   ├── merge.R                 # append-mode + conflict detection
│   ├── wikilinks.R             # vault-derived alias registry → [[wikilinks]]
│   ├── writer.R                # writes .md files; dry-run vs live
│   ├── review.R                # review_log.md management
│   └── git_commit.R            # vault git commit after run
└── review/
    └── review_log.md
```

---

## 6. Ollama + Qwen Integration

### What This Is
Ollama runs large language models locally — no API key, no cost, no data leaving the machine. The pipeline calls it via its local HTTP API for entity spotting on VTT files. This is the cheap, fast pass that narrows scope before the more expensive Claude API call does the quality structured writing.

This is the core pattern worth internalizing for analytics work: route volume through a local model, route quality through a cloud model.

### Ollama API Call (R / httr2)

```r
library(httr2)
library(jsonlite)
library(purrr)

spot_entities <- function(chunk, model = OLLAMA_MODEL) {
  request(paste0(OLLAMA_BASE_URL, "/api/chat")) |>
    req_body_json(list(
      model  = model,
      stream = FALSE,
      format = "json",
      messages = list(
        list(
          role    = "system",
          content = paste(
            "You extract named entities from tabletop RPG session transcripts.",
            "Return only valid JSON. No explanation. No markdown fences."
          )
        ),
        list(
          role    = "user",
          content = paste0(
            'Extract all named NPCs, locations, items, and factions from the text below. ',
            'Return exactly this structure: ',
            '{"npcs": [], "locations": [], "items": [], "factions": []}\n\n',
            chunk
          )
        )
      )
    )) |>
    req_timeout(120) |>
    req_perform() |>
    resp_body_json() |>
    pluck("message", "content") |>
    fromJSON()
}
```

### VTT Chunking Strategy

```r
library(stringr)

chunk_vtt <- function(vtt_text, chunk_words = 1500, overlap_words = 150) {
  # Strip VTT timestamps, keep speaker lines only
  lines <- vtt_text |>
    str_split("\n") |>
    pluck(1) |>
    str_subset("^\\d{2}:\\d{2}", negate = TRUE) |>  # remove timestamps
    str_subset("^WEBVTT", negate = TRUE) |>          # remove header
    str_squish() |>
    discard(\(x) x == "")

  words   <- str_split(paste(lines, collapse = " "), " ")[[1]]
  starts  <- seq(1, length(words), by = chunk_words - overlap_words)

  map(starts, \(s) {
    end <- min(s + chunk_words - 1, length(words))
    paste(words[s:end], collapse = " ")
  })
}
```

### Model Assignments (current)
- **Generator:** `gemma4:latest` (9.6 GB) — all note drafting
- **Critic:** `qwen3.5:9b` (6.6 GB) — fact-checking with JSON schema enforcement

### Full Local Model Inventory

| Model | Size | Role in pipeline |
|---|---|---|
| `gemma4:latest` | 9.6 GB | **Generator** — session + entity note drafting (`OLLAMA_MODEL`) |
| `qwen3.5:9b` | 6.6 GB | **Critic** — fact-checking, JSON schema enforced (`OLLAMA_CRITIC_MODEL`) |
| `llama3.1:8b` | 4.9 GB | **Retired** — was critic; superseded by qwen3.5:9b (stronger reasoning) |
| `qwen2.5-coder:1.5b-base` | 986 MB | Not used — code-focused, too small for extraction |
| `nomic-embed-text:latest` | 274 MB | **Future** — semantic search across the vault (see below) |

### Future Capability: Semantic Search (`nomic-embed-text`)
`nomic-embed-text` is an embedding model — it converts text into numerical vectors that represent semantic meaning rather than exact words. Once the vault is populated, this enables queries like "find all notes related to the tribunal arc" or "what sessions involve the Captain's identity" without requiring exact keyword matches. It runs entirely locally at zero cost and integrates with Obsidian via the Smart Connections community plugin. Not needed for Phase 1–3, but worth knowing it's already available.

### Failure Handling

```r
spot_entities_safe <- function(chunk, model = OLLAMA_MODEL) {
  result <- tryCatch(
    spot_entities(chunk, model),
    error = function(e) {
      message("Ollama failed: ", conditionMessage(e), " — falling back to Claude")
      NULL
    }
  )

  if (is.null(result)) {
    # Fall back to Claude API for this chunk (more expensive but guaranteed)
    claude_spot_entities(chunk)
  } else {
    result
  }
}
```

If Ollama is not running when the pipeline starts, it fails fast with a clear message rather than silently routing everything through Claude.

---

## 7. Google Drive Access (R)

The `googledrive` package handles OAuth without requiring manual Google Cloud Console setup for interactive use. One-time browser authorization; token cached in the OS keychain on macOS thereafter.

```r
library(googledrive)

# Run once interactively — opens browser for authorization
# Token is cached; subsequent runs are non-interactive
drive_auth()

# Fetch a Google Doc as HTML by doc ID
# NOTE: Must use type = "text/html", NOT "text/plain".
# Google Drive's plain-text export has a hard ~1000-line truncation limit that
# silently cuts off content mid-document. For a 40-tab episode notes doc this
# means everything after S2e17 is lost. HTML export is untruncated (~419 KB).
fetch_gdoc <- function(doc_id) {
  tmp <- tempfile(fileext = ".html")
  drive_download(
    as_id(doc_id),
    path      = tmp,
    type      = "text/html",
    overwrite = TRUE
  )
  readr::read_file(tmp)
}

# Parse Source B multi-tab Google Doc HTML into named list: {episode_id: text}
# Google Docs HTML export uses <p class="title"> tags (not h1 or "# " headings)
# as tab/section boundaries. Episode IDs are normalised to canonical S<n>e<n>
# form and non-episode sections (e.g. "Tab 7") are filtered out.
parse_source_b <- function(doc_text) {
  # (See R/source_b.R for full implementation)
  # Splits on <p class="title"> sentinel, extracts/normalises episode IDs,
  # strips heading tag from section content, strips remaining HTML, decodes
  # entities, deduplicates adjacent identical IDs.
}
```

For unattended pipeline runs (Phase 4 ongoing mode), the cached token handles re-authorization automatically unless it expires — in which case one interactive `drive_auth()` call refreshes it.

---

## 8. Claude API Integration (R)

```r
claude_generate_note <- function(prompt, system_prompt, model = CLAUDE_MODEL) {
  request("https://api.anthropic.com/v1/messages") |>
    req_headers(
      "x-api-key"         = Sys.getenv("ANTHROPIC_API_KEY"),
      "anthropic-version" = "2023-06-01",
      "content-type"      = "application/json"
    ) |>
    req_body_json(list(
      model      = model,
      max_tokens = 2000,
      system     = system_prompt,
      messages   = list(list(role = "user", content = prompt))
    )) |>
    req_retry(max_tries = 3, backoff = \(i) 10 * 3^(i - 1)) |>  # 10s, 30s, 90s
    req_perform() |>
    resp_body_json() |>
    pluck("content", 1, "text")
}
```

The `req_retry()` call handles rate limits and transient errors automatically with exponential backoff.

---

## 9. Pipeline Definition (`_targets.R`)

```r
library(targets)
library(tarchetypes)

tar_option_set(
  packages = c("httr2", "googledrive", "jsonlite", "readr",
               "stringr", "purrr", "fs", "gert", "glue")
)

source("config.R")
source("R/gdrive.R")
source("R/source_b.R")
source("R/source_c.R")
source("R/ollama.R")
source("R/claude.R")
source("R/merge.R")
source("R/writer.R")
source("R/review.R")
source("R/git_commit.R")

list(
  # Source B: multi-tab Google Doc (HTML export — see gdrive.R note above)
  tar_target(source_b_raw,      fetch_gdoc(EPISODE_NOTES_DOC_ID)),
  tar_target(source_b_sections, parse_source_b(source_b_raw)),
  tar_target(section_ids,       names(source_b_sections)),

  # Alias registry scanned from vault at pipeline start
  tar_target(alias_registry, build_alias_registry(VAULT_PATH)),

  # Session notes — one Claude call per Source B section (dynamic branching)
  tar_target(
    session_note_content,
    claude_generate_note(
      prompt        = session_prompt(section_ids, source_b_sections),
      system_prompt = "You are a precise structured data extractor for a D&D campaign wiki. Follow all instructions exactly."
    ),
    pattern = map(source_b_sections, section_ids)
  ),

  # Write session notes to vault (or DRY_RUN_PATH)
  # overwrite = TRUE: intentional — pipeline output replaces prior drafts on each run.
  # Vault history is preserved by git; overwrite here is safe.
  tar_target(
    session_notes_written,
    write_note(
      content       = session_note_content,
      relative_path = file.path("sessions", paste0(section_ids, ".md")),
      dry_run       = DRY_RUN,
      overwrite     = TRUE
    ),
    pattern = map(session_note_content, section_ids)
  ),

  # Review log header — depends on all notes being written first
  tar_target(review_header, { session_notes_written; write_run_header(CURRENT_SESSION) }),

  # Git commit — after notes and review log are written
  tar_target(vault_committed, { review_header; commit_vault(CURRENT_SESSION) })
)
```

`targets` caches every step. If Source B hasn't changed since last run, it won't re-fetch or re-parse it. Only new VTT files trigger re-extraction.

---

## 10. Append Mode & Conflict Detection

The pipeline runs after each session. Session notes are written with `overwrite = TRUE` — the pipeline replaces its own prior output on each run. This is safe because the vault is a git repo; every previous version is recoverable. The "never silently overwrites" principle applies to human-authored content: conflict detection (see below) flags contradictions rather than clobbering them.

### Rules

| Situation | Behavior |
|---|---|
| New entity | Create new note |
| New session | Always create new session note |
| Existing note, new non-conflicting info | Append to relevant section |
| Existing note, contradicting info | Append AND insert `[!warning]` callout |
| Sparse source (low word-count) | Minimal stub; `review_required: true` |
| Unresolved alias | Skip wikilink; log to `review_log.md` |

### Review Callout (Obsidian renders as a yellow warning box)

```markdown
> [!warning] DM Review Required
> **Source:** S2e38 prep notes
> **Conflict:** Previous note listed this NPC's faction as "Giff Military."
> New source suggests Eladrin/Fey Noble. Verify and update faction field.
```

### Review Log (`review/review_log.md`)

```markdown
## Run: 2026-05-01 (after S2e41)
- [ ] [[Buhrghur]] — faction conflict; see note callout
- [ ] [[S2e26_stub]] — source too sparse; manual entry needed
- [ ] Unresolved alias: "Mr. Cream" — add aliases: entry to the relevant note in Obsidian
```

---

## 11. R Package Installation

```r
install.packages(c(
  "targets",      # pipeline orchestration
  "tarchetypes",  # target helpers (tar_file, tar_age, etc.)
  "httr2",        # HTTP client for Ollama + Claude APIs
  "googledrive",  # Google Drive OAuth + file access
  "jsonlite",     # JSON parsing
  "readr",        # file reading
  "stringr",      # string manipulation
  "purrr",        # functional programming / map
  "fs",           # file system operations
  "gert",         # git operations from R
  "glue",         # string interpolation
  "yaml"          # YAML frontmatter generation
))
```

---

## 12. Configuration (`config.R`)

```r
# config.R — fill in after completing to-do list

# Obsidian vault — lives in barquentine_wiki repo (separate from this pipeline repo)
VAULT_PATH <- "/Users/jasongrahn/R-projects/barquentine_wiki/BarquentineWiki"

# NAS mount — confirmed at /Volumes/share/videos/
NAS_MOUNT <- "/Volumes/share/videos"

# Google Drive — auth handled by googledrive package (token cached ✓)
EPISODE_NOTES_DOC_ID <- "1m5xXbEsPBFdTZAUoUAgj6a14I7aF8LcszCmX-r1mBbs"

# Claude API — set in .Renviron, never hardcode
# Add to ~/.Renviron: ANTHROPIC_API_KEY=sk-ant-...
CLAUDE_MODEL <- "claude-sonnet-4-6"

# Ollama — local, no auth required
OLLAMA_BASE_URL     <- "http://localhost:11434"
OLLAMA_MODEL        <- "gemma4:latest"   # generator
OLLAMA_CRITIC_MODEL <- "qwen3.5:9b"     # critic (JSON schema enforced)

# Auto-approve disabled — all notes go through human review queue
CRITIC_AUTO_APPROVE_THRESHOLD <- Inf

# Current session (update each run)
CURRENT_SESSION <- "S2e42"

# Pipeline mode
DRY_RUN <- FALSE   # TRUE writes to /tmp/barquentine-preview/ instead of vault
```

`ANTHROPIC_API_KEY` goes in `~/.Renviron` (R's environment variable file), not in `config.R`. Add it with:

```r
usethis::edit_r_environ()
# Add line: ANTHROPIC_API_KEY=sk-ant-...
# Save and restart R
```

---

## 13. Output Validation & Dry-Run

### Dry-Run Mode
Set `DRY_RUN <- TRUE` in `config.R`. All output writes to `/tmp/barquentine-preview/`. Review before flipping to live. Recommended for:
- First pipeline run ever
- First time processing a new source type
- Any run after changing extraction prompts

### Validation Checks (before each file write)

```r
validate_note <- function(note_text, entity_registry) {
  issues <- character(0)

  # 1. Frontmatter parses as valid YAML
  front <- extract_frontmatter(note_text)
  if (inherits(tryCatch(yaml::read_yaml(text = front), error = identity), "error"))
    issues <- c(issues, "Invalid YAML frontmatter")

  # 2. All [[wikilinks]] exist in registry or are queued for creation
  links <- str_extract_all(note_text, "(?<=\\[\\[)[^\\]|]+")[[1]]
  missing <- links[!links %in% entity_registry]
  if (length(missing) > 0)
    issues <- c(issues, paste("Unresolved wikilinks:", paste(missing, collapse = ", ")))

  # 3. "Basil" does not appear in prose outside the Basil PC note
  if (str_detect(note_text, "\\bBasil\\b") && !str_detect(note_text, "^name: Basil"))
    issues <- c(issues, "Raw name 'Basil' found in prose — use [[Basil|the Captain]]")

  issues
}
```

Validation failures are logged to `review_log.md` and block the file write. The pipeline continues to the next note.

---

## 14. Versioning & GitHub

Two separate GitHub repos.

### `barquentine-pipeline`
- All R source code
- Never contains API keys, credentials, or vault content
- `.Renviron` and `config/gdrive_token/` in `.gitignore`
- Tag releases by session milestone: `git tag v0.1-s2e41`

### `barquentine-wiki`
- Obsidian vault — only `.md` files
- One auto-commit per pipeline run
- Full session-by-session history; any state recoverable with `git checkout`

### Versioning (two repos)
Pipeline code and vault are separate repos. Auto-commits go to `barquentine_wiki` only. Pipeline code in `barquentine_pipeline` is committed manually with descriptive messages. This mirrors how dbt project repos relate to generated documentation outputs in a professional setting.

### Auto-Commit (R / gert)

```r
library(gert)

commit_vault <- function(session_id, vault_path = VAULT_PATH) {
  git_add(".", repo = vault_path)
  git_commit(
    message = glue("Session {session_id} — auto-generated [{Sys.Date()}]"),
    repo    = vault_path
  )
}
```

---

## 15. Error Handling

| Error | Behavior |
|---|---|
| NAS not mounted | Fail fast: "NAS not found at /Volumes/share. Connect via Finder first." |
| Drive API auth expired | Prompt for interactive re-auth via `drive_auth()` |
| Drive doc not found | Fatal error with doc ID logged |
| Ollama not running | Fail fast with clear message; no Claude fallback (local-only pipeline) |
| Ollama malformed JSON | `parse_critic_response()` returns `parse_error` verdict → enqueued for review |
| Claude rate limit (429) | `req_retry()` handles: 10s → 30s → 90s backoff (Claude used for escalation UI only, not primary path) |
| Claude server error (5xx) | `req_retry()` retries twice; logs and skips (escalation path only) |
| Alias not in registry | Skip wikilink; log unresolved alias to review_log |
| Validation failure | Block file write; log to review_log; continue to next note |

---

## 16. Extraction Prompt Rules (All Prompts)

1. **Never fabricate.** If a detail is not in the source, the field is blank or `unknown`. No inference, no gap-filling.
2. **Preserve voice.** NPC dialogue is extracted verbatim from source.
3. **Mark source.** Every note includes a `source:` frontmatter field.
4. **Sparse sources produce sparse stubs.** Low word-count sections → `review_required: true`, minimal fields only.
5. **Name normalization in output prose only.** The Basil PC note retains "Basil" as its title. All other notes reference him as `[[Basil|the Captain]]`.

---

## 17. Unit Testing

Unit tests verify that individual functions behave correctly with known inputs before they're wired into the pipeline. In R, the standard tool is `testthat`. Tests live in `tests/testthat/` and are named to mirror their source file.

### Setup

```r
install.packages("testthat")

# Creates tests/testthat/ directory and boilerplate
usethis::use_testthat()
```

This adds the following to the project:
```
barquentine_pipeline/
├── tests/
│   └── testthat/
│       ├── test-gdrive.R
│       ├── test-source_b.R
│       ├── test-ollama.R
│       ├── test-claude.R
│       ├── test-wikilinks.R
│       ├── test-merge.R
│       └── test-writer.R
```

Run all tests with:
```r
testthat::test_dir("tests/testthat/")
```

### What to Test vs. What Not to Test

**Test these** — pure functions with known inputs and outputs:
- Text parsing and splitting logic (`parse_source_b`, `chunk_vtt`)
- Alias resolution and wikilink generation (`resolve_alias`, `make_wikilink`)
- Frontmatter YAML generation and validation (`validate_note`)
- Conflict detection logic (`detect_conflict`)
- Review log formatting (`format_review_entry`)
- Dry-run path switching (`get_output_path`)

**Don't test these** — external services; mock or skip in CI:
- `fetch_gdoc()` — hits Google Drive API; test with a saved fixture instead
- `spot_entities()` — hits Ollama; test the JSON parsing logic separately
- `claude_generate_note()` — hits Claude API; test the request construction separately
- `commit_vault()` — hits git; test with a temp repo or skip

### Example Tests

#### `tests/testthat/test-source_b.R`
```r
library(testthat)
source("R/source_b.R")

test_that("parse_source_b splits on # headings", {
  doc <- "# Barquentine S2e14\nSome content.\n# Barquentine S2e15\nMore content."
  result <- parse_source_b(doc)

  expect_equal(length(result), 2)
  expect_true("Barquentine S2e14" %in% names(result))
  expect_true("Barquentine S2e15" %in% names(result))
})

test_that("parse_source_b trims whitespace from sections", {
  doc <- "# Barquentine S2e14\n\n  Some content.  \n"
  result <- parse_source_b(doc)

  expect_equal(result[["Barquentine S2e14"]], "Some content.")
})

test_that("parse_source_b handles empty sections gracefully", {
  doc <- "# Barquentine S2e26\n# Barquentine S2e27\nContent here."
  result <- parse_source_b(doc)

  expect_true(nchar(trimws(result[["Barquentine S2e26"]])) == 0)
})
```

#### `tests/testthat/test-wikilinks.R`
```r
library(testthat)
source("R/wikilinks.R")

test_that("resolve_alias returns canonical slug for known variants", {
  aliases <- list("Old Brass" = "Brassam_Volund", "War Saint" = "Brassam_Volund")

  expect_equal(resolve_alias("Old Brass", aliases), "Brassam_Volund")
  expect_equal(resolve_alias("War Saint", aliases), "Brassam_Volund")
})

test_that("resolve_alias returns NULL for unknown names", {
  aliases <- list("Old Brass" = "Brassam_Volund")

  expect_null(resolve_alias("Unknown Person", aliases))
})

test_that("make_wikilink produces display alias syntax for the Captain", {
  expect_equal(make_wikilink("Basil", display = "the Captain"), "[[Basil|the Captain]]")
})

test_that("make_wikilink produces simple syntax for other entities", {
  expect_equal(make_wikilink("Attorrnash"), "[[Attorrnash]]")
})
```

#### `tests/testthat/test-writer.R`
```r
library(testthat)
source("config.R")
source("R/writer.R")

test_that("get_output_path returns dry-run path when DRY_RUN is TRUE", {
  path <- get_output_path("npcs/Attorrnash.md", dry_run = TRUE)
  expect_true(startsWith(path, DRY_RUN_PATH))
})

test_that("get_output_path returns vault path when DRY_RUN is FALSE", {
  path <- get_output_path("npcs/Attorrnash.md", dry_run = FALSE)
  expect_true(startsWith(path, VAULT_PATH))
})
```

#### `tests/testthat/test-merge.R`
```r
library(testthat)
source("R/merge.R")

test_that("detect_conflict identifies contradicting field values", {
  existing <- "status: alive"
  incoming <- "status: dead"

  expect_true(detect_conflict(existing, incoming, field = "status"))
})

test_that("detect_conflict returns FALSE when values match", {
  existing <- "status: alive"
  incoming <- "status: alive"

  expect_false(detect_conflict(existing, incoming, field = "status"))
})
```

### Test Philosophy for This Project

- **Write tests as you build each module**, not after. The test for `parse_source_b` gets written alongside `source_b.R` in Phase 1.
- **Tests serve as living documentation.** A new reader can understand what `make_wikilink()` does by reading the test, not the implementation.
- **Failing tests before coding is fine** — write the test that describes what you *want* the function to do, then write the function to make it pass. This is called test-driven development (TDD) and is good practice even if you're not strict about it.
- **Don't chase 100% coverage.** Test the logic that could silently produce wrong output. External API calls, file I/O, and git operations are better tested by running them manually the first time.

---

## 18. Extraction Prompt Templates

The extraction prompts are what Claude actually receives. They are the most critical part of the pipeline — clean plumbing feeding a bad prompt produces confident garbage. Prompts are defined in `R/extract.R` and called by `session_extractor.R`, `npc_extractor.R`, etc.

### Design Constraints (from Section 16 rules)
- Instructions must explicitly forbid fabrication — not just omit permission for it
- Every field must have a documented fallback: blank or `unknown`
- Sparse sections must be detectable from the output (via `review_required: true`)
- Prompt must produce valid YAML frontmatter + markdown body in one response

### Sparse Section Threshold
A source section is considered sparse and triggers `review_required: true` when it contains fewer than **100 words** of non-header content. This threshold is defined in `config.R` as:
```r
SPARSE_THRESHOLD_WORDS <- 100
```

### Session Note Prompt (Source B)

```r
session_prompt <- function(episode_id, section_text) {
  glue(
    "You are building an Obsidian markdown wiki for a D&D 5e Spelljammer campaign called Barquentine.

Your task: extract a structured session note from the source text below.

RULES — follow exactly:
1. Never fabricate. If a detail is not in the source text, leave the field blank or write 'unknown'. Do not infer or guess.
2. Preserve NPC dialogue verbatim if it appears in the source.
3. The player character formerly known as 'Basil' is referred to as 'the Captain' in all prose and wikilinks, written as [[Basil|the Captain]].
4. If the source text is fewer than 100 words, set review_required to true and populate only what is explicitly present.
5. All entity references (NPCs, locations, items, factions) must use [[wikilink]] syntax.
6. Output only the markdown note. No explanation, no preamble, no code fences.

SOURCE TEXT (episode: {episode_id}):
{section_text}

OUTPUT FORMAT:
---
tags: [session]
episode: {episode_id}
title:
date_played:
source: prep_notes
review_required: false
---

## Summary

## Key Events
-

## NPCs Present
-

## Locations
-

## Items / Artifacts
-

## Open Threads
-

## GM Notes
"
  )
}
```

### NPC Extraction Prompt

```r
npc_prompt <- function(npc_name, source_passages) {
  passages_text <- paste(source_passages, collapse = "\n\n---\n\n")
  glue(
    "You are building an Obsidian markdown wiki for a D&D 5e Spelljammer campaign called Barquentine.

Your task: extract a structured NPC note for '{npc_name}' from the source passages below.

RULES — follow exactly:
1. Never fabricate. Only include details explicitly stated in the source. Leave fields blank or write 'unknown' if not present.
2. Preserve any direct quotes verbatim, wrapped in blockquote syntax (> ).
3. The player character formerly known as 'Basil' is referred to in prose as [[Basil|the Captain]]. His own note title remains 'Basil'.
4. If fewer than 3 distinct facts are present about this NPC, set review_required to true.
5. Output only the markdown note. No explanation, no preamble, no code fences.

SOURCE PASSAGES:
{passages_text}

OUTPUT FORMAT:
---
tags: [npc]
name: {npc_name}
aliases: []
status: unknown
faction:
first_seen:
review_required: false
---

## Overview

## Appearance & Vibe

## Motivation

## Relationship to Party

## Quotes

## Session Appearances
-

## GM Notes
"
  )
}
```

### Prompt Testing Protocol
Before using a prompt in `_targets.R`, test it manually:

```r
source("config.R")
source("R/gdrive.R")
source("R/source_b.R")
source("R/claude.R")
source("R/extract.R")

# Pull one section and run the prompt manually
raw      <- fetch_gdoc(EPISODE_NOTES_DOC_ID)
sections <- parse_source_b(raw)

# Pick a rich section and a sparse one to compare output
rich   <- sections[["Barquentine S2e35"]]
sparse <- sections[["Barquentine S2e26"]]

cat(claude_generate_note(session_prompt("S2e35", rich),
                         system_prompt = "You are a precise structured data extractor."))
```

Read the output critically before wiring it into the pipeline. Ask:
- Did it fabricate anything not in the source?
- Did it leave sparse fields blank rather than filling them?
- Is the YAML frontmatter valid?
- Did it use `[[wikilink]]` syntax for entity references?

---

## 19. Source A Enumeration Strategy

Source A is the collection of individual early-session Google Drive prep docs. Unlike Source B (one known doc ID), Source A has no fixed list — the `.gdoc` shortcut files on your local machine contain the doc IDs, but they need to be enumerated and registered before the pipeline can process them.

### Approach: Static Registry File

Rather than having the pipeline discover Source A docs dynamically, we maintain a static CSV in the pipeline repo that maps each early session to its Google Doc ID. This is a one-time manual setup and gives us full control over which docs are included and in what order.

**`config/source_a_registry.csv`**
```
episode_id,doc_id,title,notes
S1e00,1LnxfA4QqZSmMUKEMSDO9JugRMfCN9wWtGB2wO-KM6sI,Session 0,confirmed
S1e03,1vRRlmg1mG2NksSSFXKawGzpstd85f-H_3IZy1MPsSBs,Ep3 Deck,confirmed
S1e09,1Z75xz1slMIyXYg5X9lorX0RKBDQ-n8b6pRFokD-30fY,Ep9 Waterline,confirmed
S1e13,1Lgx15WxW4WCB9gVHlL8kYFzkaFi5sVfLxEpW0QPyXTw,Ep13 Skiff pt1,confirmed
S1e14,1JvEGBkW8C9YRmu4M54B-6NgwFtmWeDpmB4a83_KpF-E,Ep14 Skiff pt2,confirmed
S1e15,1L4T-WzelO5HK1TkoPr1wbp7fhALyyua7hAV90zusFyc,Ep15 Helm,confirmed
S2e20,1ABE4jaBnRPWzOUQqX1o5ctgmTTu4obFy4uuIV1wYnlw,Ep20 Back and Fill,confirmed
```

Doc IDs already extracted from the `.gdoc` shortcut files uploaded earlier. Additional files can be added as they're located.

### `notes` Column Values
- `confirmed` — doc ID verified, content readable
- `missing` — session exists but no doc found
- `skip` — doc exists but content is too sparse to be useful

### Pipeline Usage (Phase 2)

```r
# R/source_a.R
load_source_a_registry <- function(registry_path = "config/source_a_registry.csv") {
  readr::read_csv(registry_path, show_col_types = FALSE) |>
    dplyr::filter(notes == "confirmed")
}

fetch_all_source_a <- function(registry) {
  purrr::map(registry$doc_id, fetch_gdoc) |>
    purrr::set_names(registry$episode_id)
}
```

This file is safe to commit — it contains only doc IDs, no secrets.

---

## 20. Open Questions

| # | Question | Status |
|---|---|---|
| 1 | Local model assignments? | ✅ `gemma4:latest` (generator), `qwen3.5:9b` (critic) — see v4.3 changelog |
| 2 | VTT cutover episode? | ✅ S2e34 confirmed |
| 3 | Vault path? | ✅ `/Users/jasongrahn/R-projects/barquentine_wiki/BarquentineWiki` |
| 4 | NAS VTT path? | ✅ `/Volumes/share/videos/` — files at root, no subdirectory |
| 5 | Repo structure? | ✅ Two repos: `barquentine_wiki` (vault) + `barquentine_pipeline` (code) |

All open questions resolved. Phase 0 complete — proceed to Phase 1.

---

## 21. Phased Rollout

### Phase 0 — Setup (complete ✅)
- All to-do items checked
- Both repos created and cloned
- Config confirmed

### Phase 1 — Scaffold + Source B
- Build and test each R module individually (see Section 17 for test protocol)
- Fetch and parse Source B into per-episode sections
- Generate session stubs for all episodes; full notes for "Previously on" intros (S2e33+)
- Validate wikilink graph in Obsidian graph view

### Phase 2 — Source A
- Populate `config/source_a_registry.csv` with remaining doc IDs
- Process early-session Drive docs
- Back-fill S1 session stubs
- Merge NPC data appearing in both sources; flag conflicts

### Phase 3 — Source C (VTT)
- Qwen entity-spotting pass on all VTT files from S2e34 onward
- Claude note-writing on spotted entities
- Overlay VTT content onto existing stubs (higher precedence)

### Phase 4 — Ongoing
- After each session: run `tar_make()` in Positron
- New VTT file detected → entity spotting → note append + conflict detection → git commit → review_log reviewed by DM

---

## 22. Success Criteria

- Every named entity has a note with source-verifiable content — no fabrication
- Every session from VTT cutover onward has a session note
- Wikilinks resolve — clicking `[[Attorrnash]]` opens the NPC note
- `review/review_log.md` is the single DM attention list after each run
- All tests pass via `testthat::test_dir("tests/testthat/")`
- Pipeline runs cleanly via `tar_make()` after each session in under 5 minutes
- Vault history is fully navigable in git — any session's state is recoverable
