server <- function(input, output, session) {

  ENTITY_STATUSES <- c("pending", "generation_failed", "critic_rejected")
  ENTITY_TYPES    <- c("npc", "location", "faction", "session")

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------
  queue_rv      <- reactiveVal(data.frame())
  selected_id   <- reactiveVal(NULL)
  action_msg_rv <- reactiveVal(NULL)
  action_log_rv      <- reactiveVal(list())
  pending_approve_rv <- reactiveVal(NULL)

  .confidence_badge <- function(verdict, confidence) {
    if (!is.na(confidence) && confidence < 0.50)
      return(tags$span(class = "conf-danger",  "\u274C ", sprintf("%.0f%%", confidence * 100)))
    if (!is.na(confidence) && verdict == "approved")
      return(tags$span(class = "conf-approved", "\u2705 ", sprintf("%.0f%%", confidence * 100)))
    if (!is.na(confidence))
      return(tags$span(class = "conf-warn",    "\u26A0 ", sprintf("%.0f%%", confidence * 100)))
    NULL
  }

  .log_action <- function(section_id, entity_name, label, prior_draft = NULL,
                           was_merged = FALSE) {
    entry <- list(
      section_id  = section_id,
      entity_name = entity_name,
      label       = label,
      at          = format(Sys.time(), "%H:%M:%S"),
      prior_draft = prior_draft,
      was_merged  = was_merged
    )
    log <- c(list(entry), action_log_rv())
    action_log_rv(head(log, 5))
  }

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
  # Main panel — delegates to render_dispatch.R
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

    tagList(
      render_review_pane(row),
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
      snippet <- substr(js_safe, 1, 50)
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
        snippet
      ))
      runjs(sprintf(
        "(function(){
          var d = document.getElementById('draft_preview_content');
          if (!d) return;
          if ((d.innerText || '').indexOf('%s') !== -1) {
            d.style.outline = '2px solid #fd7e14';
            setTimeout(function(){ d.style.outline = ''; }, 2000);
          }
        })();",
        snippet
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
  # Approve — shows rename modal for entity types; writes directly for sessions
  # ---------------------------------------------------------------------------
  .resolve_write <- function(row, draft, resolution, vault_rel) {
    ep_ids <- tryCatch(
      fromJSON(.nc(row$source_episode_ids, "[]"), simplifyVector = TRUE),
      error = function(e) character(0)
    )
    note_type <- .nc(row$note_type, "npc")
    content <- tryCatch({
      if (note_exists(vault_rel, dry_run = DRY_RUN,
                       .vault_path = VAULT_PATH_ABS, .dry_run_path = DRY_RUN_PATH)) {
        existing <- paste(readLines(
          get_output_path(vault_rel, dry_run = DRY_RUN,
                          .vault_path = VAULT_PATH_ABS, .dry_run_path = DRY_RUN_PATH),
          warn = FALSE), collapse = "\n")
        ep_id <- if (length(ep_ids) > 0) ep_ids[[1]] else row$section_id
        supplement_note(existing, draft, ep_id, note_type)
      } else draft
    }, error = function(e) draft)

    write_note(content, vault_rel, dry_run = DRY_RUN, overwrite = TRUE,
               .vault_path = VAULT_PATH_ABS, .dry_run_path = DRY_RUN_PATH)
    resolve_item(row$section_id, resolution,
                 edited_draft = if (resolution == "accepted_with_edit") draft else NULL,
                 .queue_path = QUEUE_PATH_ABS)
    .log_action(row$section_id, .nc(row$entity_name, row$section_id), resolution,
                prior_draft = .nc(row$draft, ""))
    action_msg_rv(list(
      text  = paste0("\u2714 ",
                     if (resolution == "accepted_with_edit") "Approved with edits" else "Approved",
                     ": ", row$section_id),
      color = "#28a745"
    ))
    .advance()
  }

  observeEvent(input$approve_btn, {
    row <- current_row()
    if (is.null(row)) return()

    tab       <- .nc(input$draft_tabs, "Preview")
    entity_id <- row$section_id
    note_type <- .nc(row$note_type, "npc")

    draft <- if (tab %in% c("Edit", "Raw markdown")) {
      ed <- .nc(input[[paste0("draft_edit_", entity_id)]], "")
      if (!nzchar(trimws(ed))) {
        action_msg_rv(list(text = "Edited draft is empty.", color = "#dc3545"))
        return()
      }
      if (trimws(ed) == trimws(.nc(row$draft, ""))) {
        action_msg_rv(list(
          text  = "No changes detected. Edit the text first, or switch to approve as-is.",
          color = "#fd7e14"
        ))
        return()
      }
      ed
    } else {
      d <- .nc(row$draft, "")
      if (!nzchar(d)) {
        action_msg_rv(list(text = "Draft is empty \u2014 Regenerate first.", color = "#dc3545"))
        return()
      }
      d
    }

    resolution <- if (tab %in% c("Edit", "Raw markdown")) "accepted_with_edit" else "accepted"

    if (note_type == "session") {
      vault_rel <- file.path("sessions", paste0(entity_id, ".md"))
      tryCatch(
        .resolve_write(row, draft, resolution, vault_rel),
        error = function(e) action_msg_rv(list(
          text = paste0("Error: ", conditionMessage(e)), color = "#dc3545"))
      )
    } else {
      pending_approve_rv(list(row = row, draft = draft, resolution = resolution))
      entity_name <- .nc(row$entity_name, entity_id)
      showModal(rename_modal_ui(entity_id, entity_name, note_type, VAULT_PATH_ABS))
    }
  })

  # Rename modal: auto-derive slug from display name
  observeEvent(input$rename_derive_slug, {
    display_name <- trimws(.nc(input$rename_display_name, ""))
    if (nzchar(display_name)) {
      updateTextInput(session, "rename_slug", value = make_slug(display_name))
    }
  })

  output$rename_vault_path_preview <- renderUI({
    pending <- pending_approve_rv()
    if (is.null(pending)) return(NULL)
    slug      <- trimws(.nc(input$rename_slug, ""))
    note_type <- .nc(pending$row$note_type, "npc")
    sub_dir   <- switch(note_type, npc = "npcs", location = "locations",
                         faction = "factions", "npcs")
    err <- if (nzchar(slug))
      validate_rename_slug(slug, note_type, VAULT_PATH_ABS)
    else NULL

    if (!is.null(err)) {
      tags$p(style = "color:#dc3545;font-size:0.85em;", err)
    } else if (nzchar(slug)) {
      tags$p(style = "font-size:0.85em;color:#555;",
             "Will write to: ",
             tags$code(file.path(sub_dir, paste0(slug, ".md"))))
    }
  })

  observeEvent(input$rename_confirm_btn, {
    removeModal()
    pending <- pending_approve_rv()
    if (is.null(pending)) return()
    pending_approve_rv(NULL)

    row       <- pending$row
    draft     <- pending$draft
    resolution <- pending$resolution
    note_type <- .nc(row$note_type, "npc")
    slug      <- trimws(.nc(input$rename_slug, row$section_id))
    sub_dir   <- switch(note_type, npc = "npcs", location = "locations",
                         faction = "factions", "npcs")
    vault_rel <- file.path(sub_dir, paste0(slug, ".md"))

    err <- validate_rename_slug(slug, note_type, VAULT_PATH_ABS)
    if (!is.null(err)) {
      action_msg_rv(list(text = paste0("Slug error: ", err), color = "#dc3545"))
      return()
    }

    # If slug changed, update the queue row's slug_override
    if (slug != row$section_id) {
      tryCatch({
        csv_path <- file.path(QUEUE_PATH_ABS, "queue.csv")
        df  <- read_csv(csv_path, show_col_types = FALSE)
        df  <- .fill_missing_columns(df)
        idx <- which(df$section_id == row$section_id)
        if (length(idx) > 0) {
          df$slug_override[idx] <- slug
          write_csv(df, csv_path)
        }
      }, error = function(e) NULL)
    }

    tryCatch(
      .resolve_write(row, draft, resolution, vault_rel),
      error = function(e) action_msg_rv(list(
        text = paste0("Error: ", conditionMessage(e)), color = "#dc3545"))
    )
  })

  # ---------------------------------------------------------------------------
  # Edit & Approve — switch to Edit/Raw markdown tab
  # ---------------------------------------------------------------------------
  observeEvent(input$edit_approve_btn, {
    row <- current_row()
    note_type <- if (!is.null(row)) .nc(row$note_type, "npc") else "npc"
    tab_name  <- if (note_type %in% c("npc", "location", "faction")) "Raw markdown" else "Edit"
    updateTabsetPanel(session, "draft_tabs", selected = tab_name)
    action_msg_rv(list(text = "Edit the draft above, then click Approve.", color = "#555"))
  })

  # ---------------------------------------------------------------------------
  # Dynamic finding observers (dismiss / address-via-regenerate)
  # ---------------------------------------------------------------------------
  observe({
    row <- current_row()
    if (is.null(row)) return()
    issues <- .parse_json_col(row$issues)
    if (length(issues) == 0) return()
    lapply(seq_along(issues), function(i) {
      local({
        idx        <- i
        issue_text <- as.character(issues[[idx]])
        observeEvent(input[[paste0("finding_dismiss_", idx)]], {
          tryCatch({
            update_dismissed_findings(row$section_id, idx, .queue_path = QUEUE_PATH_ABS)
            .reload_queue()
          }, error = function(e) NULL)
        }, ignoreInit = TRUE, once = TRUE)
        observeEvent(input[[paste0("finding_address_", idx)]], {
          showModal(regenerate_modal_ui(prefill = issue_text))
        }, ignoreInit = TRUE, once = TRUE)
      })
    })
  })

  # ---------------------------------------------------------------------------
  # Skip
  # ---------------------------------------------------------------------------
  observeEvent(input$skip_btn, {
    row <- current_row()
    if (is.null(row)) return()
    resolve_item(row$section_id, "snoozed", .queue_path = QUEUE_PATH_ABS)
    .log_action(row$section_id, .nc(row$entity_name, row$section_id), "snoozed")
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
    .log_action(row$section_id, .nc(row$entity_name, row$section_id), reason)
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
      .log_action(row$section_id, .nc(row$entity_name, row$section_id), "regenerated",
                  prior_draft = .nc(row$draft, ""))
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
    row <- current_row()
    vault_entities <- tryCatch(
      list_vault_entities(VAULT_PATH_ABS),
      error = function(e) data.frame(slug = character(), name = character(),
                                      type = character(), stringsAsFactors = FALSE)
    )
    queue_items <- if (!is.null(row)) {
      list_queue_items(queue_rv(), .nc(row$note_type, "npc"), exclude_id = row$section_id)
    } else {
      NULL
    }
    showModal(merge_modal_ui(vault_entities, queue_items))
  })

  output$merge_preview_ui <- renderUI({
    row    <- current_row()
    target <- .nc(input$merge_target, "")
    if (is.null(row) || !nzchar(target)) return(NULL)

    surface_form <- .nc(row$entity_name, row$section_id)

    if (startsWith(target, "queue:")) {
      target_id <- sub("^queue:", "", target)
      tags$div(
        style = "background:#f8f9fa;border-radius:4px;padding:10px;font-size:0.85em;margin-top:10px;",
        tags$strong("This will:"),
        tags$ul(
          tags$li(paste0("Add \u2018", surface_form, "\u2019\u2019s source passages to \u2018", target_id, "\u2019")),
          tags$li(paste0("Remove \u2018", surface_form, "\u2019 from the queue")),
          tags$li(paste0("Leave \u2018", target_id, "\u2019 pending for review with the combined evidence"))
        )
      )
    } else {
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
          tags$li(paste0("Register \u2018", surface_form, "\u2019 as an alias of ", target)),
          tags$li("Discard the standalone draft for \u2018", surface_form, "\u2019")
        )
      )
    }
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

    # Queue-to-queue merge
    if (startsWith(target, "queue:")) {
      target_id <- sub("^queue:", "", target)
      tryCatch({
        merge_queue_items(row$section_id, target_id, .queue_path = QUEUE_PATH_ABS)
        .log_action(row$section_id, surface_form, "merged", was_merged = TRUE)
        action_msg_rv(list(
          text  = paste0("\u2714 Merged \u2018", surface_form, "\u2019 into queue item \u2018", target_id, "\u2019"),
          color = "#28a745"
        ))
        .advance()
      }, error = function(e) {
        action_msg_rv(list(text = paste0("Merge error: ", conditionMessage(e)), color = "#dc3545"))
      })
      return()
    }

    # Vault merge (existing path)
    ep_ids <- tryCatch(
      fromJSON(.nc(row$source_episode_ids, "[]"), simplifyVector = TRUE),
      error = function(e) character(0)
    )
    ep_id     <- if (length(ep_ids) > 0) ep_ids[[1]] else row$section_id
    note_type <- .nc(row$note_type, "npc")

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

    tryCatch(
      register_alias_in_vault(target, surface_form, VAULT_PATH_ABS),
      error = function(e) NULL
    )

    resolve_item(row$section_id, "merged",
                 merged_into = target, .queue_path = QUEUE_PATH_ABS)
    .log_action(row$section_id, surface_form, "merged", was_merged = TRUE)
    action_msg_rv(list(
      text  = paste0("\u2714 Merged \u2018", surface_form, "\u2019 into \u2018", target, "\u2019"),
      color = "#28a745"
    ))
    .advance()
  })

  # ---------------------------------------------------------------------------
  # Action log panel
  # ---------------------------------------------------------------------------
  output$action_log_ui <- renderUI({
    log <- action_log_rv()
    if (length(log) == 0) return(NULL)

    most_recent <- log[[1]]

    tags$details(
      tags$summary(
        style = "cursor:pointer;font-size:0.82em;color:#666;",
        paste0("Recent actions (", length(log), ")")
      ),
      tags$div(
        style = "font-size:0.8em;",
        lapply(seq_along(log), function(i) {
          e <- log[[i]]
          tags$div(
            style = "padding:2px 0; border-bottom:1px solid #eee;",
            tags$span(style = "color:#888;", paste0(e$at, " ")),
            tags$strong(e$label), " \u2014 ", e$entity_name
          )
        }),
        if (!most_recent$was_merged) actionButton(
          "undo_btn", "Undo last",
          class = "btn-outline-secondary btn-sm",
          style = "margin-top:6px;"
        ) else tags$p(
          style = "font-size:0.78em;color:#888;margin-top:4px;",
          "Last action was a merge \u2014 vault changes must be reverted manually."
        )
      )
    )
  })

  observeEvent(input$undo_btn, {
    log <- action_log_rv()
    if (length(log) == 0) return()
    last <- log[[1]]
    if (last$was_merged) return()

    tryCatch({
      revert_to_pending(last$section_id, prior_draft = last$prior_draft,
                        .queue_path = QUEUE_PATH_ABS)
      action_log_rv(log[-1])
      .reload_queue()
      selected_id(last$section_id)
      action_msg_rv(list(text = paste0("Undone: ", last$entity_name), color = "#555"))
    }, error = function(e) {
      action_msg_rv(list(text = paste0("Undo failed: ", conditionMessage(e)), color = "#dc3545"))
    })
  })
}
