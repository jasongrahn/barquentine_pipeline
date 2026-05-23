library(gert)
library(glue)

commit_vault <- function(session_id, vault_path = VAULT_PATH,
                         dry_run = DRY_RUN) {
  commit_message <- glue("Session {session_id} \u2014 auto-generated [{Sys.Date()}]")

  if (dry_run) {
    message("DRY RUN \u2014 would commit vault with message: ", commit_message)
    return(invisible(NULL))
  }

  all_files <- git_status(repo = vault_path)$file
  note_files <- all_files[!grepl("^\\.obsidian/", all_files)]
  if (length(note_files) == 0) {
    message("vault_commit: nothing to stage (all notes queued for review)")
    return(invisible(NULL))
  }
  git_add(note_files, repo = vault_path)

  staged <- git_status(repo = vault_path)
  staged <- staged[staged$staged, ]
  if (nrow(staged) == 0) {
    message("vault_commit: nothing to commit after staging")
    return(invisible(NULL))
  }

  note_dirs <- paste0("^(sessions|npcs|locations|factions|dm_prep)/")
  if (!any(grepl(note_dirs, staged$file))) {
    stop("vault_commit: staged files contain no note paths — check writer output")
  }

  hash <- git_commit(commit_message, repo = vault_path)
  invisible(hash)
}
