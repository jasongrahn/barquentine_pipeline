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
