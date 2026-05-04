library(testthat)
library(withr)
library(jsonlite)

source(test_path("../../config.R"))
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
