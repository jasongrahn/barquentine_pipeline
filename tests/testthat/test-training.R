library(testthat)
library(withr)
library(jsonlite)

source(test_path("../../config.R"))
source(test_path("../../R/queue.R"))
source(test_path("../../R/training.R"))

read_jsonl <- function(path) {
  lines <- readLines(path)
  lapply(lines[nzchar(lines)], function(l) fromJSON(l, simplifyVector = FALSE))
}

# --- write_sft() -------------------------------------------------------------

test_that("write_sft creates sft.jsonl", {
  tmp <- local_tempdir()
  write_sft("S2e10", "prompt text", "completion text", .path = tmp)
  expect_true(file.exists(file.path(tmp, "sft.jsonl")))
})

test_that("write_sft record has correct fields", {
  tmp    <- local_tempdir()
  write_sft("S2e10", "p", "c", .path = tmp)
  record <- read_jsonl(file.path(tmp, "sft.jsonl"))[[1]]
  expect_equal(record$type,       "sft")
  expect_equal(record$section_id, "S2e10")
  expect_equal(record$prompt,     "p")
  expect_equal(record$completion, "c")
  expect_false(is.null(record$created_at))
})

test_that("write_sft appends without overwriting", {
  tmp <- local_tempdir()
  write_sft("S2e10", "p1", "c1", .path = tmp)
  write_sft("S2e11", "p2", "c2", .path = tmp)
  records <- read_jsonl(file.path(tmp, "sft.jsonl"))
  expect_length(records, 2L)
  expect_equal(records[[1]]$section_id, "S2e10")
  expect_equal(records[[2]]$section_id, "S2e11")
})

test_that("write_sft returns section_id invisibly", {
  tmp    <- local_tempdir()
  result <- withVisible(write_sft("S2e10", "p", "c", .path = tmp))
  expect_false(result$visible)
  expect_equal(result$value, "S2e10")
})

test_that("write_sft creates directory if absent", {
  tmp <- local_tempdir()
  write_sft("S2e10", "p", "c", .path = file.path(tmp, "new_dir"))
  expect_true(dir.exists(file.path(tmp, "new_dir")))
})

# --- write_dpo() -------------------------------------------------------------

test_that("write_dpo creates dpo.jsonl", {
  tmp <- local_tempdir()
  write_dpo("S2e10", "prompt", "chosen", "rejected", .path = tmp)
  expect_true(file.exists(file.path(tmp, "dpo.jsonl")))
})

test_that("write_dpo record has correct fields", {
  tmp    <- local_tempdir()
  write_dpo("S2e10", "p", "ch", "rej", .path = tmp)
  record <- read_jsonl(file.path(tmp, "dpo.jsonl"))[[1]]
  expect_equal(record$type,       "dpo")
  expect_equal(record$section_id, "S2e10")
  expect_equal(record$prompt,     "p")
  expect_equal(record$chosen,     "ch")
  expect_equal(record$rejected,   "rej")
})

test_that("write_dpo appends multiple records", {
  tmp <- local_tempdir()
  write_dpo("S2e10", "p", "ch1", "rej1", .path = tmp)
  write_dpo("S2e11", "p", "ch2", "rej2", .path = tmp)
  records <- read_jsonl(file.path(tmp, "dpo.jsonl"))
  expect_length(records, 2L)
})

test_that("write_dpo returns section_id invisibly", {
  tmp    <- local_tempdir()
  result <- withVisible(write_dpo("S2e10", "p", "ch", "rej", .path = tmp))
  expect_false(result$visible)
  expect_equal(result$value, "S2e10")
})

# --- write_negative() --------------------------------------------------------

test_that("write_negative creates negatives.jsonl", {
  tmp <- local_tempdir()
  write_negative("S2e10", "prompt", "bad draft", .path = tmp)
  expect_true(file.exists(file.path(tmp, "negatives.jsonl")))
})

test_that("write_negative record has correct fields", {
  tmp    <- local_tempdir()
  write_negative("S2e10", "p", "draft", .path = tmp)
  record <- read_jsonl(file.path(tmp, "negatives.jsonl"))[[1]]
  expect_equal(record$type,       "negative")
  expect_equal(record$section_id, "S2e10")
  expect_equal(record$prompt,     "p")
  expect_equal(record$draft,      "draft")
})

test_that("write_negative appends multiple records", {
  tmp <- local_tempdir()
  write_negative("S2e10", "p", "d1", .path = tmp)
  write_negative("S2e11", "p", "d2", .path = tmp)
  records <- read_jsonl(file.path(tmp, "negatives.jsonl"))
  expect_length(records, 2L)
})

test_that("write_negative returns section_id invisibly", {
  tmp    <- local_tempdir()
  result <- withVisible(write_negative("S2e10", "p", "d", .path = tmp))
  expect_false(result$visible)
  expect_equal(result$value, "S2e10")
})

test_that("sft and dpo write to separate files", {
  tmp <- local_tempdir()
  write_sft("S2e10",      "p", "c",          .path = tmp)
  write_dpo("S2e10",      "p", "ch", "rej",  .path = tmp)
  write_negative("S2e10", "p", "d",           .path = tmp)
  expect_true(file.exists(file.path(tmp, "sft.jsonl")))
  expect_true(file.exists(file.path(tmp, "dpo.jsonl")))
  expect_true(file.exists(file.path(tmp, "negatives.jsonl")))
})

# --- generate_training_data() ------------------------------------------------

make_verdict_list <- function(verdict = "flagged", confidence = 0.7) {
  list(verdict = verdict, confidence = confidence,
       issues = list("issue"), source_quotes = list("quote"))
}

test_that("generate_training_data returns 0 when queue.csv absent", {
  tmp_q <- local_tempdir()
  tmp_t <- local_tempdir()
  n <- generate_training_data(.queue_path = tmp_q, .training_path = tmp_t)
  expect_equal(n, 0L)
})

test_that("generate_training_data writes SFT for accepted item", {
  tmp_q <- local_tempdir()
  tmp_t <- local_tempdir()
  enqueue_review("draft", make_verdict_list(), "S2e10", "src", .queue_path = tmp_q)
  consolidate_queue(.queue_path = tmp_q)
  resolve_item("S2e10", "accepted", .queue_path = tmp_q)
  generate_training_data(.queue_path = tmp_q, .training_path = tmp_t)
  expect_true(file.exists(file.path(tmp_t, "sft.jsonl")))
})

test_that("generate_training_data writes DPO for accepted_with_edit", {
  tmp_q <- local_tempdir()
  tmp_t <- local_tempdir()
  enqueue_review("original", make_verdict_list(), "S2e10", "src", .queue_path = tmp_q)
  consolidate_queue(.queue_path = tmp_q)
  resolve_item("S2e10", "accepted_with_edit", edited_draft = "edited",
               .queue_path = tmp_q)
  generate_training_data(.queue_path = tmp_q, .training_path = tmp_t)
  expect_true(file.exists(file.path(tmp_t, "dpo.jsonl")))
  records <- read_jsonl(file.path(tmp_t, "dpo.jsonl"))
  expect_equal(records[[1]]$chosen,   "edited")
  expect_equal(records[[1]]$rejected, "original")
})

test_that("generate_training_data writes negative for rejected", {
  tmp_q <- local_tempdir()
  tmp_t <- local_tempdir()
  enqueue_review("draft", make_verdict_list(), "S2e10", "src", .queue_path = tmp_q)
  consolidate_queue(.queue_path = tmp_q)
  resolve_item("S2e10", "rejected", .queue_path = tmp_q)
  generate_training_data(.queue_path = tmp_q, .training_path = tmp_t)
  expect_true(file.exists(file.path(tmp_t, "negatives.jsonl")))
})

test_that("generate_training_data marks items as exported", {
  tmp_q <- local_tempdir()
  tmp_t <- local_tempdir()
  enqueue_review("d", make_verdict_list(), "S2e10", "s", .queue_path = tmp_q)
  consolidate_queue(.queue_path = tmp_q)
  resolve_item("S2e10", "accepted", .queue_path = tmp_q)
  generate_training_data(.queue_path = tmp_q, .training_path = tmp_t)
  df <- readr::read_csv(file.path(tmp_q, "queue.csv"), show_col_types = FALSE)
  expect_true(df$training_exported[df$section_id == "S2e10"])
})

test_that("generate_training_data skips already-exported items", {
  tmp_q <- local_tempdir()
  tmp_t <- local_tempdir()
  enqueue_review("d", make_verdict_list(), "S2e10", "s", .queue_path = tmp_q)
  consolidate_queue(.queue_path = tmp_q)
  resolve_item("S2e10", "accepted", .queue_path = tmp_q)
  generate_training_data(.queue_path = tmp_q, .training_path = tmp_t)
  n2 <- generate_training_data(.queue_path = tmp_q, .training_path = tmp_t)
  expect_equal(n2, 0L)
  records <- read_jsonl(file.path(tmp_t, "sft.jsonl"))
  expect_length(records, 1L)
})

test_that("generate_training_data loads prompt from file when present", {
  tmp_q <- local_tempdir()
  tmp_t <- local_tempdir()
  enqueue_review("d", make_verdict_list(), "S2e10", "s",
                 prompt = "stored prompt", .queue_path = tmp_q)
  consolidate_queue(.queue_path = tmp_q)
  resolve_item("S2e10", "accepted", .queue_path = tmp_q)
  generate_training_data(.queue_path = tmp_q, .training_path = tmp_t)
  records <- read_jsonl(file.path(tmp_t, "sft.jsonl"))
  expect_equal(records[[1]]$prompt, "stored prompt")
})

# --- write_intermediate_pairs_from_log() ------------------------------------

test_that("write_intermediate_pairs_from_log returns 0 for fewer than 2 entries", {
  tmp <- local_tempdir()
  expect_equal(
    write_intermediate_pairs_from_log("S2e10", "p", list(), .path = tmp),
    0L
  )
  one_entry <- list(list(draft = "d", confidence = 0.5))
  expect_equal(
    write_intermediate_pairs_from_log("S2e10", "p", one_entry, .path = tmp),
    0L
  )
})

test_that("write_intermediate_pairs_from_log writes DPO when confidence improves", {
  tmp <- local_tempdir()
  log <- list(
    list(draft = "first draft",  confidence = 0.55),
    list(draft = "second draft", confidence = 0.80)
  )
  n <- write_intermediate_pairs_from_log("S2e10", "p", log, .path = tmp)
  expect_equal(n, 1L)
  expect_true(file.exists(file.path(tmp, "dpo.jsonl")))
  recs <- read_jsonl(file.path(tmp, "dpo.jsonl"))
  expect_equal(recs[[1]]$rejected, "first draft")
  expect_equal(recs[[1]]$chosen,   "second draft")
})

test_that("write_intermediate_pairs_from_log writes negative when confidence drops", {
  tmp <- local_tempdir()
  log <- list(
    list(draft = "first draft",  confidence = 0.80),
    list(draft = "second draft", confidence = 0.55)
  )
  n <- write_intermediate_pairs_from_log("S2e10", "p", log, .path = tmp)
  expect_equal(n, 1L)
  expect_true(file.exists(file.path(tmp, "negatives.jsonl")))
  recs <- read_jsonl(file.path(tmp, "negatives.jsonl"))
  expect_equal(recs[[1]]$draft, "second draft")
  expect_equal(recs[[1]]$reject_reason, "revision_did_not_improve")
})

test_that("write_intermediate_pairs_from_log writes negative when confidence is flat", {
  tmp <- local_tempdir()
  log <- list(
    list(draft = "first draft",  confidence = 0.70),
    list(draft = "second draft", confidence = 0.70)
  )
  n <- write_intermediate_pairs_from_log("S2e10", "p", log, .path = tmp)
  expect_equal(n, 1L)
  expect_true(file.exists(file.path(tmp, "negatives.jsonl")))
})

test_that("write_intermediate_pairs_from_log skips identical drafts", {
  tmp <- local_tempdir()
  log <- list(
    list(draft = "same draft", confidence = 0.55),
    list(draft = "same draft", confidence = 0.80)
  )
  n <- write_intermediate_pairs_from_log("S2e10", "p", log, .path = tmp)
  expect_equal(n, 0L)
  expect_false(file.exists(file.path(tmp, "dpo.jsonl")))
})

test_that("write_intermediate_pairs_from_log skips entries missing draft or confidence", {
  tmp <- local_tempdir()
  log <- list(
    list(draft = "first",  confidence = 0.55),
    list(draft = NULL,     confidence = 0.80),
    list(draft = "third",  confidence = NA_real_)
  )
  n <- write_intermediate_pairs_from_log("S2e10", "p", log, .path = tmp)
  expect_equal(n, 0L)
})

test_that("write_intermediate_pairs_from_log walks multi-iteration logs pairwise", {
  tmp <- local_tempdir()
  log <- list(
    list(draft = "v1", confidence = 0.50),
    list(draft = "v2", confidence = 0.65),  # improved → DPO
    list(draft = "v3", confidence = 0.55),  # dropped → negative
    list(draft = "v4", confidence = 0.85)   # improved → DPO
  )
  n <- write_intermediate_pairs_from_log("S2e10", "p", log, .path = tmp)
  expect_equal(n, 3L)
  expect_length(read_jsonl(file.path(tmp, "dpo.jsonl")),       2L)
  expect_length(read_jsonl(file.path(tmp, "negatives.jsonl")), 1L)
})

# --- generate_training_data with iteration_log ------------------------------

test_that("generate_training_data writes intermediate DPO pairs from iteration_log", {
  tmp_q <- local_tempdir()
  tmp_t <- local_tempdir()
  iter_log <- list(
    list(draft = "draft_v1", confidence = 0.55, verdict = "flagged"),
    list(draft = "draft_v2", confidence = 0.85, verdict = "approved")
  )
  iter_log_json <- jsonlite::toJSON(iter_log, auto_unbox = TRUE)

  enqueue_review("draft_v2", make_verdict_list("approved", 0.85), "S2e10", "src",
                 iteration_log = iter_log_json,
                 .queue_path = tmp_q)
  consolidate_queue(.queue_path = tmp_q)
  resolve_item("S2e10", "accepted", .queue_path = tmp_q)
  generate_training_data(.queue_path = tmp_q, .training_path = tmp_t)

  expect_true(file.exists(file.path(tmp_t, "sft.jsonl")))     # the accepted draft
  expect_true(file.exists(file.path(tmp_t, "dpo.jsonl")))     # the intermediate pair
  recs <- read_jsonl(file.path(tmp_t, "dpo.jsonl"))
  expect_equal(recs[[1]]$rejected, "draft_v1")
  expect_equal(recs[[1]]$chosen,   "draft_v2")
})

test_that("generate_training_data tolerates missing or empty iteration_log", {
  tmp_q <- local_tempdir()
  tmp_t <- local_tempdir()
  enqueue_review("d", make_verdict_list(), "S2e10", "s",
                 iteration_log = "[]", .queue_path = tmp_q)
  consolidate_queue(.queue_path = tmp_q)
  resolve_item("S2e10", "accepted", .queue_path = tmp_q)
  expect_no_error(
    generate_training_data(.queue_path = tmp_q, .training_path = tmp_t)
  )
  expect_false(file.exists(file.path(tmp_t, "dpo.jsonl")))
})

# --- Step 3.2: Claude escalation source tagging -----------------------------

test_that("write_dpo accepts and writes a source field when supplied", {
  tmp <- local_tempdir()
  write_dpo("S2e10", "p", "ch", "rej", source = "claude_escalation", .path = tmp)
  rec <- read_jsonl(file.path(tmp, "dpo.jsonl"))[[1]]
  expect_equal(rec$source, "claude_escalation")
})

test_that("write_dpo omits source field when source = NULL (backward compat)", {
  tmp <- local_tempdir()
  write_dpo("S2e10", "p", "ch", "rej", .path = tmp)
  rec <- read_jsonl(file.path(tmp, "dpo.jsonl"))[[1]]
  expect_null(rec$source)
})

test_that("intermediate revision DPO pair is tagged source='intermediate'", {
  tmp <- local_tempdir()
  log <- list(
    list(draft = "v1", confidence = 0.55),
    list(draft = "v2", confidence = 0.85)
  )
  write_intermediate_pairs_from_log("S2e10", "p", log, .path = tmp)
  rec <- read_jsonl(file.path(tmp, "dpo.jsonl"))[[1]]
  expect_equal(rec$source, "intermediate")
})

test_that("cap_hit Claude revision emits DPO with source='claude_escalation'", {
  tmp <- local_tempdir()
  log <- list(
    list(draft = "ollama_v1", confidence = 0.50, model = "qwen3.5:9b"),
    list(draft = "claude_revision", confidence = 0.90,
         model = "claude (cap_hit escalation)",
         escalation_reason = "cap_hit")
  )
  n <- write_intermediate_pairs_from_log("S2e10", "p", log, .path = tmp)
  expect_equal(n, 1L)
  rec <- read_jsonl(file.path(tmp, "dpo.jsonl"))[[1]]
  expect_equal(rec$source,   "claude_escalation")
  expect_equal(rec$rejected, "ollama_v1")
  expect_equal(rec$chosen,   "claude_revision")
})

test_that("cap_hit pair picks highest-confidence Ollama draft as rejected", {
  tmp <- local_tempdir()
  log <- list(
    list(draft = "ollama_v1", confidence = 0.55),
    list(draft = "ollama_v2", confidence = 0.78),  # best Ollama
    list(draft = "ollama_v3", confidence = 0.40),
    list(draft = "claude_revision", confidence = 0.90,
         escalation_reason = "cap_hit")
  )
  write_intermediate_pairs_from_log("S2e10", "p", log, .path = tmp)
  recs <- read_jsonl(file.path(tmp, "dpo.jsonl"))
  esc <- Filter(function(r) identical(r$source, "claude_escalation"), recs)
  expect_length(esc, 1L)
  expect_equal(esc[[1]]$rejected, "ollama_v2")
  expect_equal(esc[[1]]$chosen,   "claude_revision")
})

test_that("cap_hit Claude with same draft as best Ollama emits no claude_escalation pair", {
  tmp <- local_tempdir()
  log <- list(
    list(draft = "ollama_only", confidence = 0.60),
    list(draft = "ollama_only", confidence = 0.85,    # Claude reviewed only
         escalation_reason = "cap_hit")
  )
  n <- write_intermediate_pairs_from_log("S2e10", "p", log, .path = tmp)
  expect_equal(n, 0L)
  expect_false(file.exists(file.path(tmp, "dpo.jsonl")))
})

test_that("cap_hit Claude with NA draft emits no claude_escalation pair", {
  tmp <- local_tempdir()
  log <- list(
    list(draft = "ollama_v1", confidence = 0.60),
    list(draft = NA_character_, confidence = 0.85,
         escalation_reason = "cap_hit")
  )
  n <- write_intermediate_pairs_from_log("S2e10", "p", log, .path = tmp)
  expect_equal(n, 0L)
})

test_that("accepted_with_edit DPO is tagged source='human_edit'", {
  tmp_q <- local_tempdir()
  tmp_t <- local_tempdir()
  enqueue_review("original", make_verdict_list(), "S2e10", "src", .queue_path = tmp_q)
  consolidate_queue(.queue_path = tmp_q)
  resolve_item("S2e10", "accepted_with_edit", edited_draft = "edited",
               .queue_path = tmp_q)
  generate_training_data(.queue_path = tmp_q, .training_path = tmp_t)
  rec <- read_jsonl(file.path(tmp_t, "dpo.jsonl"))[[1]]
  expect_equal(rec$source, "human_edit")
})
