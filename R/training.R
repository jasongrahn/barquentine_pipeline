library(jsonlite)
library(fs)

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
write_negative <- function(section_id, prompt, draft,
                           .path = TRAINING_DATA_PATH) {
  dir_create(.path, recurse = TRUE)
  record <- toJSON(list(
    type       = "negative",
    section_id = section_id,
    prompt     = prompt,
    draft      = draft,
    created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  ), auto_unbox = TRUE)
  cat(record, "\n", sep = "",
      file = file.path(.path, "negatives.jsonl"), append = TRUE)
  invisible(section_id)
}
