# Plan: Fix Shiny Review Queue Startup Errors

## Symptoms

Running `shiny::runApp("shiny/review_queue", port = 7475)` produces:

1. `Error in .reload_queue: object 'QUEUE_PATH_ABS' not found`
2. UI renders but is entirely greyed out (Shiny error overlay)

## Root Cause

Shiny sources `app.R` in a dedicated app environment (not `globalenv`). Inside `app.R`:

- Line 38 defines `QUEUE_PATH_ABS` in that local app environment
- Line 166 calls `source(...server.R...)` with the default `local = FALSE`, which sources `server.R` into **`globalenv`**

The `server` function's enclosing environment is therefore `globalenv`, where `QUEUE_PATH_ABS` does not exist. When the first session connects and calls `.reload_queue()` at `server.R:44`, the lookup fails.

Issue #2 (grey overlay) is a downstream effect of Issue #1.

## Fix

Create `shiny/review_queue/global.R`. Shiny explicitly sources `global.R` in `globalenv` before the app starts, making all vars defined there available to `server.R` regardless of scoping.

### Move from `app.R` into new `global.R`

- `library()` calls (app.R lines 1–8)
- `PROJECT_ROOT` computation and `setwd()` (lines 10–12)
- All `source()` calls for R/ helper files (lines 14–36)
- `QUEUE_PATH_ABS` and `VAULT_PATH_ABS` definitions (lines 38–39)
- Helper functions `.nc`, `.parse_json_col`, `.entity_vault_path`, `.highlight_entity`, `.render_source_pane`, `.render_draft_pane` (lines 41–110)

### What stays in `app.R`

- `ui <- fluidPage(...)` (lines 112–164)
- `source(...server.R...)` (line 166)
- `shinyApp(ui, server)` (line 168)

## Files to Change

| File | Action |
|---|---|
| `shiny/review_queue/global.R` | **Create** — move libs, paths, source calls, helper fns from app.R |
| `shiny/review_queue/app.R` | **Trim** — remove lines 1–110 (now in global.R); keep ui + shinyApp |

## Verification

1. `shiny::runApp("shiny/review_queue", port = 7475)`
2. No `QUEUE_PATH_ABS not found` error in console
3. UI loads without grey overlay
4. Sidebar renders entity list or empty-queue message
