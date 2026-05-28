library(fs)
library(readr)

# .dry_run_path and .vault_path are test injection points — production code
# always receives these from config.R via their defaults.
get_output_path <- function(relative_path, dry_run = DRY_RUN,
                            .dry_run_path = DRY_RUN_PATH,
                            .vault_path   = VAULT_PATH) {
  base      <- if (dry_run) .dry_run_path else .vault_path
  full_path <- file.path(base, relative_path)
  dir_create(dirname(full_path))
  full_path
}

# Infer note_type from the vault subdirectory and, for npcs/, frontmatter tags.
# Returns NULL for unrecognised paths (e.g. dm_prep/) — validation is skipped.
.infer_note_type <- function(relative_path, content) {
  dir_part <- basename(dirname(relative_path))
  if (dir_part == "npcs") {
    if (grepl("tags:\\s*\\[pc\\]", content, perl = TRUE)) return("pc")
    return("npc")
  }
  switch(dir_part,
    locations = "location",
    factions  = "faction",
    sessions  = "session",
    NULL
  )
}

write_note <- function(content, relative_path, dry_run = DRY_RUN, overwrite = FALSE,
                       .dry_run_path = DRY_RUN_PATH,
                       .vault_path   = VAULT_PATH) {
  full_path <- get_output_path(relative_path, dry_run, .dry_run_path, .vault_path)

  # Pre-write format validation — fires only when validator.R is loaded.
  if (exists("validate_note_format", mode = "function")) {
    note_type <- .infer_note_type(relative_path, content)
    if (!is.null(note_type)) {
      vr <- validate_note_format(content, note_type)
      if (!vr$valid)
        warning("[format-warn] pre-write (", relative_path, "): ",
                paste(vr$issues, collapse = "; "))
    }
  }

  if (file_exists(full_path)) {
    if (identical(read_file(full_path), content)) return(invisible(full_path))
    if (!overwrite) stop("File already exists: ", full_path, "\nPass overwrite = TRUE to replace it.")
  }
  write_file(content, full_path)

  # Post-write validation — confirms on-disk content matches expectations.
  if (exists("validate_note_format", mode = "function")) {
    note_type <- .infer_note_type(relative_path, content)
    if (!is.null(note_type)) {
      on_disk <- tryCatch(read_file(full_path), error = function(e) NULL)
      if (!is.null(on_disk)) {
        vr2 <- validate_note_format(on_disk, note_type)
        if (!vr2$valid)
          message("[format-warn] post-write (", relative_path, "): ",
                  paste(vr2$issues, collapse = "; "))
      }
    }
  }

  invisible(full_path)
}

write_placeholder_note <- function(session_id, dry_run = DRY_RUN,
                                   .dry_run_path = DRY_RUN_PATH,
                                   .vault_path   = VAULT_PATH) {
  content <- paste0(
    "---\ntype: session_note\nsession: ", session_id, "\ngap: true\n---\n\n",
    "No session notes available for ", session_id, ".\n"
  )
  relative_path <- file.path("sessions", paste0(session_id, ".md"))
  write_note(content, relative_path, dry_run = dry_run, overwrite = FALSE,
             .dry_run_path = .dry_run_path, .vault_path = .vault_path)
}

note_exists <- function(relative_path, dry_run = DRY_RUN,
                        .dry_run_path = DRY_RUN_PATH,
                        .vault_path   = VAULT_PATH) {
  isTRUE(file_exists(get_output_path(relative_path, dry_run, .dry_run_path, .vault_path)))
}
