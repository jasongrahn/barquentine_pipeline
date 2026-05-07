render_location_review <- function(row) {
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
  is_rejected <- is_critic_rejected(verdict, confidence)

  fm   <- tryCatch(.parse_frontmatter(draft_text), error = function(e) list())
  body <- tryCatch({
    m <- regexpr("^---\\s*\\n.*?\\n---\\s*\\n", draft_text, perl = TRUE)
    if (m > 0) substring(draft_text, m + attr(m, "match.length")) else draft_text
  }, error = function(e) draft_text)

  vault_rel  <- file.path("locations", paste0(entity_id, ".md"))
  vault_full <- file.path(VAULT_PATH_ABS, vault_rel)

  verdict_class <- switch(verdict,
    approved = "verdict-approved", flagged = "verdict-flagged",
    rejected = "verdict-rejected", ""
  )

  location_fields <- list(
    list(key = "name",                label = "Name"),
    list(key = "type",                label = "Type"),
    list(key = "region",              label = "Region / parent location"),
    list(key = "controlling_faction", label = "Controlling faction"),
    list(key = "key_events",          label = "Key events")
  )

  controlling_faction <- .nc(fm[["controlling_faction"]], "")
  faction_overlap <- nzchar(controlling_faction) &&
    tolower(trimws(controlling_faction)) == tolower(trimws(entity_name))

  tagList(
    fluidRow(
      column(8,
        tags$h4(style = "margin-bottom:2px;", entity_name,
          tags$span(style = "font-size:0.65em;color:#666;font-weight:400;margin-left:8px;", "LOCATION")
        ),
        tags$div(style = "font-size:0.82em;color:#555;",
          "Will be written to: ", tags$code(vault_rel),
          tags$span(style = "margin-left:8px;", render_vault_status_badge(vault_full))
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

    if (is_rejected)  render_rejected_banner(),
    if (!is_rejected && scan_for_placeholders(draft_text)) render_placeholder_banner(),
    if (faction_overlap) tags$div(
      style = paste0(
        "background:#fff3cd;border:1px solid #fd7e14;border-radius:4px;",
        "padding:10px 14px;margin-bottom:12px;"
      ),
      tags$strong("\u26A0 This might also be a faction."),
      " The controlling faction field matches this location\u2019s name.",
      " Consider using Merge to link with an existing faction entry, or Reject and create a faction note instead."
    ),

    fluidRow(
      column(6,
        tags$h6("Source Evidence"),
        .render_source_pane(source_text, entity_name)
      ),
      column(6,
        tags$h6("Draft"),
        tabsetPanel(
          id = "draft_tabs",
          tabPanel("Card",
            .render_structured_draft(fm, body, location_fields)
          ),
          tabPanel("Raw markdown",
            tags$div(style = "margin-top:8px;",
              textAreaInput(paste0("draft_edit_", entity_id), label = NULL,
                            value = draft_text, width = "100%", height = "380px")
            )
          )
        ),
        if (file.exists(vault_full) && nzchar(draft_text)) tags$details(
          style = "margin-top:10px;",
          tags$summary(style = "font-size:0.82em;cursor:pointer;color:#555;",
                       "Show vault diff \u25BC"),
          render_vault_diff(vault_full, draft_text)
        )
      )
    ),

    if (length(issues) > 0) render_critic_cards_with_actions(issues, src_quotes, dismissed),
    hr(style = "margin:12px 0;"),
    render_action_bar(row, is_rejected = is_rejected)
  )
}
