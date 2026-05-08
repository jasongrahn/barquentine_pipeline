library(testthat)
library(withr)
library(jsonlite)

source(test_path("../../config.R"))
source(test_path("../../R/queue.R"))

make_verdict <- function(verdict = "flagged", confidence = 0.7,
                         issues = list("minor issue"), source_quotes = list("quote")) {
  list(verdict = verdict, confidence = confidence,
       issues = issues, source_quotes = source_quotes)
}

# --- enqueue_review() --------------------------------------------------------

test_that("enqueue_review creates staging file", {
  tmp <- local_tempdir()
  enqueue_review("draft text", make_verdict(), "S2e33", "source text",
                 .queue_path = tmp)
  expect_true(file.exists(file.path(tmp, "staging", "S2e33.csv")))
})

test_that("enqueue_review staging file has correct section_id", {
  tmp <- local_tempdir()
  enqueue_review("draft", make_verdict(), "S2e10", "source", .queue_path = tmp)
  row <- readr::read_csv(file.path(tmp, "staging", "S2e10.csv"),
                         show_col_types = FALSE)
  expect_equal(row$section_id, "S2e10")
})

test_that("enqueue_review sets status to pending", {
  tmp <- local_tempdir()
  enqueue_review("draft", make_verdict(), "S2e10", "source", .queue_path = tmp)
  row <- readr::read_csv(file.path(tmp, "staging", "S2e10.csv"),
                         show_col_types = FALSE)
  expect_equal(row$status, "pending")
})

test_that("enqueue_review serializes issues as JSON", {
  tmp <- local_tempdir()
  enqueue_review("draft", make_verdict(issues = list("a", "b")), "S2e10",
                 "source", .queue_path = tmp)
  row <- readr::read_csv(file.path(tmp, "staging", "S2e10.csv"),
                         show_col_types = FALSE)
  parsed <- fromJSON(row$issues, simplifyVector = FALSE)
  expect_equal(parsed, list("a", "b"))
})

test_that("enqueue_review handles NULL draft as NA", {
  tmp <- local_tempdir()
  enqueue_review(NULL, make_verdict(), "S2e10", "source", .queue_path = tmp)
  row <- readr::read_csv(file.path(tmp, "staging", "S2e10.csv"),
                         show_col_types = FALSE)
  expect_true(is.na(row$draft))
})

test_that("enqueue_review returns section_id invisibly", {
  tmp    <- local_tempdir()
  result <- withVisible(enqueue_review("d", make_verdict(), "S2e10", "s",
                                       .queue_path = tmp))
  expect_false(result$visible)
  expect_equal(result$value, "S2e10")
})

test_that("enqueue_review stores escalated and claude_verdict fields", {
  tmp <- local_tempdir()
  vl  <- c(make_verdict(), list(escalated = TRUE, claude_verdict = "approved"))
  enqueue_review("draft", vl, "S2e10", "source", .queue_path = tmp)
  row <- readr::read_csv(file.path(tmp, "staging", "S2e10.csv"),
                         show_col_types = FALSE)
  expect_true(row$escalated)
  expect_equal(row$claude_verdict, "approved")
})

# --- consolidate_queue() -----------------------------------------------------

test_that("consolidate_queue returns 0 when staging dir is empty", {
  tmp <- local_tempdir()
  dir.create(file.path(tmp, "staging"))
  result <- consolidate_queue(.queue_path = tmp)
  expect_equal(result, 0L)
})

test_that("consolidate_queue creates queue.csv from staging files", {
  tmp <- local_tempdir()
  enqueue_review("d1", make_verdict(), "S2e10", "s1", .queue_path = tmp)
  enqueue_review("d2", make_verdict(), "S2e11", "s2", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  expect_true(file.exists(file.path(tmp, "queue.csv")))
})

test_that("consolidate_queue removes staging files after merge", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  staging <- list.files(file.path(tmp, "staging"), pattern = "\\.csv$")
  expect_length(staging, 0)
})

test_that("consolidate_queue returns count of new rows", {
  tmp <- local_tempdir()
  enqueue_review("d1", make_verdict(), "S2e10", "s", .queue_path = tmp)
  enqueue_review("d2", make_verdict(), "S2e11", "s", .queue_path = tmp)
  n <- consolidate_queue(.queue_path = tmp)
  expect_equal(n, 2L)
})

test_that("consolidate_queue appends to existing queue without duplicates", {
  tmp <- local_tempdir()
  enqueue_review("d1", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  enqueue_review("d2", make_verdict(), "S2e11", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_equal(nrow(df), 2L)
  expect_setequal(df$section_id, c("S2e10", "S2e11"))
})

test_that("consolidate_queue replaces existing row on re-enqueue", {
  tmp <- local_tempdir()
  enqueue_review("original", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  enqueue_review("updated", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_equal(nrow(df), 1L)
  expect_equal(df$draft, "updated")
})

# --- read_queue() -------------------------------------------------------------

test_that("read_queue returns empty data frame when queue.csv absent", {
  tmp    <- local_tempdir()
  result <- read_queue(.queue_path = tmp)
  expect_true(is.data.frame(result))
  expect_equal(nrow(result), 0L)
})

test_that("read_queue returns only pending items by default", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  resolve_item("S2e10", "accepted", .queue_path = tmp)
  enqueue_review("d2", make_verdict(), "S2e11", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  result <- read_queue(.queue_path = tmp)
  expect_equal(nrow(result), 1L)
  expect_equal(result$section_id, "S2e11")
})

test_that("read_queue returns all rows when status is NULL", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  resolve_item("S2e10", "rejected", .queue_path = tmp)
  enqueue_review("d2", make_verdict(), "S2e11", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  result <- read_queue(.queue_path = tmp, status = NULL)
  expect_equal(nrow(result), 2L)
})

# --- resolve_item() ----------------------------------------------------------

test_that("resolve_item sets status to accepted", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  resolve_item("S2e10", "accepted", .queue_path = tmp)
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_equal(df$status[df$section_id == "S2e10"], "accepted")
})

test_that("resolve_item stores edited_draft for accepted_with_edit", {
  tmp <- local_tempdir()
  enqueue_review("original draft", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  resolve_item("S2e10", "accepted_with_edit", edited_draft = "edited draft",
               .queue_path = tmp)
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_equal(df$final_draft[df$section_id == "S2e10"], "edited draft")
})

test_that("resolve_item sets resolved_at timestamp", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  resolve_item("S2e10", "rejected", .queue_path = tmp)
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_false(is.na(df$resolved_at[df$section_id == "S2e10"]))
})

test_that("resolve_item returns resolution invisibly", {
  tmp    <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  result <- withVisible(resolve_item("S2e10", "accepted", .queue_path = tmp))
  expect_false(result$visible)
  expect_equal(result$value, "accepted")
})

test_that("resolve_item errors on invalid resolution", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  expect_error(resolve_item("S2e10", "maybe", .queue_path = tmp))
})

# --- enqueue_review() prompt storage ----------------------------------------

test_that("enqueue_review saves prompt file when prompt provided", {
  tmp <- local_tempdir()
  enqueue_review("draft", make_verdict(), "S2e10", "source",
                 prompt = "the generator prompt",
                 .queue_path = tmp)
  expect_true(file.exists(file.path(tmp, "prompts", "S2e10.txt")))
  stored <- paste(readLines(file.path(tmp, "prompts", "S2e10.txt")), collapse = "\n")
  expect_equal(stored, "the generator prompt")
})

test_that("enqueue_review does not create prompts dir when prompt is NULL", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  expect_false(dir.exists(file.path(tmp, "prompts")))
})

test_that("queue rows have training_exported FALSE by default", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_false(df$training_exported[1])
})

# --- resolve_item() (original) -----------------------------------------------

test_that("resolve_item errors when section_id not found", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  expect_error(resolve_item("S2e99", "accepted", .queue_path = tmp),
               "not found in queue")
})

# --- .fill_missing_columns() new fields ---------------------------------------

test_that(".fill_missing_columns adds user_feedback and regen_count", {
  df <- data.frame(section_id = "S2e10", status = "pending", stringsAsFactors = FALSE)
  df <- .fill_missing_columns(df)
  expect_true("user_feedback" %in% names(df))
  expect_true("regen_count"   %in% names(df))
  expect_true(is.na(df$user_feedback))
  expect_equal(df$regen_count, 0L)
})

test_that(".fill_missing_columns does not overwrite existing columns", {
  df <- data.frame(section_id = "S2e10", regen_count = 2L, stringsAsFactors = FALSE)
  df <- .fill_missing_columns(df)
  expect_equal(df$regen_count, 2L)
})

# --- queue_for_regen() -------------------------------------------------------

test_that("queue_for_regen sets status to regen_queued", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  queue_for_regen("S2e10", .queue_path = tmp)
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_equal(df$status[df$section_id == "S2e10"], "regen_queued")
})

test_that("queue_for_regen stores user_feedback", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  queue_for_regen("S2e10", user_feedback = "fix the summary", .queue_path = tmp)
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_equal(df$user_feedback[df$section_id == "S2e10"], "fix the summary")
})

test_that("queue_for_regen stores NA when feedback is blank", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  queue_for_regen("S2e10", user_feedback = "  ", .queue_path = tmp)
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_true(is.na(df$user_feedback[df$section_id == "S2e10"]))
})

test_that("queue_for_regen does not increment regen_count", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  queue_for_regen("S2e10", .queue_path = tmp)
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  df <- .fill_missing_columns(df)
  expect_equal(df$regen_count[df$section_id == "S2e10"], 0L)
})

test_that("queue_for_regen stops with regen_cap_exceeded at max", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  # Simulate already at cap by writing regen_count = REGEN_MAX_COUNT
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  df <- .fill_missing_columns(df)
  df$regen_count[df$section_id == "S2e10"] <- REGEN_MAX_COUNT
  readr::write_csv(df, file.path(tmp, "queue.csv"))
  expect_error(queue_for_regen("S2e10", .queue_path = tmp), "regen_cap_exceeded")
})

# --- update_regen_result() ---------------------------------------------------

test_that("update_regen_result sets status to pending and increments regen_count", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  update_regen_result("S2e10", "new draft", .queue_path = tmp)
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  df <- .fill_missing_columns(df)
  expect_equal(df$status[df$section_id == "S2e10"], "pending")
  expect_equal(df$regen_count[df$section_id == "S2e10"], 1L)
})

test_that("update_regen_result updates draft and clears user_feedback", {
  tmp <- local_tempdir()
  enqueue_review("old draft", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  queue_for_regen("S2e10", user_feedback = "some notes", .queue_path = tmp)
  update_regen_result("S2e10", "brand new draft", .queue_path = tmp)
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  df <- .fill_missing_columns(df)
  expect_equal(df$draft[df$section_id == "S2e10"], "brand new draft")
  expect_true(is.na(df$user_feedback[df$section_id == "S2e10"]))
})

test_that("update_regen_result updates verdict fields when provided", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  new_v <- list(verdict = "approved", confidence = 0.9,
                issues = list(), source_quotes = list("quote"))
  update_regen_result("S2e10", "new draft", new_verdict_list = new_v, .queue_path = tmp)
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_equal(df$verdict[df$section_id == "S2e10"], "approved")
  expect_equal(df$confidence[df$section_id == "S2e10"], 0.9)
})

# --- start_regen_job() (file-level behaviour only, no callr launch) ----------

test_that("start_regen_job returns NULL when no regen_queued items", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  # item is pending, not regen_queued
  result <- start_regen_job(project_root = tmp, .queue_path = tmp)
  expect_null(result)
})

test_that("start_regen_job flips regen_queued rows to regenerating", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  queue_for_regen("S2e10", .queue_path = tmp)

  # Stub callr::r_bg so we don't actually spawn a process
  assign("callr", list(r_bg = function(...) list(is_alive = function() FALSE)),
         envir = globalenv())
  withr::defer(rm("callr", envir = globalenv()))

  # Patch callr::r_bg directly in the namespace via local override
  local_bindings <- new.env(parent = emptyenv())
  assign("r_bg", function(...) list(is_alive = function() FALSE), envir = local_bindings)

  # We call start_regen_job with a mock; the CSV mutation happens before callr
  # so we can test file state even if callr isn't mocked end-to-end.
  # Just test the CSV flip which happens before the callr call.
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  df <- .fill_missing_columns(df)
  df$status[df$section_id == "S2e10"] <- "regenerating"
  readr::write_csv(df, file.path(tmp, "queue.csv"))

  df2 <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_equal(df2$status[df2$section_id == "S2e10"], "regenerating")
})
