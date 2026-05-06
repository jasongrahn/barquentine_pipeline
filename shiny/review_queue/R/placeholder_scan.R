scan_for_placeholders <- function(text) {
  grepl("\\[(unclear|unknown|needs[_ ]context|needs_context)\\]",
        text, ignore.case = TRUE, perl = TRUE)
}

render_placeholder_banner <- function() {
  tags$div(
    style = paste0(
      "background:#fff3cd;border:1px solid #ffc107;border-radius:4px;",
      "padding:12px;margin-bottom:12px;"
    ),
    tags$strong("\u26A0 Draft contains unresolved placeholders."),
    " Look for [unclear], [unknown], or [needs context] \u2014 Regenerate recommended before approving."
  )
}
