library(testthat)
library(withr)

source(test_path("../../config.R"))
source(test_path("../../R/review.R"))

# --- format_review_entry() ---------------------------------------------------

test_that("format_review_entry returns a character string", {
  result <- format_review_entry("npcs/Attorrnash", "unresolved alias")
  expect_type(result, "character")
  expect_equal(length(result), 1L)
})

test_that("format_review_entry string starts with '- [ ]'", {
  result <- format_review_entry("npcs/Attorrnash", "unresolved alias")
  expect_true(startsWith(result, "- [ ]"))
})

test_that("format_review_entry contains the note_path inside [[...]]", {
  result <- format_review_entry("npcs/Attorrnash", "unresolved alias")
  expect_true(grepl("[[npcs/Attorrnash]]", result, fixed = TRUE))
})

test_that("format_review_entry contains the reason", {
  result <- format_review_entry("npcs/Attorrnash", "unresolved alias")
  expect_true(grepl("unresolved alias", result, fixed = TRUE))
})

test_that("format_review_entry contains the run_date", {
  result <- format_review_entry("npcs/Attorrnash", "sparse source",
                                run_date = as.Date("2026-05-03"))
  expect_true(grepl("2026-05-03", result, fixed = TRUE))
})

test_that("format_review_entry defaults run_date to today", {
  result <- format_review_entry("sessions/S2e33", "stub")
  expect_true(grepl(as.character(Sys.Date()), result, fixed = TRUE))
})

# --- append_review_entry() ---------------------------------------------------

test_that("append_review_entry creates review_log.md if it does not exist", {
  tmp <- local_tempdir()
  log_path <- file.path(tmp, "review", "review_log.md")

  expect_false(file.exists(log_path))
  append_review_entry("- [ ] test entry", vault_path = tmp, dry_run = FALSE)
  expect_true(file.exists(log_path))
})

test_that("append_review_entry creates parent directory when absent", {
  tmp <- local_tempdir()
  append_review_entry("- [ ] test entry", vault_path = tmp, dry_run = FALSE)
  expect_true(dir.exists(file.path(tmp, "review")))
})

test_that("append_review_entry does not modify existing content", {
  tmp <- local_tempdir()
  dir.create(file.path(tmp, "review"))
  log_path <- file.path(tmp, "review", "review_log.md")
  writeLines("# Existing content", log_path)

  append_review_entry("- [ ] new entry", vault_path = tmp, dry_run = FALSE)

  content <- readr::read_file(log_path)
  expect_true(grepl("# Existing content", content, fixed = TRUE))
  expect_true(grepl("new entry", content, fixed = TRUE))
})

test_that("append_review_entry entries accumulate across multiple calls", {
  tmp <- local_tempdir()
  append_review_entry("- [ ] entry one", vault_path = tmp, dry_run = FALSE)
  append_review_entry("- [ ] entry two", vault_path = tmp, dry_run = FALSE)
  append_review_entry("- [ ] entry three", vault_path = tmp, dry_run = FALSE)

  content <- readr::read_file(file.path(tmp, "review", "review_log.md"))
  expect_true(grepl("entry one",   content, fixed = TRUE))
  expect_true(grepl("entry two",   content, fixed = TRUE))
  expect_true(grepl("entry three", content, fixed = TRUE))
})

test_that("append_review_entry returns the log path invisibly", {
  tmp    <- local_tempdir()
  result <- withVisible(
    append_review_entry("- [ ] entry", vault_path = tmp, dry_run = FALSE)
  )
  expect_false(result$visible)
  expect_true(file.exists(result$value))
})

# --- write_run_header() ------------------------------------------------------

test_that("write_run_header appends a line containing the session_id", {
  tmp <- local_tempdir()
  write_run_header("S2e42", vault_path = tmp, dry_run = FALSE)

  content <- readr::read_file(file.path(tmp, "review", "review_log.md"))
  expect_true(grepl("S2e42", content, fixed = TRUE))
})

test_that("write_run_header appends a line containing today's date", {
  tmp <- local_tempdir()
  write_run_header("S2e42", vault_path = tmp, dry_run = FALSE)

  content <- readr::read_file(file.path(tmp, "review", "review_log.md"))
  expect_true(grepl(as.character(Sys.Date()), content, fixed = TRUE))
})

test_that("write_run_header does not modify existing log entries", {
  tmp <- local_tempdir()
  append_review_entry("- [ ] prior entry", vault_path = tmp, dry_run = FALSE)
  write_run_header("S2e42", vault_path = tmp, dry_run = FALSE)

  content <- readr::read_file(file.path(tmp, "review", "review_log.md"))
  expect_true(grepl("prior entry", content, fixed = TRUE))
  expect_true(grepl("S2e42",       content, fixed = TRUE))
})

test_that("write_run_header returns the log path invisibly", {
  tmp    <- local_tempdir()
  result <- withVisible(
    write_run_header("S2e42", vault_path = tmp, dry_run = FALSE)
  )
  expect_false(result$visible)
  expect_true(file.exists(result$value))
})

# --- Safety: no destructive operations in review.R ---------------------------

test_that("review.R contains no destructive file or directory operations", {
  src <- readr::read_file(test_path("../../R/review.R"))
  expect_false(grepl("file\\.remove",  src))
  expect_false(grepl("file_delete",    src, fixed = TRUE))
  expect_false(grepl("\\bunlink\\b",   src))
  expect_false(grepl("dir_delete",     src, fixed = TRUE))
  expect_false(grepl("write_lines",    src, fixed = TRUE))
})
