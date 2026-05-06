render_session_review <- function(row) {
  entity_id   <- row$section_id
  entity_name <- .nc(row$entity_name, entity_id)
  draft_text  <- .nc(row$draft, "")
  source_text <- .nc(row$source_text, "")
  verdict     <- .nc(row$verdict, "")
  confidence  <- if (is.na(row$confidence)) NA_real_ else row$confidence
  issues      <- .parse_json_col(row$issues)
  src_quotes  <- .parse_json_col(row$source_quotes)
  dismissed   <- tryCatch(
    as.integer(fromJSON(.nc(row$dismissed_findings, "[]"), simplifyVector = TRUE)),
    error = function(e) integer(0)
  )

  vault_rel <- file.path("sessions", paste0(entity_id, ".md"))

  verdict_class <- switch(verdict,
    approved = "verdict-approved", flagged = "verdict-flagged",
    rejected = "verdict-rejected", ""
  )

  tagList(
    fluidRow(
      column(8,
        tags$h4(style = "margin-bottom:2px;", entity_name,
          tags$span(style = "font-size:0.65em;color:#666;font-weight:400;margin-left:8px;",
                    "SESSION")
        ),
        tags$div(style = "font-size:0.82em;color:#555;",
          "Will be written to: ", tags$code(vault_rel),
          tags$span(style = "margin-left:8px;",
                    render_vault_status_badge(file.path(VAULT_PATH_ABS, vault_rel)))
        )
      ),
      column(4, style = "text-align:right;padding-top:14px;",
        tagList(
          if (nzchar(verdict)) tags$span(class = verdict_class, paste0("Critic: ", verdict, " ")),
          .confidence_badge(verdict, confidence)
        )
      )
    ),
    hr(style = "margin:10px 0;"),

    fluidRow(
      column(6,
        tags$h6("Source B \u2014 Google Doc Recap"),
        .render_source_pane(source_text, entity_name)
      ),
      column(6,
        tags$details(
          tags$summary(style = "cursor:pointer;font-size:0.85em;color:#555;margin-bottom:4px;",
                       "Raw VTT \u25BC (collapsed)"),
          .render_source_pane(source_text, entity_name)
        )
      )
    ),
    tags$div(style = "margin-top:14px;",
      tags$h6("Draft"),
      .render_draft_pane(draft_text, entity_id)
    ),
    if (length(issues) > 0)
      render_critic_cards_with_actions(issues, src_quotes, dismissed),
    hr(style = "margin:12px 0;"),
    render_action_bar(row)
  )
}
