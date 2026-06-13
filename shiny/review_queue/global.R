library(shiny)
library(shinyjs)
library(readr)
library(jsonlite)
library(stringr)
library(fs)
library(yaml)
library(commonmark)

# Shiny may source global.R with wd = project root OR wd = shiny/review_queue/.
# Check for the project's top-level R/ and shiny/ dirs — always present at root,
# never inside the app subdirectory.
.wd <- normalizePath(getwd())
PROJECT_ROOT <- if (dir.exists(file.path(.wd, "R")) && dir.exists(file.path(.wd, "shiny"))) .wd else normalizePath(file.path(.wd, "../.."))
setwd(PROJECT_ROOT)

source("config.R")
source("R/queue.R")
source("R/writer.R")
source("R/validator.R")
source("R/review.R")
source("R/training.R")
source("R/merge.R")
source("R/wikilinks.R")
source("R/ollama.R")
source("R/agentic_extract.R")
source("R/agentic_entity_schemas.R")
source("R/agentic_entity_extract.R")
source("R/agentic_entity_writer.R")
source("R/agentic_entity_fact_check.R")
source("R/postprocess_shared.R")
source("R/agentic_postprocess.R")
source("R/agentic_fact_check.R")
source("R/agentic_writer.R")
source("R/source_c.R")
source("R/regen.R")
source("shiny/iteration_metadata.R")
source("shiny/review_queue/R/sidebar.R")
source("shiny/review_queue/R/critic_card.R")
source("shiny/review_queue/R/diff_view.R")
source("shiny/review_queue/R/regenerate.R")
source("shiny/review_queue/R/merge_action.R")
source("shiny/review_queue/R/placeholder_scan.R")
source("shiny/review_queue/R/finding_actions.R")
source("shiny/review_queue/R/rejected_state.R")
source("shiny/review_queue/R/rename_modal.R")
source("shiny/review_queue/R/render_session.R")
source("shiny/review_queue/R/render_npc.R")
source("shiny/review_queue/R/render_location.R")
source("shiny/review_queue/R/render_faction.R")
source("shiny/review_queue/R/render_dispatch.R")

QUEUE_PATH_ABS    <- file.path(PROJECT_ROOT, REVIEW_QUEUE_PATH)
VAULT_PATH_ABS    <- VAULT_PATH  # already absolute in config.R
TRAINING_PATH_ABS <- file.path(PROJECT_ROOT, TRAINING_DATA_PATH)

.nc <- function(x, default = "") if (is.null(x) || (length(x) == 1 && is.na(x))) default else x

.confidence_badge <- function(verdict, confidence) {
  if (!is.na(confidence) && confidence < 0.50)
    return(tags$span(class = "conf-danger",  "❌ ", sprintf("%.0f%%", confidence * 100)))
  if (!is.na(confidence) && verdict == "approved")
    return(tags$span(class = "conf-approved", "✅ ", sprintf("%.0f%%", confidence * 100)))
  if (!is.na(confidence))
    return(tags$span(class = "conf-warn",    "⚠ ", sprintf("%.0f%%", confidence * 100)))
  NULL
}

.parse_json_col <- function(x) {
  tryCatch(fromJSON(.nc(x, "[]"), simplifyVector = FALSE), error = function(e) list())
}

.entity_vault_path <- function(entity_id, note_type, vault_path = VAULT_PATH_ABS) {
  sub_dir <- switch(note_type,
    npc      = "npcs",
    location = "locations",
    faction  = "factions",
    "npcs"
  )
  file.path(vault_path, sub_dir, paste0(entity_id, ".md"))
}

.highlight_entity <- function(text, entity_name) {
  if (!nzchar(trimws(entity_name))) return(text)
  pattern <- paste0("(?i)(", str_escape(entity_name), ")")
  gsub(pattern, "<mark>\\1</mark>", text, perl = TRUE)
}

.render_source_pane <- function(source_text, entity_name) {
  passages <- str_split(source_text, "\n\n---\n\n")[[1]]
  passage_tags <- lapply(seq_along(passages), function(i) {
    highlighted <- .highlight_entity(passages[[i]], entity_name)
    tags$div(
      class = "source-passage",
      style = "margin-bottom: 14px;",
      tags$div(
        style = "font-size:0.75em;color:#888;font-weight:600;margin-bottom:2px;",
        paste0("[Chunk ", i, "]")
      ),
      tags$div(
        style = "font-size:0.87em;line-height:1.5;",
        HTML(highlighted)
      )
    )
  })
  tags$div(
    style = "max-height:420px;overflow-y:auto;padding:8px;background:#f8f9fa;border-radius:4px;",
    tagList(passage_tags)
  )
}

.render_draft_pane <- function(draft_text, entity_id) {
  safe_draft <- .nc(draft_text, "")
  html_preview <- if (nzchar(safe_draft)) {
    tryCatch(markdown_html(safe_draft), error = function(e) paste0("<pre>", safe_draft, "</pre>"))
  } else {
    "<p style='color:#999;font-style:italic;'>Draft is empty \u2014 use Regenerate to produce one.</p>"
  }

  tabsetPanel(
    id = "draft_tabs",
    tabPanel("Preview",
      tags$div(
        id    = "draft_preview_content",
        style = "max-height:420px;overflow-y:auto;padding:10px;border:1px solid #dee2e6;border-radius:4px;margin-top:8px;",
        HTML(html_preview)
      )
    ),
    tabPanel("Edit",
      tags$div(style = "margin-top:8px;",
        textAreaInput(paste0("draft_edit_", entity_id), label = NULL,
                      value = safe_draft, width = "100%", height = "380px")
      )
    )
  )
}
