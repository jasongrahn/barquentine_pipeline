library(readr)
library(jsonlite)
library(fs)

.queue_csv_path <- function(.queue_path) {
  file.path(.queue_path, "queue.csv")
}

.staging_file_path <- function(section_id, .queue_path) {
  file.path(.queue_path, "staging", paste0(section_id, ".csv"))
}

.fill_missing_columns <- function(df) {
  defaults <- list(
    note_type          = NA_character_,
    entity_name        = NA_character_,
    chunk_count        = NA_integer_,
    source_episode_ids = NA_character_,
    status_detail      = NA_character_,
    merged_into        = NA_character_,
    last_action_at     = NA_character_
  )
  for (col in names(defaults)) {
    if (!col %in% names(df)) df[[col]] <- defaults[[col]]
  }
  df
}

enqueue_review <- function(draft, verdict_list, section_id, source_text,
                           prompt             = NULL,
                           note_type          = NA_character_,
                           entity_name        = NA_character_,
                           chunk_count        = NA_integer_,
                           source_episode_ids = NA_character_,
                           status             = "pending",
                           .queue_path        = REVIEW_QUEUE_PATH) {
  dir_create(file.path(.queue_path, "staging"), recurse = TRUE)

  if (!is.null(prompt)) {
    prompt_dir <- file.path(.queue_path, "prompts")
    dir_create(prompt_dir, recurse = TRUE)
    writeLines(prompt, file.path(prompt_dir, paste0(section_id, ".txt")))
  }

  row <- data.frame(
    section_id         = as.character(section_id)[[1]],
    status             = status,
    training_exported  = FALSE,
    draft              = if (is.null(draft) || (length(draft) == 1 && is.na(draft)))
                           NA_character_ else as.character(draft)[[1]],
    final_draft        = NA_character_,
    source_text        = as.character(source_text)[[1]],
    verdict            = verdict_list$verdict,
    confidence         = if (is.null(verdict_list$confidence)) NA_real_
                           else verdict_list$confidence,
    issues             = toJSON(if (is.null(verdict_list$issues)) list()
                                else verdict_list$issues, auto_unbox = TRUE),
    source_quotes      = toJSON(if (is.null(verdict_list$source_quotes)) list()
                                else verdict_list$source_quotes, auto_unbox = TRUE),
    escalated          = isTRUE(verdict_list$escalated),
    claude_verdict     = if (is.null(verdict_list$claude_verdict)) NA_character_
                           else verdict_list$claude_verdict,
    enqueued_at        = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
    resolved_at        = NA_character_,
    note_type          = if (length(note_type) == 1 && is.na(note_type)) NA_character_
                           else as.character(note_type),
    entity_name        = if (length(entity_name) == 1 && is.na(entity_name)) NA_character_
                           else as.character(entity_name),
    chunk_count        = if (length(chunk_count) == 1 && is.na(chunk_count)) NA_integer_
                           else as.integer(chunk_count),
    source_episode_ids = if (length(source_episode_ids) == 1 && is.na(source_episode_ids))
                           NA_character_ else as.character(source_episode_ids),
    status_detail      = NA_character_,
    merged_into        = NA_character_,
    last_action_at     = NA_character_,
    stringsAsFactors   = FALSE
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
    existing <- .fill_missing_columns(existing)
    existing <- existing[!existing$section_id %in% new_rows$section_id, ]
    combined <- rbind(existing, .fill_missing_columns(new_rows))
  } else {
    combined <- .fill_missing_columns(new_rows)
  }

  dir_create(.queue_path, recurse = TRUE)
  write_csv(combined, csv_path)
  file_delete(staging_files)
  invisible(nrow(new_rows))
}

read_queue <- function(.queue_path = REVIEW_QUEUE_PATH, status = "pending") {
  csv_path <- .queue_csv_path(.queue_path)
  if (!file_exists(csv_path)) {
    return(data.frame(
      section_id = character(), status = character(),
      training_exported = logical(), draft = character(),
      final_draft = character(), source_text = character(),
      verdict = character(), confidence = numeric(),
      issues = character(), source_quotes = character(),
      escalated = logical(), claude_verdict = character(),
      enqueued_at = character(), resolved_at = character(),
      note_type = character(), entity_name = character(),
      chunk_count = integer(), source_episode_ids = character(),
      status_detail = character(), merged_into = character(),
      last_action_at = character(), stringsAsFactors = FALSE
    ))
  }
  df <- read_csv(csv_path, show_col_types = FALSE)
  df <- .fill_missing_columns(df)
  if (!is.null(status)) df <- df[df$status %in% status, ]
  df
}

resolve_item <- function(section_id, resolution, edited_draft = NULL,
                         status_detail = NULL, merged_into = NULL,
                         .queue_path = REVIEW_QUEUE_PATH) {
  VALID_RESOLUTIONS <- c(
    "accepted", "accepted_with_edit", "rejected",
    "snoozed", "merged",
    "rejected_garbage", "rejected_duplicate",
    "rejected_not_an_entity", "rejected_out_of_scope"
  )
  stopifnot(resolution %in% VALID_RESOLUTIONS)

  csv_path <- .queue_csv_path(.queue_path)
  df  <- read_csv(csv_path, show_col_types = FALSE)
  df  <- .fill_missing_columns(df)
  idx <- which(df$section_id == section_id)
  if (length(idx) == 0) stop("section_id not found in queue: ", section_id)

  now <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  df$status[idx]          <- resolution
  df$resolved_at[idx]     <- now
  df$last_action_at[idx]  <- now
  if (!is.null(edited_draft)) df$final_draft[idx]    <- edited_draft
  if (!is.null(status_detail)) df$status_detail[idx] <- status_detail
  if (!is.null(merged_into))  df$merged_into[idx]    <- merged_into

  write_csv(df, csv_path)
  invisible(resolution)
}

update_draft <- function(section_id, new_draft, new_verdict_list = NULL,
                          .queue_path = REVIEW_QUEUE_PATH) {
  csv_path <- .queue_csv_path(.queue_path)
  df  <- read_csv(csv_path, show_col_types = FALSE)
  df  <- .fill_missing_columns(df)
  idx <- which(df$section_id == section_id)
  if (length(idx) == 0) stop("section_id not found in queue: ", section_id)

  now <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  df$draft[idx]          <- new_draft
  df$status[idx]         <- "pending"
  df$last_action_at[idx] <- now

  if (!is.null(new_verdict_list)) {
    df$verdict[idx]    <- new_verdict_list$verdict
    df$confidence[idx] <- new_verdict_list$confidence
    df$issues[idx]     <- toJSON(if (is.null(new_verdict_list$issues)) list()
                                  else new_verdict_list$issues, auto_unbox = TRUE)
    df$source_quotes[idx] <- toJSON(if (is.null(new_verdict_list$source_quotes)) list()
                                     else new_verdict_list$source_quotes, auto_unbox = TRUE)
  }

  write_csv(df, csv_path)
  invisible(section_id)
}

revert_to_pending <- function(section_id, prior_draft = NULL,
                               .queue_path = REVIEW_QUEUE_PATH) {
  csv_path <- .queue_csv_path(.queue_path)
  df  <- read_csv(csv_path, show_col_types = FALSE)
  df  <- .fill_missing_columns(df)
  idx <- which(df$section_id == section_id)
  if (length(idx) == 0) stop("section_id not found: ", section_id)

  now <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  df$status[idx]         <- "pending"
  df$resolved_at[idx]    <- NA_character_
  df$last_action_at[idx] <- now
  if (!is.null(prior_draft)) df$draft[idx] <- prior_draft

  write_csv(df, csv_path)
  invisible(section_id)
}

