library(jsonlite)
library(fs)
library(readr)

# Writes one SFT (supervised fine-tuning) training pair as a JSONL record.
# Called after auto-approve or reviewer acceptance with no edits.
write_sft <- function(section_id, prompt, completion,
                      .path = TRAINING_DATA_PATH) {
  dir_create(.path, recurse = TRUE)
  record <- toJSON(list(
    type       = "sft",
    section_id = section_id,
    prompt     = prompt,
    completion = completion,
    created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  ), auto_unbox = TRUE)
  cat(record, "\n", sep = "",
      file = file.path(.path, "sft.jsonl"), append = TRUE)
  invisible(section_id)
}

# Writes one DPO (direct preference optimisation) pair.
# chosen  = the human-edited (accepted) draft
# rejected = the original model-generated draft
write_dpo <- function(section_id, prompt, chosen, rejected,
                      .path = TRAINING_DATA_PATH) {
  dir_create(.path, recurse = TRUE)
  record <- toJSON(list(
    type       = "dpo",
    section_id = section_id,
    prompt     = prompt,
    chosen     = chosen,
    rejected   = rejected,
    created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  ), auto_unbox = TRUE)
  cat(record, "\n", sep = "",
      file = file.path(.path, "dpo.jsonl"), append = TRUE)
  invisible(section_id)
}

# Writes one negative example (a draft the reviewer rejected outright).
write_negative <- function(section_id, prompt, draft, reject_reason = NULL,
                           .path = TRAINING_DATA_PATH) {
  dir_create(.path, recurse = TRUE)
  record_list <- list(
    type       = "negative",
    section_id = section_id,
    prompt     = prompt,
    draft      = draft,
    created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  )
  if (!is.null(reject_reason) && nzchar(trimws(reject_reason))) {
    record_list$reject_reason <- trimws(reject_reason)
  }
  record <- toJSON(record_list, auto_unbox = TRUE)
  cat(record, "\n", sep = "",
      file = file.path(.path, "negatives.jsonl"), append = TRUE)
  invisible(section_id)
}

# Walks an iteration_log (list of per-iteration records) and writes intermediate
# DPO pairs (when a revision improved confidence) or negative examples (when it
# stayed flat or dropped). Returns the count of training records written.
write_intermediate_pairs_from_log <- function(section_id, prompt, iteration_log,
                                               .path = TRAINING_DATA_PATH) {
  if (!is.list(iteration_log) || length(iteration_log) < 2L) return(invisible(0L))

  count <- 0L
  for (i in seq_len(length(iteration_log) - 1L)) {
    prev <- iteration_log[[i]]
    nxt  <- iteration_log[[i + 1L]]

    prev_draft <- prev$draft
    nxt_draft  <- nxt$draft
    prev_conf  <- prev$confidence
    nxt_conf   <- nxt$confidence

    if (is.null(prev_draft) || is.null(nxt_draft)) next
    if (length(prev_draft) == 0L || length(nxt_draft) == 0L) next
    if (is.na(prev_draft) || is.na(nxt_draft))               next
    if (!nzchar(prev_draft) || !nzchar(nxt_draft))           next
    if (identical(prev_draft, nxt_draft))                    next
    if (is.null(prev_conf) || is.null(nxt_conf))             next
    if (is.na(prev_conf)  || is.na(nxt_conf))                next

    if (nxt_conf > prev_conf) {
      write_dpo(section_id, prompt, chosen = nxt_draft, rejected = prev_draft,
                .path = .path)
    } else {
      write_negative(section_id, prompt, draft = nxt_draft,
                     reject_reason = "revision_did_not_improve",
                     .path = .path)
    }
    count <- count + 1L
  }
  invisible(count)
}

# Reads all resolved, not-yet-exported queue items and writes training pairs.
# Returns the count of items exported.
generate_training_data <- function(.queue_path    = REVIEW_QUEUE_PATH,
                                   .training_path = TRAINING_DATA_PATH) {
  csv_path <- file.path(.queue_path, "queue.csv")
  if (!file_exists(csv_path)) return(invisible(0L))

  df  <- read_csv(csv_path, show_col_types = FALSE)
  resolved_statuses <- c("accepted", "accepted_with_edit", "rejected")
  rows <- df[df$status %in% resolved_statuses &
               !isTRUE(df$training_exported), ]
  if (nrow(rows) == 0) return(invisible(0L))

  for (i in seq_len(nrow(rows))) {
    row <- rows[i, ]
    sid    <- row$section_id
    draft  <- if (is.na(row$draft)) "" else row$draft

    prompt_file <- file.path(.queue_path, "prompts", paste0(sid, ".txt"))
    prompt <- if (file_exists(prompt_file)) {
      paste(readLines(prompt_file, warn = FALSE), collapse = "\n")
    } else ""

    if (row$status == "accepted") {
      write_sft(sid, prompt, draft, .path = .training_path)
    } else if (row$status == "accepted_with_edit") {
      chosen <- if (is.na(row$final_draft)) draft else row$final_draft
      write_dpo(sid, prompt, chosen = chosen, rejected = draft,
                .path = .training_path)
    } else {
      reason <- if ("reject_reason" %in% names(row) && !is.na(row$reject_reason))
        row$reject_reason else NULL
      write_negative(sid, prompt, draft, reject_reason = reason, .path = .training_path)
    }

    # Walk iteration_log for intermediate revision pairs (Phase 3.1).
    iter_log <- if ("iteration_log" %in% names(row) && !is.na(row$iteration_log))
      tryCatch(fromJSON(as.character(row$iteration_log), simplifyVector = FALSE),
               error = function(e) NULL) else NULL
    if (!is.null(iter_log) && length(iter_log) >= 2L) {
      write_intermediate_pairs_from_log(sid, prompt, iter_log,
                                         .path = .training_path)
    }

    df$training_exported[df$section_id == sid] <- TRUE
  }

  write_csv(df, csv_path)
  invisible(nrow(rows))
}
