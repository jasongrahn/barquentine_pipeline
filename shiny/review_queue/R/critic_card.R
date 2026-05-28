render_grounding_panel <- function(row) {
  pipeline_path <- .nc(row$pipeline_path, "")
  if (!nzchar(pipeline_path) || pipeline_path == "critic_loop") return(NULL)
  if (!startsWith(pipeline_path, "aps_")) return(NULL)

  coverage_score <- if (is.na(row$coverage_score)) NA_real_ else as.numeric(row$coverage_score)

  matched   <- tryCatch(fromJSON(.nc(row$matched_claims,   "[]"), simplifyVector = TRUE),
                        error = function(e) character(0))
  unmatched <- tryCatch(fromJSON(.nc(row$unmatched_claims, "[]"), simplifyVector = TRUE),
                        error = function(e) character(0))
  if (!is.character(matched))   matched   <- character(0)
  if (!is.character(unmatched)) unmatched <- character(0)

  score_label <- if (!is.na(coverage_score))
    tags$span(
      style = paste0("font-weight:bold;color:",
                     if (coverage_score >= 0.7) "#28a745"
                     else if (coverage_score >= 0.4) "#fd7e14"
                     else "#dc3545", ";"),
      sprintf("%.0f%% grounded", coverage_score * 100)
    )
  else NULL

  make_badges <- function(claims, bg) {
    if (length(claims) == 0) return(NULL)
    lapply(claims, function(cl) {
      tags$span(
        style = paste0("display:inline-block;background:", bg, ";color:#fff;",
                       "border-radius:3px;padding:2px 6px;margin:2px;font-size:0.78em;"),
        cl
      )
    })
  }

  tagList(
    tags$h6(style = "margin-top:16px;", "APS Grounding", score_label),
    if (length(matched) > 0) tagList(
      tags$div(style = "font-size:0.8em;color:#555;margin-bottom:4px;",
               paste0("Matched (", length(matched), ")")),
      tags$div(tagList(make_badges(matched, "#28a745")))
    ),
    if (length(unmatched) > 0) tagList(
      tags$div(style = "font-size:0.8em;color:#555;margin:8px 0 4px;",
               paste0("Unmatched (", length(unmatched), ")")),
      tags$div(tagList(make_badges(unmatched, "#dc3545")))
    )
  )
}

render_critic_cards <- function(issues, source_quotes) {
  if (length(issues) == 0) return(NULL)

  cards <- lapply(seq_along(issues), function(i) {
    issue_text <- as.character(issues[[i]])
    quote_text <- if (i <= length(source_quotes) && nzchar(source_quotes[[i]]))
      as.character(source_quotes[[i]]) else NULL

    tags$div(
      id    = paste0("critic_card_", i),
      style = paste0(
        "border: 1px solid #fd7e14; border-left: 4px solid #fd7e14; ",
        "border-radius: 4px; padding: 10px 14px; margin: 6px 0; ",
        "background: #fff8f0; cursor: pointer;"
      ),
      onclick = sprintf(
        "Shiny.setInputValue('critic_card_click', {card:%d, ts:Date.now()}, {priority:'event'});",
        i
      ),
      tags$div(style = "font-weight:500; margin-bottom:4px;", issue_text),
      if (!is.null(quote_text)) tags$div(
        style = "font-size:0.85em; color:#555;",
        tags$strong("Evidence: "),
        tags$em(paste0("\u201c", quote_text, "\u201d"))
      )
    )
  })

  tagList(
    tags$h6(style = "margin-top:16px;", "Critic Findings"),
    tagList(cards)
  )
}
