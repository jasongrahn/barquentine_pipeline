list_vault_entities <- function(vault_path = VAULT_PATH) {
  result <- data.frame(slug = character(), name = character(),
                        type = character(), stringsAsFactors = FALSE)
  for (subdir in c("npcs", "locations", "factions")) {
    dir_path <- file.path(vault_path, subdir)
    if (!dir.exists(dir_path)) next
    files <- list.files(dir_path, pattern = "\\.md$", full.names = TRUE)
    for (f in files) {
      slug <- tools::file_path_sans_ext(basename(f))
      fm   <- tryCatch({
        txt <- paste(readLines(f, warn = FALSE), collapse = "\n")
        m   <- regmatches(txt, regexpr("(?s)^---\\n(.*?)\\n---", txt, perl = TRUE))
        if (length(m) == 0) list()
        else yaml::read_yaml(text = sub("^---\\n", "", sub("\\n---$", "", m)))
      }, error = function(e) list())
      name <- if (!is.null(fm$name) && nzchar(fm$name)) fm$name else slug
      result <- rbind(result, data.frame(slug = slug, name = name,
                                          type = subdir, stringsAsFactors = FALSE))
    }
  }
  result
}

merge_modal_ui <- function(vault_entities) {
  if (nrow(vault_entities) == 0) {
    choices <- c("No vault entities found" = "")
  } else {
    choices <- setNames(
      vault_entities$slug,
      paste0(vault_entities$name, " [", vault_entities$type, "]")
    )
  }

  modalDialog(
    title = "Merge into Existing Entity",
    size  = "m",
    selectInput("merge_target", "Merge into which existing entity?",
                choices = choices, selectize = TRUE),
    uiOutput("merge_preview_ui"),
    tags$p(style = "font-size:0.82em;color:#888;margin-top:8px;",
           "The surface form of the current entity will be registered as an alias on the target. ",
           "This prevents re-spotting on future runs."),
    footer = tagList(
      modalButton("Cancel"),
      actionButton("merge_confirm_btn", "Merge", class = "btn-warning")
    ),
    easyClose = TRUE
  )
}

register_alias_in_vault <- function(target_slug, alias_name, vault_path = VAULT_PATH) {
  for (subdir in c("npcs", "locations", "factions", "pcs")) {
    path <- file.path(vault_path, subdir, paste0(target_slug, ".md"))
    if (!file.exists(path)) next

    txt  <- paste(readLines(path, warn = FALSE), collapse = "\n")
    fm   <- tryCatch({
      m <- regmatches(txt, regexpr("(?s)^---\\n(.*?)\\n---", txt, perl = TRUE))
      if (length(m) == 0) list()
      else yaml::read_yaml(text = sub("^---\\n", "", sub("\\n---$", "", m)))
    }, error = function(e) list())

    existing_aliases <- if (!is.null(fm$aliases))
      as.character(unlist(fm$aliases)) else character(0)
    if (alias_name %in% existing_aliases) return(invisible(TRUE))

    fm$aliases <- c(existing_aliases, alias_name)
    new_fm     <- yaml::as.yaml(fm)
    new_txt    <- sub("(?s)^---\\n.*?\\n---",
                      paste0("---\n", new_fm, "---"),
                      txt, perl = TRUE)
    writeLines(new_txt, path)
    return(invisible(TRUE))
  }
  invisible(FALSE)
}
