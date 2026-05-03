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

write_note <- function(content, relative_path, dry_run = DRY_RUN, overwrite = FALSE,
                       .dry_run_path = DRY_RUN_PATH,
                       .vault_path   = VAULT_PATH) {
  full_path <- get_output_path(relative_path, dry_run, .dry_run_path, .vault_path)
  if (file_exists(full_path) && !overwrite) {
    stop(
      "File already exists: ", full_path,
      "\nPass overwrite = TRUE to replace it."
    )
  }
  write_file(content, full_path)
  invisible(full_path)
}

note_exists <- function(relative_path, dry_run = DRY_RUN,
                        .dry_run_path = DRY_RUN_PATH,
                        .vault_path   = VAULT_PATH) {
  isTRUE(file_exists(get_output_path(relative_path, dry_run, .dry_run_path, .vault_path)))
}
