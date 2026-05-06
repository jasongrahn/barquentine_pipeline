server <- function(input, output, session) {

  ENTITY_STATUSES <- c("pending", "generation_failed")
  ENTITY_TYPES    <- c("npc", "location", "faction")

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------
  queue_rv      <- reactiveVal(data.frame())
  selected_id   <- reactiveVal(NULL)
  action_msg_rv <- reactiveVal(NULL)

  .reload_queue <- function() {
    df <- read_queue(.queue_path = QUEUE_PATH_ABS, status = ENTITY_STATUSES)
    df <- df[!is.na(df$note_type) & df$note_type %in% ENTITY_TYPES, , drop = FALSE]
    queue_rv(df)
  }
  .reload_queue()

  .total_count <- function() {
    tryCatch({
      csv_path <- file.path(QUEUE_PATH_ABS, "queue.csv")
      if (!file.exists(csv_path)) return(0L)
      all_df <- read_csv(csv_path, show_col_types = FALSE)
      all_df <- .fill_missing_columns(all_df)
      nrow(all_df[!is.na(all_df$note_type) & all_df$note_type %in% ENTITY_TYPES, ])
    }, error = function(e) 0L)
  }

  # ---------------------------------------------------------------------------
  # Progress
  # ---------------------------------------------------------------------------
  output$progress_text <- renderText({
    n_rem   <- nrow(queue_rv())
    n_total <- .total_count()
    paste0(n_rem, " of ", n_total, " remaining")
  })

  observe({
    n_rem   <- nrow(queue_rv())
    n_total <- .total_count()
    pct     <- if (n_total > 0) round(100 * (n_total - n_rem) / n_total) else 0
    runjs(sprintf(
      "document.getElementById('progress_bar_fill').style.width = '%d%%';", pct
    ))
  })

  # ---------------------------------------------------------------------------
  # Sidebar
  # ---------------------------------------------------------------------------
  filtered_queue <- reactive({
    df <- queue_rv()
    q  <- trimws(.nc(input$search_box, ""))
    if (nzchar(q)) {
      q   <- tolower(q)
      df  <- df[grepl(q, tolower(.nc(df$entity_name, "")), fixed = TRUE) |
                grepl(q, tolower(df$section_id), fixed = TRUE), , drop = FALSE]
    }
    df
  })

  output$sidebar_content <- renderUI({
    render_sidebar(filtered_queue(), selected_id(), .total_count())
  })

  # Wire sidebar action links dynamically
  observe({
    df <- filtered_queue()
    if (is.null(df) || nrow(df) == 0) return()
    lapply(df$section_id, function(sid) {
      local({
        id <- sid
        observeEvent(input[[paste0("sel_", id)]], {
          selected_id(id)
          action_msg_rv(NULL)
        }, ignoreInit = TRUE)
      })
    })
  })

  observeEvent(input$refresh_btn, {
    .reload_queue()
    action_msg_rv(NULL)
  })

  # Auto-select first item when queue changes and nothing is selected
  observe({
    df  <- queue_rv()
    sid <- selected_id()
    if (is.null(sid) && nrow(df) > 0) selected_id(df$section_id[1])
  })

  # ---------------------------------------------------------------------------
  # Current row
  # ---------------------------------------------------------------------------
  current_row <- reactive({
    df  <- queue_rv()
    sid <- selected_id()
    if (is.null(df) || nrow(df) == 0 || is.null(sid)) return(NULL)
    idx <- which(df$section_id == sid)
    if (length(idx) == 0) return(NULL)
    df[idx[1], ]
  })

  # ---------------------------------------------------------------------------
  # Main panel
  # ---------------------------------------------------------------------------
  output$entity_panel <- renderUI({
    df  <- queue_rv()
    row <- current_row()

    if (is.null(df) || nrow(df) == 0) {
      return(wellPanel(h3("Queue empty"),
                       p("All entity notes have been reviewed for this batch.")))
    }
    if (is.null(row)) {
      return(p("Select an entity from the sidebar.", style = "color:#888;padding:20px;"))
    }

    entity_id   <- row$section_id
    entity_name <- .nc(row$entity_name, entity_id)
    note_type   <- .nc(row$note_type, "npc")
    draft_text  <- .nc(row$draft, "")
    source_text <- .nc(row$source_text, "")
    verdict     <- .nc(row$verdict, "")
    confidence  <- if (is.na(row$confidence)) NA_real_ else row$confidence
    issues      <- .parse_json_col(row$issues)
    src_quotes  <- .parse_json_col(row$source_quotes)
    is_failed   <- !is.na(row$status) && row$status == "generation_failed"
    has_draft   <- nzchar(draft_text)

    vault_rel  <- switch(note_type,
      npc      = file.path("npcs",      paste0(entity_id, ".md")),
      location = file.path("locations", paste0(entity_id, ".md")),
      faction  = file.path("factions",  paste0(entity_id, ".md")),
      file.path("npcs", paste0(entity_id, ".md"))
    )
    vault_full <- file.path(VAULT_PATH_ABS, vault_rel)
    vault_exists <- file.exists(vault_full)

    verdict_class <- switch(verdict,
      approved = "verdict-approved", flagged = "verdict-flagged",
      rejected = "verdict-rejected", ""
    )
    conf_label <- if (!is.na(confidence))
      sprintf("%.0f%%", confidence * 100) else "?"

    tagList(
      # --- Header ---
      fluidRow(
        column(7,
          tags$h4(style = "margin-bottom:2px;",
            entity_name,
            tags$span(style = "font-size:0.65em;color:#666;font-weight:400;margin-left:8px;",
                      toupper(note_type))
          ),
          tags$div(
            style = "font-size:0.82em;color:#555;",
            "Will be written to: ",
            tags$code(vault_rel),
            tags$span(style = "margin-left:8px;", render_vault_status_badge(vault_full))
          )
        ),
        column(5, style = "text-align:right;padding-top:14px;",
          if (nzchar(verdict)) tags$span(
            class = verdict_class,
            paste0("Critic: ", verdict,
                   if (!is.na(confidence)) paste0(" (", conf_label, ")") else "")
          )
        )
      ),
      hr(style = "margin:10px 0;"),

      # --- Failed generation banner ---
      if (is_failed) tags$div(
        style = "background:#fff3cd;border:1px solid #ffc107;border-radius:4px;padding:12px;margin-bottom:12px;",
        tags$strong("\u26A0 Generation failed."),
        " No draft was produced. Use ",
        tags$strong("Regenerate"),
        " to produce a draft, ",
        tags$strong("Merge"),
        " to add a session appearance to an existing entity, or ",
        tags$strong("Reject"),
        " to discard."
      ),

      # --- Source + Draft ---
      if (!is_failed) fluidRow(
        column(6,
          tags$h6("Source Evidence"),
          .render_source_pane(source_text, entity_name)
        ),
        column(6,
          tags$h6("Draft"),
          .render_draft_pane(draft_text, entity_id),
          if (vault_exists && has_draft) tags$details(
            style = "margin-top:10px;",
            tags$summary(style = "font-size:0.82em;cursor:pointer;color:#555;",
                         "Show vault diff \u25BC"),
            render_vault_diff(vault_full, draft_text)
          )
        )
      ),

      # --- Failed state: show source only ---
      if (is_failed) fluidRow(
        column(12,
          tags$h6("Source Evidence"),
          .render_source_pane(source_text, entity_name)
        )
      ),

      # --- Critic cards ---
      if (!is_failed && length(issues) > 0)
        render_critic_cards(issues, src_quotes),

      hr(style = "margin:12px 0;"),

      # --- Action bar ---
      tags$div(
        class = "action-bar",
        if (!is_failed) {
          tagList(
            actionButton("approve_btn", "Approve", class = "btn-success btn-sm",
                         disabled = if (!has_draft) "disabled" else NULL),
            actionButton("edit_approve_btn", "Edit & Approve", class = "btn-warning btn-sm",
                         disabled = if (!has_draft) "disabled" else NULL),
            if (!has_draft) tags$span(style = "font-size:0.8em;color:#dc3545;margin-right:8px;",
                                       "Draft empty \u2014 Regenerate first")
          )
        },
        actionButton("regen_btn",  "Regenerate",      class = "btn-info btn-sm"),
        actionButton("merge_btn",  "Merge into\u2026", class = "btn-secondary btn-sm"),
        actionButton("reject_btn", "Reject \u25BE",    class = "btn-danger btn-sm"),
        actionButton("skip_btn",   "Skip",             class = "btn-outline-secondary btn-sm")
      ),

      # --- Status message ---
      uiOutput("action_msg_ui")
    )
  })

  output$action_msg_ui <- renderUI({
    msg <- action_msg_rv()
    if (is.null(msg)) return(NULL)
    tags$p(style = paste0("color:", msg$color, ";margin-top:8px;font-size:0.9em;"),
           msg$text)
  })

  # ---------------------------------------------------------------------------
  # Critic card click → flash source pane (highlight via JS)
  # ---------------------------------------------------------------------------
  observeEvent(input$critic_card_click, {
    row    <- current_row()
    if (is.null(row)) return()
    quotes <- .parse_json_col(row$source_quotes)
    card_i <- input$critic_card_click$card
    if (card_i <= length(quotes)) {
      quote_text <- as.character(quotes[[card_i]])
      # Use JS to flash the matching passage in the source pane
      js_safe <- gsub("'", "\\'", quote_text, fixed = TRUE)
      runjs(sprintf(
        "(function(){
          var els = document.querySelectorAll('.source-passage');
          els.forEach(function(el) { el.style.background = ''; });
          els.forEach(function(el) {
            if (el.textContent.indexOf('%s') !== -1) {
              el.scrollIntoView({behavior:'smooth', block:'nearest'});
              el.style.background = '#fff3cd';
              setTimeout(function(){ el.style.background = ''; }, 2000);
            }
          });
        })();",
        substr(js_safe, 1, 50)
      ))
    }
  })

  # ---------------------------------------------------------------------------
  # Advance to next entity after action
  # ---------------------------------------------------------------------------
  .advance <- function() {
    old_id <- selected_id()
    .reload_queue()
    df <- queue_rv()
    if (nrow(df) == 0) { selected_id(NULL); return() }
    if (!is.null(old_id)) {
      idx <- which(df$section_id == old_id)
      if (length(idx) == 0 && nrow(df) > 0)
        selected_id(df$section_id[1])
    }
  }

  # ---------------------------------------------------------------------------
  # Approve
  # ---------------------------------------------------------------------------
  observeEvent(input$approve_btn, {
    row <- current_row()
    if (is.null(row)) return()
    draft <- .nc(row$draft, "")
    if (!nzchar(draft)) {
      action_msg_rv(list(text = "Draft is empty — Regenerate first.", color = "#dc3545"))
      return()
    }

    note_type <- .nc(row$note_type, "npc")
    vault_rel <- switch(note_type,
      npc      = file.path("npcs",      paste0(row$section_id, ".md")),
      location = file.path("locations", paste0(row$section_id, ".md")),
      faction  = file.path("factions",  paste0(row$section_id, ".md")),
      file.path("npcs", paste0(row$section_id, ".md"))
    )

    ep_ids <- tryCatch(
      fromJSON(.nc(row$source_episode_ids, "[]"), simplifyVector = TRUE),
      error = function(e) character(0)
    )

    content <- tryCatch({
      if (note_exists(vault_rel, dry_run = DRY_RUN,
                       .vault_path = VAULT_PATH_ABS, .dry_run_path = DRY_RUN_PATH)) {
        existing <- paste(readLines(
          get_output_path(vault_rel, dry_run = DRY_RUN,
                          .vault_path = VAULT_PATH_ABS, .dry_run_path = DRY_RUN_PATH),
          warn = FALSE), collapse = "\n")
        ep_id <- if (length(ep_ids) > 0) ep_ids[[1]] else row$section_id
        supplement_note(existing, draft, ep_id, note_type)
      } else {
        draft
      }
    }, error = function(e) draft)

    tryCatch({
      write_note(content, vault_rel, dry_run = DRY_RUN, overwrite = TRUE,
                 .vault_path = VAULT_PATH_ABS, .dry_run_path = DRY_RUN_PATH)
      resolve_item(row$section_id, "accepted", .queue_path = QUEUE_PATH_ABS)
      action_msg_rv(list(text = paste0("\u2714 Approved: ", row$section_id), color = "#28a745"))
      .advance()
    }, error = function(e) {
      action_msg_rv(list(text = paste0("Error: ", conditionMessage(e)), color = "#dc3545"))
    })
  })

  # ---------------------------------------------------------------------------
  # Edit & Approve — switch to Edit tab
  # ---------------------------------------------------------------------------
  observeEvent(input$edit_approve_btn, {
    updateTabsetPanel(session, "draft_tabs", selected = "Edit")
    action_msg_rv(list(text = "Edit the draft above, then click Approve.", color = "#555"))
  })

  # Approve from edit tab uses textarea value
  observeEvent(input$approve_btn, {
    tab <- .nc(input$draft_tabs, "Preview")
    if (tab != "Edit") return()

    row <- current_row()
    if (is.null(row)) return()
    entity_id <- row$section_id
    edited    <- .nc(input[[paste0("draft_edit_", entity_id)]], "")

    if (!nzchar(trimws(edited))) {
      action_msg_rv(list(text = "Edited draft is empty.", color = "#dc3545"))
      return()
    }
    if (trimws(edited) == trimws(.nc(row$draft, ""))) {
      action_msg_rv(list(text = "No changes detected. Switch to Approve or edit the text.",
                         color = "#fd7e14"))
      return()
    }

    note_type <- .nc(row$note_type, "npc")
    vault_rel <- switch(note_type,
      npc      = file.path("npcs",      paste0(entity_id, ".md")),
      location = file.path("locations", paste0(entity_id, ".md")),
      faction  = file.path("factions",  paste0(entity_id, ".md")),
      file.path("npcs", paste0(entity_id, ".md"))
    )

    tryCatch({
      write_note(edited, vault_rel, dry_run = DRY_RUN, overwrite = TRUE,
                 .vault_path = VAULT_PATH_ABS, .dry_run_path = DRY_RUN_PATH)
      resolve_item(entity_id, "accepted_with_edit",
                   edited_draft = edited, .queue_path = QUEUE_PATH_ABS)
      action_msg_rv(list(text = paste0("\u2714 Approved with edits: ", entity_id),
                         color = "#28a745"))
      .advance()
    }, error = function(e) {
      action_msg_rv(list(text = paste0("Error: ", conditionMessage(e)), color = "#dc3545"))
    })
  }, priority = -1)  # lower priority so preview-tab approve fires first

  # ---------------------------------------------------------------------------
  # Skip
  # ---------------------------------------------------------------------------
  observeEvent(input$skip_btn, {
    row <- current_row()
    if (is.null(row)) return()
    resolve_item(row$section_id, "snoozed", .queue_path = QUEUE_PATH_ABS)
    action_msg_rv(list(text = paste0("Skipped: ", row$section_id), color = "#888"))
    .advance()
  })

  # ---------------------------------------------------------------------------
  # Reject — show reason modal
  # ---------------------------------------------------------------------------
  observeEvent(input$reject_btn, {
    showModal(modalDialog(
      title = "Reject Entity",
      selectInput("reject_reason", "Reason",
                  choices = c(
                    "Garbage / LLM refusal"      = "rejected_garbage",
                    "Duplicate of another entity" = "rejected_duplicate",
                    "Not a real entity"           = "rejected_not_an_entity",
                    "Out of scope"                = "rejected_out_of_scope"
                  )),
      footer = tagList(
        modalButton("Cancel"),
        actionButton("reject_confirm_btn", "Reject", class = "btn-danger")
      ),
      easyClose = TRUE
    ))
  })

  observeEvent(input$reject_confirm_btn, {
    removeModal()
    row    <- current_row()
    if (is.null(row)) return()
    reason <- .nc(input$reject_reason, "rejected_garbage")
    resolve_item(row$section_id, reason, .queue_path = QUEUE_PATH_ABS)
    action_msg_rv(list(text = paste0("Rejected: ", row$section_id, " (", reason, ")"),
                       color = "#dc3545"))
    .advance()
  })

  # ---------------------------------------------------------------------------
  # Regenerate — modal then run
  # ---------------------------------------------------------------------------
  observeEvent(input$regen_btn, {
    showModal(regenerate_modal_ui())
  })

  observeEvent(input$regen_confirm_btn, {
    removeModal()
    row <- current_row()
    if (is.null(row)) return()

    feedback  <- trimws(.nc(input$regen_feedback, ""))
    save_fact <- isTRUE(input$regen_save_fact)

    if (save_fact && nzchar(feedback))
      save_campaign_fact(feedback, CAMPAIGN_FACTS_PATH)

    action_msg_rv(list(text = "\u23F3 Regenerating\u2026 (this may take 30\u201360 seconds)",
                       color = "#555"))

    passages <- str_split(.nc(row$source_text, ""), "\n\n---\n\n")[[1]]
    passages <- passages[nzchar(passages)]

    issues   <- .parse_json_col(row$issues)

    new_draft <- tryCatch({
      generate_entity_note(
        entity_name     = .nc(row$entity_name, row$section_id),
        source_passages = passages,
        note_type       = .nc(row$note_type, "npc"),
        prior_draft     = .nc(row$draft, ""),
        critic_findings = issues,
        user_feedback   = feedback
      )
    }, error = function(e) {
      action_msg_rv(list(text = paste0("Generation error: ", conditionMessage(e)),
                         color = "#dc3545"))
      NULL
    })

    if (is.null(new_draft)) return()

    new_verdict <- tryCatch({
      review_note(new_draft, .nc(row$source_text, ""))
    }, error = function(e) {
      list(verdict = "parse_error", confidence = 0, issues = list(), source_quotes = list())
    })

    tryCatch({
      update_draft(row$section_id, new_draft, new_verdict,
                   .queue_path = QUEUE_PATH_ABS)
      action_msg_rv(list(
        text  = paste0("\u2714 Regenerated: ", row$section_id,
                       " \u2014 critic: ", new_verdict$verdict),
        color = "#28a745"
      ))
      .reload_queue()
    }, error = function(e) {
      action_msg_rv(list(text = paste0("Save error: ", conditionMessage(e)),
                         color = "#dc3545"))
    })
  })

  # ---------------------------------------------------------------------------
  # Merge into existing — modal + confirm
  # ---------------------------------------------------------------------------
  observeEvent(input$merge_btn, {
    vault_entities <- tryCatch(
      list_vault_entities(VAULT_PATH_ABS),
      error = function(e) data.frame(slug = character(), name = character(),
                                      type = character(), stringsAsFactors = FALSE)
    )
    showModal(merge_modal_ui(vault_entities))
  })

  output$merge_preview_ui <- renderUI({
    row    <- current_row()
    target <- .nc(input$merge_target, "")
    if (is.null(row) || !nzchar(target)) return(NULL)

    surface_form <- .nc(row$entity_name, row$section_id)
    ep_ids <- tryCatch(
      fromJSON(.nc(row$source_episode_ids, "[]"), simplifyVector = TRUE),
      error = function(e) character(0)
    )
    ep_str <- if (length(ep_ids) > 0) paste(ep_ids, collapse = ", ") else "unknown episode"

    tags$div(
      style = "background:#f8f9fa;border-radius:4px;padding:10px;font-size:0.85em;margin-top:10px;",
      tags$strong("This will:"),
      tags$ul(
        tags$li(paste0("Append \u2018- [[", ep_str, "]]\u2019 to ",
                        target, "\u2019s Session Appearances")),
        tags$li(paste0("Register \u2018", surface_form,
                        "\u2019 as an alias of ", target)),
        tags$li("Discard the standalone draft for \u2018", surface_form, "\u2019")
      )
    )
  })

  observeEvent(input$merge_confirm_btn, {
    removeModal()
    row    <- current_row()
    target <- .nc(input$merge_target, "")

    if (is.null(row) || !nzchar(target)) {
      action_msg_rv(list(text = "No target selected.", color = "#dc3545"))
      return()
    }

    surface_form <- .nc(row$entity_name, row$section_id)
    ep_ids <- tryCatch(
      fromJSON(.nc(row$source_episode_ids, "[]"), simplifyVector = TRUE),
      error = function(e) character(0)
    )
    ep_id <- if (length(ep_ids) > 0) ep_ids[[1]] else row$section_id

    # Find target vault file and supplement it
    note_type  <- .nc(row$note_type, "npc")
    sub_dir_map <- c(npc = "npcs", location = "locations", faction = "factions")

    merged_ok <- FALSE
    for (subdir in c("npcs", "locations", "factions")) {
      target_path <- file.path(VAULT_PATH_ABS, subdir, paste0(target, ".md"))
      if (!file.exists(target_path)) next

      tryCatch({
        existing <- paste(readLines(target_path, warn = FALSE), collapse = "\n")
        supped   <- supplement_note(existing, .nc(row$draft, ""), ep_id, note_type)
        writeLines(supped, target_path)
        merged_ok <- TRUE
      }, error = function(e) NULL)
      break
    }

    if (!merged_ok) {
      action_msg_rv(list(text = paste0("Could not find vault file for: ", target),
                         color = "#dc3545"))
      return()
    }

    # Register alias
    tryCatch(
      register_alias_in_vault(target, surface_form, VAULT_PATH_ABS),
      error = function(e) NULL
    )

    resolve_item(row$section_id, "merged",
                 merged_into = target, .queue_path = QUEUE_PATH_ABS)
    action_msg_rv(list(
      text  = paste0("\u2714 Merged \u2018", surface_form, "\u2019 into \u2018", target, "\u2019"),
      color = "#28a745"
    ))
    .advance()
  })
}
