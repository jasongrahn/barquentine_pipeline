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
# chosen  = the preferred draft (human edit, post-revision Ollama, or Claude revision)
# rejected = the dispreferred draft (original or pre-revision)
# source  = optional provenance tag, e.g., "human_edit", "intermediate",
#           "claude_escalation"; written into the JSON when supplied so
#           downstream fine-tuning can weight or filter pair sources separately.
write_dpo <- function(section_id, prompt, chosen, rejected,
                      source = NULL,
                      .path = TRAINING_DATA_PATH) {
  dir_create(.path, recurse = TRUE)
  record_list <- list(
    type       = "dpo",
    section_id = section_id,
    prompt     = prompt,
    chosen     = chosen,
    rejected   = rejected,
    created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  )
  if (!is.null(source) && length(source) == 1L && !is.na(source) &&
      nzchar(trimws(source))) {
    record_list$source <- trimws(source)
  }
  record <- toJSON(record_list, auto_unbox = TRUE)
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

.entry_has_usable_draft <- function(e) {
  d <- e$draft
  !is.null(d) && length(d) == 1L && !is.na(d) &&
    is.character(d) && nzchar(d)
}

.entry_has_confidence <- function(e) {
  c <- e$confidence
  !is.null(c) && length(c) == 1L && !is.na(c)
}

.is_cap_hit_entry <- function(e) {
  r <- e$escalation_reason
  !is.null(r) && length(r) == 1L && !is.na(r) &&
    identical(as.character(r), "cap_hit")
}

# Walks an iteration_log (list of per-iteration records) and writes intermediate
# DPO pairs (when a revision improved confidence), negative examples (when a
# revision stayed flat or dropped), and a Claude-escalation DPO pair when a
# cap-hit Claude revision produced a different draft from the best Ollama draft.
# Returns the count of training records written.
write_intermediate_pairs_from_log <- function(section_id, prompt, iteration_log,
                                               .path = TRAINING_DATA_PATH) {
  if (!is.list(iteration_log) || length(iteration_log) < 2L) return(invisible(0L))

  cap_indices <- which(vapply(iteration_log, .is_cap_hit_entry, logical(1)))
  cap_idx     <- if (length(cap_indices) > 0L) cap_indices[length(cap_indices)] else 0L

  count <- 0L

  # Phase 3.1 — pairwise walk over pre-cap (Ollama) iterations.
  ollama_upper <- if (cap_idx > 0L) cap_idx - 1L else length(iteration_log)
  if (ollama_upper >= 2L) {
    for (i in seq_len(ollama_upper - 1L)) {
      prev <- iteration_log[[i]]
      nxt  <- iteration_log[[i + 1L]]

      if (!.entry_has_usable_draft(prev) || !.entry_has_usable_draft(nxt)) next
      if (identical(prev$draft, nxt$draft)) next
      if (!.entry_has_confidence(prev) || !.entry_has_confidence(nxt)) next

      if (nxt$confidence > prev$confidence) {
        write_dpo(section_id, prompt, chosen = nxt$draft, rejected = prev$draft,
                  source = "intermediate", .path = .path)
      } else {
        write_negative(section_id, prompt, draft = nxt$draft,
                       reject_reason = "revision_did_not_improve",
                       .path = .path)
      }
      count <- count + 1L
    }
  }

  # Phase 3.2 — Claude cap-hit revision pair, if Claude produced a new draft.
  if (cap_idx > 0L && cap_idx >= 2L) {
    claude_entry   <- iteration_log[[cap_idx]]
    ollama_entries <- iteration_log[seq_len(cap_idx - 1L)]
    if (.entry_has_usable_draft(claude_entry) && length(ollama_entries) > 0L) {
      # Best Ollama draft = highest-confidence prior draft (mirrors best_draft logic
      # in draft_with_refinement). Tie-break: latest iteration wins.
      confidences <- vapply(ollama_entries, function(e) {
        if (.entry_has_confidence(e)) as.numeric(e$confidence) else -Inf
      }, numeric(1))
      have_draft <- vapply(ollama_entries, .entry_has_usable_draft, logical(1))
      eligible   <- which(have_draft & is.finite(confidences))
      if (length(eligible) > 0L) {
        best_local_idx <- eligible[which.max(confidences[eligible])]
        best_ollama    <- ollama_entries[[best_local_idx]]
        if (!identical(best_ollama$draft, claude_entry$draft)) {
          write_dpo(section_id, prompt,
                    chosen = claude_entry$draft, rejected = best_ollama$draft,
                    source = "claude_escalation", .path = .path)
          count <- count + 1L
        }
      }
    }
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
  exported <- df$training_exported
  exported[is.na(exported)] <- FALSE
  rows <- df[df$status %in% resolved_statuses & !exported, ]
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
                source = "human_edit", .path = .training_path)
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

# Curates a few-shot pool from accepted, high-confidence training records.
# Cross-references sft.jsonl (the prompt/completion pairs written by
# generate_training_data on accepted items) with queue.csv (which holds the
# critic confidence for each section) and writes the most recent N qualifying
# records to a separate JSONL file. The resulting pool can be supplied as
# in-prompt few-shot examples by a generation prompt builder.
# Returns the count of records written.
refresh_few_shots <- function(n = 10L,
                               confidence_threshold = 0.85,
                               .queue_path     = REVIEW_QUEUE_PATH,
                               .training_path  = TRAINING_DATA_PATH,
                               output_filename = "few_shots_pool.jsonl") {
  sft_path <- file.path(.training_path, "sft.jsonl")
  csv_path <- file.path(.queue_path,    "queue.csv")
  if (!file_exists(sft_path)) return(invisible(0L))
  if (!file_exists(csv_path)) return(invisible(0L))

  sft_lines <- readLines(sft_path, warn = FALSE)
  sft_lines <- sft_lines[nzchar(sft_lines)]
  if (length(sft_lines) == 0L) return(invisible(0L))

  sft_records <- lapply(sft_lines, function(ln)
    tryCatch(fromJSON(ln, simplifyVector = FALSE), error = function(e) NULL))
  sft_records <- Filter(function(r)
    !is.null(r) && !is.null(r$section_id) &&
      !is.null(r$prompt) && !is.null(r$completion),
    sft_records)
  if (length(sft_records) == 0L) return(invisible(0L))

  q <- read_csv(csv_path, show_col_types = FALSE)
  conf_lookup <- function(sid) {
    idx <- which(q$section_id == sid)
    if (length(idx) == 0L) return(NA_real_)
    as.numeric(q$confidence[idx[1L]])
  }

  qualified <- Filter(function(r) {
    conf <- conf_lookup(r$section_id)
    !is.na(conf) && conf >= confidence_threshold
  }, sft_records)
  if (length(qualified) == 0L) {
    out_path <- file.path(.training_path, output_filename)
    if (file_exists(out_path)) file_delete(out_path)
    dir_create(.training_path, recurse = TRUE)
    file.create(out_path)
    return(invisible(0L))
  }

  ts <- vapply(qualified, function(r)
    if (!is.null(r$created_at)) as.character(r$created_at) else "",
    character(1))
  qualified <- qualified[order(ts, decreasing = TRUE)]
  qualified <- head(qualified, as.integer(n))

  dir_create(.training_path, recurse = TRUE)
  out_path <- file.path(.training_path, output_filename)
  if (file_exists(out_path)) file_delete(out_path)
  for (r in qualified) {
    cat(toJSON(r, auto_unbox = TRUE), "\n", sep = "",
        file = out_path, append = TRUE)
  }

  invisible(length(qualified))
}
