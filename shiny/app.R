library(shiny)
library(readr)
library(jsonlite)

# Run via: shiny::runApp("shiny") from the project root directory
source("config.R")
source("R/queue.R")
source("R/writer.R")
source("R/review.R")
source("R/training.R")

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

  queue_rv     <- reactiveVal(read_queue(status = "pending"))
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
    queue_rv(read_queue(status = "pending"))
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

      if (length(issues) > 0) tagList(
        h5("Issues:"),
        tags$ul(lapply(issues, function(i) tags$li(as.character(i))))
      ),

      if (length(source_quotes) > 0) tagList(
        h5("Supporting quotes:"),
        tags$ul(lapply(source_quotes, function(q) tags$li(tags$em(as.character(q)))))
      ),

      hr(),

      fluidRow(
        column(6,
          h5("Source Text"),
          tags$pre(style = "max-height: 380px; overflow-y: auto; background: #f8f9fa; padding: 8px;",
                   null_coalesce(row$source_text, ""))
        ),
        column(6,
          h5("Draft"),
          tags$pre(style = "max-height: 380px; overflow-y: auto; background: #f8f9fa; padding: 8px;",
                   null_coalesce(row$draft, "(no draft)"))
        )
      ),

      hr(),
      h5("Edit Draft (optional — fill in to Accept with Edit):"),
      textAreaInput("edited_draft", label = NULL,
                    value = null_coalesce(row$draft, ""),
                    width = "100%", height = "250px"),

      tags$div(
        class = "action-bar",
        actionButton("accept_btn",      "Accept",             class = "btn-success btn-sm"),
        actionButton("accept_edit_btn", "Accept with Edit",   class = "btn-warning btn-sm"),
        actionButton("reject_btn",      "Reject",             class = "btn-danger  btn-sm")
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
    queue_rv(read_queue(status = "pending"))
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
    resolve_item(row$section_id, "accepted")
    if (nzchar(draft)) {
      write_note(content = draft,
                 relative_path = file.path("sessions", paste0(row$section_id, ".md")),
                 dry_run = DRY_RUN, overwrite = TRUE)
      note_path <- file.path("sessions", row$section_id)
      append_review_entry(
        format_review_entry(note_path, "auto-approved by pipeline", verdict = "accepted"),
        dry_run = DRY_RUN
      )
    }
    generate_training_data()
    output$action_msg <- renderUI(
      tags$p(style = "color: #28a745;", paste("Accepted:", row$section_id))
    )
    .advance()
  })

  observeEvent(input$accept_edit_btn, {
    row    <- .current_row()
    edited <- input$edited_draft
    resolve_item(row$section_id, "accepted_with_edit", edited_draft = edited)
    if (nzchar(trimws(edited))) {
      write_note(content = edited,
                 relative_path = file.path("sessions", paste0(row$section_id, ".md")),
                 dry_run = DRY_RUN, overwrite = TRUE)
      note_path <- file.path("sessions", row$section_id)
      append_review_entry(
        format_review_entry(note_path, "accepted with edits", verdict = "accepted_with_edit"),
        dry_run = DRY_RUN
      )
    }
    generate_training_data()
    output$action_msg <- renderUI(
      tags$p(style = "color: #fd7e14;", paste("Accepted with edit:", row$section_id))
    )
    .advance()
  })

  observeEvent(input$reject_btn, {
    row <- .current_row()
    resolve_item(row$section_id, "rejected")
    note_path <- file.path("sessions", row$section_id)
    append_review_entry(
      format_review_entry(note_path, "rejected by reviewer", verdict = "rejected"),
      dry_run = DRY_RUN
    )
    generate_training_data()
    output$action_msg <- renderUI(
      tags$p(style = "color: #dc3545;", paste("Rejected:", row$section_id))
    )
    .advance()
  })
}

shinyApp(ui, server)
