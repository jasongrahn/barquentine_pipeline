render_action_bar <- function(row, is_rejected = FALSE) {
  is_session <- isTRUE(.nc(row$note_type, "") == "session")
  has_draft  <- nzchar(.nc(row$draft, ""))
  is_failed  <- isTRUE(!is.na(row$status) && row$status == "generation_failed")

  tags$div(
    class = "action-bar",
    if (!is_rejected && !is_failed) tagList(
      actionButton("approve_btn", "Approve", class = "btn-success btn-sm",
                   disabled = if (!has_draft) "disabled" else NULL),
      actionButton("edit_approve_btn", "Edit & Approve", class = "btn-warning btn-sm",
                   disabled = if (!has_draft) "disabled" else NULL)
    ),
    if (!has_draft && !is_rejected && !is_failed)
      tags$span(style = "font-size:0.8em;color:#dc3545;margin-right:8px;",
                "Draft empty \u2014 Regenerate first"),
    actionButton("regen_btn",  "Regenerate",       class = "btn-info btn-sm"),
    if (!is_session) actionButton("merge_btn", "Merge into\u2026", class = "btn-secondary btn-sm"),
    actionButton("reject_btn", "Reject \u25BE",    class = "btn-danger btn-sm"),
    actionButton("skip_btn",   "Skip",             class = "btn-outline-secondary btn-sm")
  )
}

render_review_pane <- function(row) {
  note_type <- .nc(row$note_type, "npc")
  tryCatch(
    switch(note_type,
      session  = render_session_review(row),
      npc      = render_npc_review(row),
      location = render_location_review(row),
      faction  = render_faction_review(row),
      render_npc_review(row)
    ),
    error = function(e) {
      err_msg   <- conditionMessage(e)
      entity_id <- .nc(row$section_id, "unknown")
      message("render_review_pane error [", note_type, "]: ", err_msg)
      tagList(
        tags$div(
          class = "alert alert-warning",
          style = "margin-bottom:12px;",
          tags$strong("Renderer error \u2014 showing fallback view."),
          tags$br(),
          tags$code(err_msg)
        ),
        fluidRow(
          column(6,
            tags$h6("Source"),
            .render_source_pane(.nc(row$source_text, ""), .nc(row$entity_name, entity_id))
          ),
          column(6,
            tags$h6("Draft"),
            .render_draft_pane(.nc(row$draft, ""), entity_id)
          )
        ),
        hr(style = "margin:12px 0;"),
        render_action_bar(row)
      )
    }
  )
}
