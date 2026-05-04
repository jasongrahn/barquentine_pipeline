library(glue)
library(fs)
library(readr)

REVIEW_LOG_HEADER <- "# Review Log\n\nItems flagged for DM attention. Check off each item after resolving.\n"

format_review_entry <- function(note_path, reason, run_date = Sys.Date(),
                                verdict = NULL) {
  verdict_tag <- if (!is.null(verdict)) paste0(" [", verdict, "]") else ""
  glue("- [ ] [[{note_path}]]{verdict_tag} \u2014 {reason} ({run_date})")
}

append_review_entry <- function(entry, vault_path = VAULT_PATH,
                                dry_run = DRY_RUN) {
  log_path <- .review_log_path(vault_path, dry_run)
  .ensure_review_log(log_path)
  write_file(paste0(entry, "\n"), log_path, append = TRUE)
  invisible(log_path)
}

write_run_header <- function(session_id, vault_path = VAULT_PATH,
                             dry_run = DRY_RUN) {
  log_path <- .review_log_path(vault_path, dry_run)
  .ensure_review_log(log_path)
  write_file(glue("\n## Run: {Sys.Date()} (after {session_id})\n"),
             log_path, append = TRUE)
  invisible(log_path)
}

# Internal: resolve the review log path, honouring dry_run
.review_log_path <- function(vault_path, dry_run) {
  base <- if (dry_run) DRY_RUN_PATH else vault_path
  file.path(base, "review", "review_log.md")
}

# Internal: create review_log.md with a minimal header if absent
.ensure_review_log <- function(log_path) {
  if (!file_exists(log_path)) {
    dir_create(dirname(log_path))
    write_file(REVIEW_LOG_HEADER, log_path)
  }
}
