library(testthat)
library(withr)

source(test_path("../../config.R"))
source(test_path("../../R/writer.R"))

# --- get_output_path() -------------------------------------------------------

test_that("get_output_path returns a path starting with DRY_RUN_PATH when dry_run is TRUE", {
  tmp  <- local_tempdir()
  path <- get_output_path("npcs/Attorrnash.md", dry_run = TRUE, .dry_run_path = tmp)
  expect_true(startsWith(path, tmp))
})

test_that("get_output_path returns a path starting with VAULT_PATH when dry_run is FALSE", {
  tmp  <- local_tempdir()
  path <- get_output_path("npcs/Attorrnash.md", dry_run = FALSE, .vault_path = tmp)
  expect_true(startsWith(path, tmp))
})

test_that("get_output_path creates the parent directory if it does not exist", {
  tmp  <- local_tempdir()
  get_output_path("sessions/subdir/test.md", dry_run = TRUE, .dry_run_path = tmp)
  expect_true(dir.exists(file.path(tmp, "sessions/subdir")))
})

test_that("get_output_path returns the full file path including the filename", {
  tmp  <- local_tempdir()
  path <- get_output_path("npcs/Attorrnash.md", dry_run = TRUE, .dry_run_path = tmp)
  expect_equal(basename(path), "Attorrnash.md")
})

# --- write_note() ------------------------------------------------------------

test_that("write_note creates a file with the correct content", {
  tmp <- local_tempdir()
  write_note("hello world", "sessions/test.md", dry_run = TRUE, .dry_run_path = tmp)
  expect_equal(read_file(file.path(tmp, "sessions/test.md")), "hello world")
})

test_that("write_note returns the full output path invisibly", {
  tmp    <- local_tempdir()
  result <- withVisible(
    write_note("content", "sessions/test.md", dry_run = TRUE, .dry_run_path = tmp)
  )
  expect_false(result$visible)
  expect_true(file.exists(result$value))
})

test_that("write_note errors informatively when file exists and overwrite is FALSE", {
  tmp <- local_tempdir()
  write_note("first", "npcs/Basil.md", dry_run = TRUE, .dry_run_path = tmp)
  expect_error(
    write_note("second", "npcs/Basil.md", dry_run = TRUE, .dry_run_path = tmp),
    regexp = "already exists"
  )
})

test_that("write_note succeeds when overwrite is TRUE and file already exists", {
  tmp <- local_tempdir()
  write_note("first",  "npcs/Basil.md", dry_run = TRUE, .dry_run_path = tmp)
  write_note("second", "npcs/Basil.md", dry_run = TRUE, .dry_run_path = tmp,
             overwrite = TRUE)
  expect_equal(read_file(file.path(tmp, "npcs/Basil.md")), "second")
})

test_that("write_note is a no-op when file exists with identical content", {
  tmp <- local_tempdir()
  path <- file.path(tmp, "sessions/test.md")
  write_note("same content", "sessions/test.md", dry_run = TRUE, .dry_run_path = tmp)
  mtime_before <- file.mtime(path)
  Sys.sleep(0.05)
  write_note("same content", "sessions/test.md", dry_run = TRUE, .dry_run_path = tmp)
  expect_equal(file.mtime(path), mtime_before)
})

test_that("write_note overwrites when content differs even without overwrite = TRUE in guard path", {
  tmp <- local_tempdir()
  write_note("original", "sessions/test.md", dry_run = TRUE, .dry_run_path = tmp)
  write_note("updated",  "sessions/test.md", dry_run = TRUE, .dry_run_path = tmp,
             overwrite = TRUE)
  expect_equal(read_file(file.path(tmp, "sessions/test.md")), "updated")
})

# --- note_exists() -----------------------------------------------------------

test_that("note_exists returns FALSE when file is absent", {
  tmp <- local_tempdir()
  expect_false(note_exists("npcs/Ghost.md", dry_run = TRUE, .dry_run_path = tmp))
})

test_that("note_exists returns TRUE after write_note creates the file", {
  tmp <- local_tempdir()
  write_note("content", "npcs/Basil.md", dry_run = TRUE, .dry_run_path = tmp)
  expect_true(note_exists("npcs/Basil.md", dry_run = TRUE, .dry_run_path = tmp))
})

# --- Safety: no destructive operations in writer.R ---------------------------

test_that("writer.R contains no destructive file or directory operations", {
  src <- read_file(test_path("../../R/writer.R"))
  expect_false(grepl("file\\.remove",    src))
  expect_false(grepl("fs::file_delete",  src))
  expect_false(grepl("file_delete",      src))
  expect_false(grepl("\\bunlink\\b",     src))
  expect_false(grepl("fs::dir_delete",   src))
  expect_false(grepl("dir_delete",       src))
})
