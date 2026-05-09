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
source("R/regen.R")
source("shiny/iteration_metadata.R")
library(callr)

# Capture absolute paths now — before Shiny's session machinery can reset wd.
QUEUE_PATH_ABS    <- file.path(PROJECT_ROOT, REVIEW_QUEUE_PATH)
VAULT_PATH_ABS    <- file.path(PROJECT_ROOT, VAULT_PATH)
TRAINING_PATH_ABS <- file.path(PROJECT_ROOT, TRAINING_DATA_PATH)
LOCK_PATH_ABS     <- file.path(PROJECT_ROOT, REGEN_LOCK_FILE)

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
    .regen-status { font-size: 0.85em; margin-top: 4px; }
    .regen-queued { color: #6c757d; font-weight: bold; }
    .regen-running { color: #007bff; font-weight: bold; }
    .iter-meta { margin: -6px 0 8px 0; font-size: 0.85em; color: #555; }
    .iter-badge { display: inline-block; padding: 2px 8px; margin-right: 6px;
                  background: #eef2f7; border-radius: 10px; }
    .claude-badge { background: #ede0f7; color: #5a2a8a; font-weight: bold; }
    .reason-badge { background: transparent; color: #777; font-style: italic;
                    padding-left: 0; }
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
      uiOutput("regen_sidebar"),
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

  queue_rv         <- reactiveVal(read_queue(.queue_path = QUEUE_PATH_ABS, status = "pending"))
  selected_idx     <- reactiveVal(1L)
  regen_job_handle <- reactiveVal(NULL)

  # Orphan-lock guard: if Shiny restarted while a job was running, clean up.
  local({
    df_all <- read_queue(.queue_path = QUEUE_PATH_ABS, status = NULL)
    has_regenerating <- any(df_all$status == "regenerating", na.rm = TRUE)
    if (file.exists(LOCK_PATH_ABS) && has_regenerating) {
      df_all$status[df_all$status == "regenerating"] <- "regen_queued"
      readr::write_csv(df_all, file.path(QUEUE_PATH_ABS, "queue.csv"))
      file.remove(LOCK_PATH_ABS)
    }
  })

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
        column(8,
          h3(row$section_id),
          .format_iteration_badges(
            iteration_count    = row$iteration_count,
            claude_used        = row$claude_used,
            iteration_log_json = row$iteration_log
          )
        ),
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

      if (isTRUE(!is.na(row$existing_note) && nzchar(trimws(null_coalesce(row$existing_note, ""))))) fluidRow(
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
        actionButton("reject_btn",      "Reject",            class = "btn-danger  btn-sm"),
        actionButton("regen_btn",       "Queue for Regen",   class = "btn-secondary btn-sm")
      ),
      uiOutput("reject_panel"),
      textAreaInput("regen_feedback", label = "Feedback for regen (optional):",
                    value = "", width = "100%", height = "70px",
                    placeholder = "e.g. 'Focus on the faction\u2019s trade goals, not conquest.'"),

      uiOutput("action_msg")
    )
  })

  .current_row <- reactive({
    df  <- queue_rv()
    idx <- min(selected_idx(), nrow(df))
    df[idx, ]
  })

  reject_pending <- reactiveVal(FALSE)

  .advance <- function() {
    reject_pending(FALSE)
    queue_rv(read_queue(.queue_path = QUEUE_PATH_ABS, status = "pending"))
    new_n <- nrow(queue_rv())
    if (new_n == 0) {
      selected_idx(1L)
    } else {
      selected_idx(min(selected_idx(), new_n))
    }
  }

  output$action_msg <- renderUI(NULL)

  # --- Reject panel ------------------------------------------------------------

  output$reject_panel <- renderUI({
    if (!reject_pending()) return(NULL)
    tags$div(
      style = "margin-top: 6px;",
      textAreaInput("reject_reason", label = "Rejection reason (optional):",
                    value = "", width = "100%", height = "70px",
                    placeholder = "e.g. 'Fabricated NPC name not in source text.'"),
      actionButton("confirm_reject_btn", "Confirm Reject", class = "btn-danger btn-sm")
    )
  })

  # --- Regen sidebar -----------------------------------------------------------

  output$regen_sidebar <- renderUI({
    df_all        <- read_queue(.queue_path = QUEUE_PATH_ABS, status = NULL)
    n_queued      <- sum(df_all$status == "regen_queued",  na.rm = TRUE)
    n_regenerating <- sum(df_all$status == "regenerating", na.rm = TRUE)
    job_running   <- !is.null(regen_job_handle()) || file.exists(LOCK_PATH_ABS)

    status_line <- if (n_regenerating > 0) {
      tags$p(class = "regen-status",
             tags$span(class = "regen-running",
                       paste0("\u21bb ", n_regenerating, " regenerating\u2026")))
    } else if (n_queued > 0) {
      tags$p(class = "regen-status",
             tags$span(class = "regen-queued",
                       paste0(n_queued, " queued for regen")))
    } else NULL

    tagList(
      status_line,
      actionButton("go_regen_btn", "Go Regenerate",
                   class = if (job_running) "btn-secondary btn-sm" else "btn-primary btn-sm",
                   width = "100%",
                   disabled = if (job_running || n_queued == 0) "disabled" else NULL)
    )
  })

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
    reject_pending(TRUE)
    output$action_msg <- renderUI(
      tags$p(style = "color: #dc3545;", "Add a reason (optional) and click Confirm Reject.")
    )
  })

  observeEvent(input$confirm_reject_btn, {
    row   <- .current_row()
    reason <- trimws(input$reject_reason)
    resolve_item(row$section_id, "rejected",
                 reject_reason = if (nzchar(reason)) reason else NULL,
                 .queue_path = QUEUE_PATH_ABS)
    note_path <- file.path("sessions", row$section_id)
    append_review_entry(
      format_review_entry(note_path, "rejected by reviewer", verdict = "rejected"),
      vault_path = VAULT_PATH_ABS, dry_run = DRY_RUN
    )
    generate_training_data(.queue_path = QUEUE_PATH_ABS, .training_path = TRAINING_PATH_ABS)
    output$action_msg <- renderUI(
      tags$p(style = "color: #dc3545;", paste("Rejected:", row$section_id))
    )
    reject_pending(FALSE)
    .advance()
  })

  # --- Queue for Regen ---------------------------------------------------------

  observeEvent(input$regen_btn, {
    row      <- .current_row()
    feedback <- trimws(input$regen_feedback)

    current_count <- {
      rc <- row$regen_count
      if (is.null(rc) || (length(rc) == 1 && is.na(rc))) 0L else as.integer(rc)
    }
    if (current_count >= REGEN_MAX_COUNT) {
      output$action_msg <- renderUI(
        tags$p(style = "color: #dc3545;",
               paste0("Cannot queue \u2014 ", row$section_id, " has been regenerated ",
                      current_count, " time(s). Max is ", REGEN_MAX_COUNT,
                      ". Accept, edit, or reject instead."))
      )
      return(invisible(NULL))
    }

    tryCatch({
      queue_for_regen(row$section_id,
                      user_feedback = if (nzchar(feedback)) feedback else NA_character_,
                      .queue_path   = QUEUE_PATH_ABS)
      updateTextAreaInput(session, "regen_feedback", value = "")
      output$action_msg <- renderUI(
        tags$p(style = "color: #6c757d;",
               paste("Queued for regen:", row$section_id))
      )
      .advance()
    }, error = function(e) {
      output$action_msg <- renderUI(
        tags$p(style = "color: #dc3545;", conditionMessage(e))
      )
    })
  })

  # --- Go Regenerate -----------------------------------------------------------

  observeEvent(input$go_regen_btn, {
    if (!is.null(regen_job_handle()) || file.exists(LOCK_PATH_ABS)) {
      output$action_msg <- renderUI(
        tags$p(style = "color: #fd7e14;", "A regen job is already running.")
      )
      return(invisible(NULL))
    }

    handle <- tryCatch(
      start_regen_job(project_root = PROJECT_ROOT, .queue_path = QUEUE_PATH_ABS),
      error = function(e) {
        output$action_msg <- renderUI(
          tags$p(style = "color: #dc3545;",
                 paste("Failed to start regen job:", conditionMessage(e)))
        )
        NULL
      }
    )
    if (!is.null(handle)) {
      regen_job_handle(handle)
      output$action_msg <- renderUI(
        tags$p(style = "color: #007bff;", "Regen job started \u2014 keep reviewing!")
      )
    }
  })

  # --- Poll for regen completion (every 3s while a job is active) --------------

  observe({
    invalidateLater(3000, session)
    handle <- regen_job_handle()
    if (is.null(handle)) return(invisible(NULL))

    if (!handle$is_alive()) {
      regen_job_handle(NULL)
      if (file.exists(LOCK_PATH_ABS)) file.remove(LOCK_PATH_ABS)
      queue_rv(read_queue(.queue_path = QUEUE_PATH_ABS, status = "pending"))
      new_n <- nrow(queue_rv())
      selected_idx(if (new_n == 0) 1L else min(selected_idx(), new_n))
      output$action_msg <- renderUI(
        tags$p(style = "color: #28a745;", "\u2713 Regen complete \u2014 queue refreshed.")
      )
    }
  })
}

shinyApp(ui, server)
