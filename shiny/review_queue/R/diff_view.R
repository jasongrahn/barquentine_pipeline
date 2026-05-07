render_vault_status_badge <- function(existing_path) {
  if (file.exists(existing_path)) {
    tags$span(class = "badge",
              style = "background:#fd7e14;color:#fff;font-size:0.75em;padding:2px 7px;border-radius:10px;",
              "SUPPLEMENT")
  } else {
    tags$span(class = "badge",
              style = "background:#28a745;color:#fff;font-size:0.75em;padding:2px 7px;border-radius:10px;",
              "NEW")
  }
}

render_vault_diff <- function(existing_path, new_draft) {
  pane_style <- paste0(
    "background:#f8f9fa;padding:10px;border-radius:4px;",
    "font-family:monospace;font-size:0.82em;white-space:pre-wrap;",
    "max-height:260px;overflow-y:auto;"
  )

  if (!file.exists(existing_path)) {
    return(tags$div(
      tags$p(style = "color:#28a745;font-size:0.82em;margin-bottom:4px;",
             "\u2714 No existing vault file — this will be created."),
      tags$div(style = pane_style, new_draft)
    ))
  }

  existing_text <- tryCatch(
    paste(readLines(existing_path, warn = FALSE), collapse = "\n"),
    error = function(e) "(error reading vault file)"
  )

  fluidRow(
    column(6,
      tags$h6("Existing vault file", style = "font-size:0.85em;color:#666;"),
      tags$div(style = paste0(pane_style, "opacity:0.7;"), existing_text)
    ),
    column(6,
      tags$h6("Proposed content", style = "font-size:0.85em;color:#28a745;"),
      tags$div(style = paste0(pane_style, "border-left:3px solid #28a745;"), new_draft)
    )
  )
}
