render_critic_cards_with_actions <- function(issues, source_quotes,
                                              dismissed_indices = integer(0)) {
  if (length(issues) == 0) return(NULL)

  cards <- lapply(seq_along(issues), function(i) {
    issue_text  <- as.character(issues[[i]])
    quote_text  <- if (i <= length(source_quotes) && nzchar(source_quotes[[i]]))
      as.character(source_quotes[[i]]) else NULL
    is_dismissed <- i %in% dismissed_indices

    card_style <- paste0(
      "border: 1px solid ", if (is_dismissed) "#ccc" else "#fd7e14", "; ",
      "border-left: 4px solid ", if (is_dismissed) "#ccc" else "#fd7e14", "; ",
      "border-radius: 4px; padding: 10px 14px; margin: 6px 0; ",
      "background: ", if (is_dismissed) "#f8f9fa" else "#fff8f0", "; ",
      if (is_dismissed) "opacity:0.55;" else "cursor:pointer;"
    )

    tags$div(
      id    = paste0("critic_card_", i),
      style = card_style,
      if (!is_dismissed) {
        onclick <- sprintf(
          "Shiny.setInputValue('critic_card_click', {card:%d, ts:Date.now()}, {priority:'event'});",
          i
        )
        tagList(
          tags$div(style = "font-weight:500; margin-bottom:4px;", issue_text,
                   HTML(sprintf(' <span onclick="%s" style="cursor:pointer;"></span>', onclick))),
          if (!is.null(quote_text)) tags$div(
            style = "font-size:0.85em; color:#555; margin-bottom:6px;",
            tags$strong("Evidence: "),
            tags$em(paste0("\u201c", quote_text, "\u201d"))
          )
        )
      } else {
        tags$div(
          style = "font-weight:500; margin-bottom:4px; text-decoration:line-through; color:#888;",
          issue_text,
          tags$em(style = "font-size:0.8em; margin-left:6px;", "(dismissed)")
        )
      },
      if (!is_dismissed) {
        tags$div(
          style = "margin-top:6px; display:flex; gap:8px;",
          actionLink(paste0("finding_dismiss_", i), "Dismiss",
                     style = "font-size:0.8em; color:#888;"),
          tags$span(style = "color:#ccc;", "|"),
          actionLink(paste0("finding_address_", i), "Address via Regenerate",
                     style = "font-size:0.8em; color:#0d6efd;")
        )
      }
    )
  })

  tagList(
    tags$h6(style = "margin-top:16px;", "Critic Findings"),
    tagList(cards)
  )
}
