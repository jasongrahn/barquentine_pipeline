library(shiny)
library(readr)
library(jsonlite)

# shiny::runApp() sets wd to shiny/; reset to project root so all relative
# paths (review_queue/, training_data/, vault) resolve correctly.
PROJECT_ROOT <- normalizePath(file.path(getwd(), ".."))
setwd(PROJECT_ROOT)

source("config.R")
source("R/queue.R")
source("R/writer.R")
source("R/review.R")
source("R/training.R")

# Capture absolute paths now — before Shiny's session machinery can reset wd.
QUEUE_PATH_ABS    <- file.path(PROJECT_ROOT, REVIEW_QUEUE_PATH)
VAULT_PATH_ABS    <- file.path(PROJECT_ROOT, VAULT_PATH)
TRAINING_PATH_ABS <- file.path(PROJECT_ROOT, TRAINING_DATA_PATH)

parse_json_col <- function(x) {
  tryCatch(fromJSON(x, simplifyVector = FALSE), error = function(e) list())
}

null_coalesce <- function(x, default) if (is.null(x) || (length(x) == 1 && is.na(x))) default else x

# ---------------------------------------------------------------------------

ui <- fluidPage(
  tags$head(tags$style(HTML("
    pre { white-space: pre-wrap; word-break: break-word; }
    .verdict-approved  { color: #28a745; font-weight: bold; }
    .verdict-flagged   { color: #fd7e14; font-weight: bold; }
    .verdict-rejected  { color: #dc3545; font-weight: bold; }
    .verdict-escalated { color: #6f42c1; font-weight: bold; }
    .action-bar { margin-top: 12px; }
    .action-bar .btn { margin-right: 6px; }
    .critic-panel { background: #fff8e1; border-left: 3px solid #fd7e14;
                    padding: 8px 12px; margin: 8px 0; }
  "))),

  titlePanel("Barquentine — Review Queue"),

  sidebarLayout(
    sidebarPanel(
      width = 3,
      actionButton("refresh_btn", "Refresh", icon = icon("sync"), width = "100%"),
      hr(),
      h5("Pending"),
      uiOutput("pending_list"),
      hr(),
      p(textOutput("queue_summary"), style = "color: gray; font-size: 0.85em;")
    ),

    mainPanel(
      width = 9,
      uiOutput("review_panel")
    )
  )
)

# ---------------------------------------------------------------------------

server <- function(input, output, session) {

  queue_rv     <- reactiveVal(read_queue(.queue_path = QUEUE_PATH_ABS, status = "pending"))
  selected_idx <- reactiveVal(1L)

  output$queue_summary <- renderText({
    df <- queue_rv()
    paste(nrow(df), "pending item(s)")
  })

  output$pending_list <- renderUI({
    df <- queue_rv()
    if (nrow(df) == 0) return(p("Nothing pending.", style = "color: gray;"))
    lapply(seq_len(nrow(df)), function(i) {
      active <- selected_idx() == i
      tags$div(
        style = if (active) "font-weight: bold;" else "",
        actionLink(paste0("sel_", i), df$section_id[i])
      )
    })
  })

  # Wire sidebar item clicks
  observe({
    df <- queue_rv()
    lapply(seq_len(nrow(df)), function(i) {
      local({
        idx <- i
        observeEvent(input[[paste0("sel_", idx)]], {
          selected_idx(idx)
        }, ignoreInit = TRUE)
      })
    })
  })

  observeEvent(input$refresh_btn, {
    queue_rv(read_queue(.queue_path = QUEUE_PATH_ABS, status = "pending"))
    selected_idx(1L)
  })

  # Build the main review panel reactively
  output$review_panel <- renderUI({
    df <- queue_rv()
    if (nrow(df) == 0) {
      return(wellPanel(
        h3("Queue empty"),
        p("All items have been reviewed. Run generate_training_data() to export training pairs.")
      ))
    }

    idx <- min(selected_idx(), nrow(df))
    row <- df[idx, ]

    issues        <- parse_json_col(row$issues)
    source_quotes <- parse_json_col(row$source_quotes)

    verdict_class <- switch(null_coalesce(row$verdict, ""),
      approved = "verdict-approved",
      flagged  = "verdict-flagged",
      rejected = "verdict-rejected",
      ""
    )
    escalated_badge <- if (isTRUE(row$escalated)) {
      tags$span(" [escalated]", class = "verdict-escalated")
    }

    tagList(
      fluidRow(
        column(8, h3(row$section_id)),
        column(4, style = "text-align: right; padding-top: 20px;",
          tags$span(
            class = verdict_class,
            paste0("Critic: ", null_coalesce(row$verdict, "—"),
                   sprintf(" (%.2f)", null_coalesce(row$confidence, NA_real_)))
          ),
          escalated_badge
        )
      ),

      fluidRow(
        column(6,
          h5("Source Text"),
          tags$pre(style = "max-height: 380px; overflow-y: auto; background: #f8f9fa; padding: 8px;",
                   null_coalesce(row$source_text, ""))
        ),
        column(6,
          h5("Draft — edit below if needed:"),
          textAreaInput("edited_draft", label = NULL,
                        value = null_coalesce(row$draft, ""),
                        width = "100%", height = "380px")
        )
      ),

      if (!is.na(row$existing_note) && nzchar(trimws(null_coalesce(row$existing_note, "")))) fluidRow(
        column(12,
          tags$details(
            tags$summary(tags$strong("Current Vault Note (before this update)")),
            tags$pre(style = "max-height: 300px; overflow-y: auto; background: #e8f4f8;
                              border-left: 3px solid #17a2b8; padding: 8px; margin-top: 6px;",
                     row$existing_note)
          )
        )
      ),

      if (length(issues) > 0 || length(source_quotes) > 0) tags$div(
        class = "critic-panel",
        h5("Critic analysis:"),
        tags$ul(
          lapply(seq_along(issues), function(i) {
            quote_text <- if (i <= length(source_quotes)) {
              tags$span(style = "font-style: italic; color: #666; margin-left: 8px;",
                        paste0("\u201c", source_quotes[[i]], "\u201d"))
            } else NULL
            tags$li(as.character(issues[[i]]), quote_text)
          }),
          if (length(source_quotes) > length(issues))
            lapply(source_quotes[seq(length(issues) + 1L, length(source_quotes))],
                   function(q) tags$li(tags$em(as.character(q))))
        )
      ),

      tags$div(
        class = "action-bar",
        actionButton("accept_btn",      "Accept as Written", class = "btn-success btn-sm"),
        actionButton("accept_edit_btn", "Accept with Edits", class = "btn-warning btn-sm"),
        actionButton("reject_btn",      "Reject",            class = "btn-danger  btn-sm")
      ),

      uiOutput("action_msg")
    )
  })

  .current_row <- reactive({
    df  <- queue_rv()
    idx <- min(selected_idx(), nrow(df))
    df[idx, ]
  })

  .advance <- function() {
    queue_rv(read_queue(.queue_path = QUEUE_PATH_ABS, status = "pending"))
    new_n <- nrow(queue_rv())
    if (new_n == 0) {
      selected_idx(1L)
    } else {
      selected_idx(min(selected_idx(), new_n))
    }
  }

  output$action_msg <- renderUI(NULL)

  observeEvent(input$accept_btn, {
    row   <- .current_row()
    draft <- null_coalesce(row$draft, "")
    resolve_item(row$section_id, "accepted", .queue_path = QUEUE_PATH_ABS)
    if (nzchar(draft)) {
      write_note(content = draft,
                 relative_path = file.path("sessions", paste0(row$section_id, ".md")),
                 .vault_path = VAULT_PATH_ABS,
                 dry_run = DRY_RUN, overwrite = TRUE)
      note_path <- file.path("sessions", row$section_id)
      append_review_entry(
        format_review_entry(note_path, "auto-approved by pipeline", verdict = "accepted"),
        vault_path = VAULT_PATH_ABS, dry_run = DRY_RUN
      )
    }
    generate_training_data(.queue_path = QUEUE_PATH_ABS, .training_path = TRAINING_PATH_ABS)
    output$action_msg <- renderUI(
      tags$p(style = "color: #28a745;", paste("Accepted:", row$section_id))
    )
    .advance()
  })

  observeEvent(input$accept_edit_btn, {
    row      <- .current_row()
    edited   <- input$edited_draft
    original <- null_coalesce(row$draft, "")

    if (trimws(edited) == trimws(original)) {
      output$action_msg <- renderUI(
        tags$p(style = "color: #dc3545;",
               "No edits detected — textarea matches original draft. Use 'Accept as Written' instead, or make edits first.")
      )
      return(invisible(NULL))
    }

    resolve_item(row$section_id, "accepted_with_edit", edited_draft = edited,
                 .queue_path = QUEUE_PATH_ABS)
    if (nzchar(trimws(edited))) {
      write_note(content = edited,
                 relative_path = file.path("sessions", paste0(row$section_id, ".md")),
                 .vault_path = VAULT_PATH_ABS,
                 dry_run = DRY_RUN, overwrite = TRUE)
      note_path <- file.path("sessions", row$section_id)
      append_review_entry(
        format_review_entry(note_path, "accepted with edits", verdict = "accepted_with_edit"),
        vault_path = VAULT_PATH_ABS, dry_run = DRY_RUN
      )
    }
    generate_training_data(.queue_path = QUEUE_PATH_ABS, .training_path = TRAINING_PATH_ABS)
    output$action_msg <- renderUI(
      tags$p(style = "color: #fd7e14;", paste("Accepted with edit:", row$section_id))
    )
    .advance()
  })

  observeEvent(input$reject_btn, {
    row <- .current_row()
    resolve_item(row$section_id, "rejected", .queue_path = QUEUE_PATH_ABS)
    note_path <- file.path("sessions", row$section_id)
    append_review_entry(
      format_review_entry(note_path, "rejected by reviewer", verdict = "rejected"),
      vault_path = VAULT_PATH_ABS, dry_run = DRY_RUN
    )
    generate_training_data(.queue_path = QUEUE_PATH_ABS, .training_path = TRAINING_PATH_ABS)
    output$action_msg <- renderUI(
      tags$p(style = "color: #dc3545;", paste("Rejected:", row$section_id))
    )
    .advance()
  })
}

shinyApp(ui, server)
