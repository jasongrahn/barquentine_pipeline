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

list_queue_items <- function(queue_df, note_type, exclude_id = NULL) {
  rows <- queue_df[!is.na(queue_df$note_type) & queue_df$note_type == note_type, ]
  if (!is.null(exclude_id)) rows <- rows[rows$section_id != exclude_id, ]
  if (nrow(rows) == 0) return(data.frame(slug = character(), name = character(),
                                          stringsAsFactors = FALSE))
  data.frame(
    slug = paste0("queue:", rows$section_id),
    name = paste0(.nc(rows$entity_name, rows$section_id), " [queue]"),
    stringsAsFactors = FALSE
  )
}

merge_modal_ui <- function(vault_entities, queue_items = NULL) {
  has_queue  <- !is.null(queue_items) && nrow(queue_items) > 0
  has_vault  <- nrow(vault_entities) > 0

  vault_choices <- if (has_vault)
    setNames(vault_entities$slug, paste0(vault_entities$name, " [", vault_entities$type, "]"))
  else
    c("No vault entities found" = "")

  choices <- if (has_queue) {
    queue_choices <- setNames(queue_items$slug, queue_items$name)
    list("Pending queue items" = queue_choices, "Vault entities" = vault_choices)
  } else {
    vault_choices
  }

  modalDialog(
    title = "Merge into Entity",
    size  = "m",
    selectInput("merge_target", "Merge into which entity?",
                choices = choices, selectize = TRUE),
    uiOutput("merge_preview_ui"),
    tags$p(style = "font-size:0.82em;color:#888;margin-top:8px;",
           "Queue target: combines source passages and removes this item. ",
           "Vault target: supplements the existing note and registers an alias."),
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
