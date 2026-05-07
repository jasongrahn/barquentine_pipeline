rename_modal_ui <- function(entity_id, entity_name, note_type, vault_path_abs) {
  sub_dir <- switch(note_type,
    npc      = "npcs",
    location = "locations",
    faction  = "factions",
    "npcs"
  )

  modalDialog(
    title = "Confirm name and slug before writing",
    size  = "m",
    tags$p(style = "color:#555;font-size:0.9em;",
           "Review the display name and slug. The slug becomes the filename in the vault."),
    textInput("rename_display_name", "Display name", value = entity_name, width = "100%"),
    tags$div(
      style = "display:flex; align-items:flex-end; gap:8px;",
      tags$div(style = "flex:1;",
        textInput("rename_slug", "Slug (filename)", value = entity_id, width = "100%")
      ),
      tags$div(style = "padding-bottom:15px;",
        actionButton("rename_derive_slug", "Auto-derive", class = "btn-sm btn-outline-secondary")
      )
    ),
    tags$div(
      style = "font-size:0.85em; color:#555; margin-bottom:12px;",
      "Vault path: ",
      tags$code(file.path(sub_dir, paste0("[slug].md")))
    ),
    uiOutput("rename_validation_msg"),
    uiOutput("rename_vault_path_preview"),
    footer = tagList(
      modalButton("Cancel"),
      actionButton("rename_confirm_btn", "Confirm & Write", class = "btn-primary")
    ),
    easyClose = TRUE
  )
}

validate_rename_slug <- function(slug, note_type, vault_path_abs) {
  if (!nzchar(trimws(slug)))
    return("Slug cannot be empty.")
  if (!grepl("^[a-z0-9_-]+$", slug))
    return("Slug must contain only lowercase letters, digits, underscores, and hyphens.")
  sub_dir <- switch(note_type, npc = "npcs", location = "locations",
                    faction = "factions", "npcs")
  target <- file.path(vault_path_abs, sub_dir, paste0(slug, ".md"))
  if (file.exists(target))
    return(paste0("File already exists: ", file.path(sub_dir, paste0(slug, ".md")),
                  " — use Merge to append to an existing entity."))
  NULL
}
