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

test_that("resolve_item errors when section_id not found", {
  tmp <- local_tempdir()
  enqueue_review("d", make_verdict(), "S2e10", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  expect_error(resolve_item("S2e99", "accepted", .queue_path = tmp),
               "not found in queue")
})
