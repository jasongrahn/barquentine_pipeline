library(gert)
library(glue)

commit_vault <- function(session_id, vault_path = VAULT_PATH,
                         dry_run = DRY_RUN) {
  commit_message <- glue("Session {session_id} \u2014 auto-generated [{Sys.Date()}]")

  if (dry_run) {
    message("DRY RUN \u2014 would commit vault with message: ", commit_message)
    return(invisible(NULL))
  }

  git_add(".", repo = vault_path)
  staged <- git_status(repo = vault_path)
  staged <- staged[staged$staged, ]
  if (nrow(staged) == 0) {
    message("vault_commit: nothing to commit (all notes queued for review)")
    return(invisible(NULL))
  }
  hash <- git_commit(commit_message, repo = vault_path)
  invisible(hash)
}
