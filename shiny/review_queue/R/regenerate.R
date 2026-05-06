CAMPAIGN_FACTS_PATH <- "config/campaign_facts.md"

regenerate_modal_ui <- function() {
  modalDialog(
    title = "Regenerate with Feedback",
    size  = "m",
    tags$p(style = "color:#555;font-size:0.9em;",
           "Describe what the LLM got wrong or what it should know. ",
           "The prior draft, critic findings, and your feedback will all be sent to the generator."),
    textAreaInput(
      "regen_feedback",
      label = "Feedback (optional but encouraged)",
      placeholder = "e.g. 'Attorrnash is female \u2014 the transcript uses he/him incorrectly'",
      width = "100%", height = "110px"
    ),
    checkboxInput(
      "regen_save_fact",
      "Save this feedback as a campaign fact (prepended to all future entity prompts)"
    ),
    footer = tagList(
      modalButton("Cancel"),
      actionButton("regen_confirm_btn", "Regenerate", class = "btn-primary")
    ),
    easyClose = TRUE
  )
}

save_campaign_fact <- function(text, path = CAMPAIGN_FACTS_PATH) {
  if (!nzchar(trimws(text))) return(invisible(NULL))
  if (!file.exists(path)) {
    header <- paste0(
      "# TODO: v2 intent — move this file to the vault and read it into the pipeline at run time.\n",
      "# Known facts about this campaign, curated by the DM.\n",
      "# Prepended to every entity-note generation prompt as campaign context.\n\n"
    )
    writeLines(paste0(header, "- ", trimws(text)), path)
  } else {
    cat(paste0("\n- ", trimws(text)), file = path, append = TRUE)
  }
  invisible(path)
}
