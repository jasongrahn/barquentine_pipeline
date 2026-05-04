library(readr)
library(jsonlite)
library(fs)

.queue_csv_path <- function(.queue_path) {
  file.path(.queue_path, "queue.csv")
}

.staging_file_path <- function(section_id, .queue_path) {
  file.path(.queue_path, "staging", paste0(section_id, ".csv"))
}

enqueue_review <- function(draft, verdict_list, section_id, source_text,
                           .queue_path = REVIEW_QUEUE_PATH) {
  dir_create(file.path(.queue_path, "staging"), recurse = TRUE)

  row <- data.frame(
    section_id    = section_id,
    status        = "pending",
    draft         = if (is.null(draft)) NA_character_ else draft,
    final_draft   = NA_character_,
    source_text   = source_text,
    verdict       = verdict_list$verdict,
    confidence    = if (is.null(verdict_list$confidence)) NA_real_ else verdict_list$confidence,
    issues        = toJSON(if (is.null(verdict_list$issues)) list() else verdict_list$issues,
                           auto_unbox = TRUE),
    source_quotes = toJSON(if (is.null(verdict_list$source_quotes)) list() else verdict_list$source_quotes,
                           auto_unbox = TRUE),
    escalated     = isTRUE(verdict_list$escalated),
    claude_verdict = if (is.null(verdict_list$claude_verdict)) NA_character_ else verdict_list$claude_verdict,
    enqueued_at   = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
    resolved_at   = NA_character_,
    stringsAsFactors = FALSE
  )

  write_csv(row, .staging_file_path(section_id, .queue_path))
  invisible(section_id)
}

consolidate_queue <- function(.queue_path = REVIEW_QUEUE_PATH) {
  staging_dir   <- file.path(.queue_path, "staging")
  staging_files <- dir_ls(staging_dir, glob = "*.csv")
  if (length(staging_files) == 0) return(invisible(0L))

  new_rows <- do.call(rbind, lapply(staging_files, read_csv, show_col_types = FALSE))

  csv_path <- .queue_csv_path(.queue_path)
  if (file_exists(csv_path)) {
    existing <- read_csv(csv_path, show_col_types = FALSE)
    # Re-enqueue replaces existing rows for the same section_id
    existing <- existing[!existing$section_id %in% new_rows$section_id, ]
    combined <- rbind(existing, new_rows)
  } else {
    combined <- new_rows
  }

  dir_create(.queue_path, recurse = TRUE)
  write_csv(combined, csv_path)
  file_delete(staging_files)
  invisible(nrow(new_rows))
}

read_queue <- function(.queue_path = REVIEW_QUEUE_PATH, status = "pending") {
  csv_path <- .queue_csv_path(.queue_path)
  if (!file_exists(csv_path)) {
    return(data.frame(section_id = character(), status = character(),
                      draft = character(), final_draft = character(),
                      source_text = character(), verdict = character(),
                      confidence = numeric(), issues = character(),
                      source_quotes = character(), escalated = logical(),
                      claude_verdict = character(), enqueued_at = character(),
                      resolved_at = character(), stringsAsFactors = FALSE))
  }
  df <- read_csv(csv_path, show_col_types = FALSE)
  if (!is.null(status)) df <- df[df$status %in% status, ]
  df
}

resolve_item <- function(section_id, resolution, edited_draft = NULL,
                         .queue_path = REVIEW_QUEUE_PATH) {
  stopifnot(resolution %in% c("accepted", "accepted_with_edit", "rejected"))

  csv_path <- .queue_csv_path(.queue_path)
  df  <- read_csv(csv_path, show_col_types = FALSE)
  idx <- which(df$section_id == section_id)
  if (length(idx) == 0) stop("section_id not found in queue: ", section_id)

  df$status[idx]     <- resolution
  df$resolved_at[idx] <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  if (!is.null(edited_draft)) df$final_draft[idx] <- edited_draft

  write_csv(df, csv_path)
  invisible(resolution)
}
