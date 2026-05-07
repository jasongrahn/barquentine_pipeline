if (!exists("CRITIC_REJECT_THRESHOLD")) CRITIC_REJECT_THRESHOLD <- 0.95
if (!exists("CRITIC_FLAG_THRESHOLD"))   CRITIC_FLAG_THRESHOLD   <- 0.50

is_critic_rejected <- function(verdict, confidence) {
  isTRUE(verdict == "rejected") &&
    !is.na(confidence) && confidence >= CRITIC_REJECT_THRESHOLD
}

render_rejected_banner <- function() {
  tags$div(
    style = paste0(
      "background:#f8d7da;border:1px solid #f5c6cb;border-radius:4px;",
      "padding:12px;margin-bottom:12px;"
    ),
    tags$strong("\u274C The critic rejected this draft with high confidence."),
    " Recommended actions: Regenerate or Reject."
  )
}
