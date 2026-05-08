# Run the full pipeline with automatic retry for Ollama timeouts.
# Uses error = "continue" so a single timed-out branch doesn't block the other
# branches from dispatching and consolidating into the review queue.
# After each pass, any errored branches are retried until all succeed or
# max_retries is exhausted.
#
# Usage (from R console in project root):
#   source("scripts/run_pipeline.R")
#   run_pipeline()

run_pipeline <- function(max_retries = 3) {
  for (i in seq_len(max_retries)) {
    targets::tar_make(error = "continue")
    failed <- targets::tar_errored()
    if (length(failed) == 0) break
    message(sprintf(
      "[retry %d/%d] %d branch(es) still errored: %s",
      i, max_retries, length(failed), paste(failed, collapse = ", ")
    ))
  }
  failed <- targets::tar_errored()
  if (length(failed) > 0) {
    warning(sprintf(
      "Pipeline finished with %d unresolved error(s): %s",
      length(failed), paste(failed, collapse = ", ")
    ))
  } else {
    message("Pipeline complete — no errors.")
  }
  invisible(failed)
}
