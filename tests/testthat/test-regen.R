library(testthat)
library(withr)
library(jsonlite)

source(test_path("../../config.R"))
source(test_path("../../R/queue.R"))
source(test_path("../../R/regen.R"))

# Helpers ---------------------------------------------------------------------

make_verdict <- function(verdict = "flagged", confidence = 0.7,
                         issues = list("minor issue"), source_quotes = list("quote")) {
  list(verdict = verdict, confidence = confidence,
       issues = issues, source_quotes = source_quotes)
}

.make_queue <- function(tmp, section_id = "S2e10", note_type = "session",
                        source_text = "source passage one\n\n---\n\nsource passage two",
                        entity_name = NA_character_,
                        existing_note = NA_character_,
                        user_feedback = NA_character_) {
  enqueue_review("original draft", make_verdict(), section_id, source_text,
                 note_type = note_type, entity_name = entity_name,
                 .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)
  # Flip to regenerating directly
  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  df <- .fill_missing_columns(df)
  df$status[df$section_id == section_id]        <- "regenerating"
  df$existing_note[df$section_id == section_id] <- existing_note
  df$user_feedback[df$section_id == section_id] <- user_feedback
  readr::write_csv(df, file.path(tmp, "queue.csv"))
  invisible(tmp)
}

# regen_worker() — session note -----------------------------------------------

test_that("regen_worker processes session row and sets status to pending", {
  tmp <- local_tempdir()
  .make_queue(tmp, section_id = "S2e10", note_type = "session")

  # Write a lock file (worker removes it on exit)
  writeLines(character(0), file.path(tmp, ".regen.lock"))

  assign("generate_note", function(...) "---\ntags: [session]\n## Summary\nregenerated",
         envir = globalenv())
  withr::defer(rm("generate_note", envir = globalenv()))

  regen_worker(file.path(tmp, "queue.csv"))

  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_equal(df$status[df$section_id == "S2e10"], "pending")
  expect_equal(df$draft[df$section_id == "S2e10"],
               "---\ntags: [session]\n## Summary\nregenerated")
})

test_that("regen_worker increments regen_count for session note", {
  tmp <- local_tempdir()
  .make_queue(tmp)
  writeLines(character(0), file.path(tmp, ".regen.lock"))

  assign("generate_note", function(...) "---\ntags: [session]\n## Summary\nok",
         envir = globalenv())
  withr::defer(rm("generate_note", envir = globalenv()))

  regen_worker(file.path(tmp, "queue.csv"))

  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  df <- .fill_missing_columns(df)
  expect_equal(df$regen_count[df$section_id == "S2e10"], 1L)
})

# regen_worker() — entity note ------------------------------------------------

test_that("regen_worker processes npc row with prior_draft and user_feedback", {
  tmp <- local_tempdir()
  .make_queue(tmp, section_id = "npc-elara", note_type = "npc",
              entity_name = "Elara",
              source_text = "passage one\n\n---\n\npassage two",
              existing_note = "# Elara\nold content",
              user_feedback = "add her motivation")
  writeLines(character(0), file.path(tmp, ".regen.lock"))

  capture <- list()
  assign("generate_entity_note", function(entity_name, source_passages, note_type,
                                          prior_draft = NULL, critic_findings = NULL,
                                          user_feedback = NULL, ...) {
    capture[[length(capture) + 1]] <<- list(
      entity_name   = entity_name,
      n_passages    = length(source_passages),
      prior_draft   = prior_draft,
      user_feedback = user_feedback
    )
    "---\ntags: [npc]\n## Overview\nregenerated"
  }, envir = globalenv())
  withr::defer(rm("generate_entity_note", envir = globalenv()))

  regen_worker(file.path(tmp, "queue.csv"))

  expect_equal(capture[[1]]$entity_name,   "Elara")
  expect_equal(capture[[1]]$n_passages,    2L)
  expect_equal(capture[[1]]$prior_draft,   "# Elara\nold content")
  expect_equal(capture[[1]]$user_feedback, "add her motivation")

  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_equal(df$status[df$section_id == "npc-elara"], "pending")
})

# regen_worker() — failure handling -------------------------------------------

test_that("regen_worker flips item back to regen_queued when generation returns NULL", {
  tmp <- local_tempdir()
  .make_queue(tmp)
  writeLines(character(0), file.path(tmp, ".regen.lock"))

  assign("generate_note", function(...) NULL, envir = globalenv())
  withr::defer(rm("generate_note", envir = globalenv()))

  regen_worker(file.path(tmp, "queue.csv"))

  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_equal(df$status[df$section_id == "S2e10"], "regen_queued")
})

test_that("regen_worker flips item back to regen_queued when generation throws", {
  tmp <- local_tempdir()
  .make_queue(tmp)
  writeLines(character(0), file.path(tmp, ".regen.lock"))

  assign("generate_note", function(...) stop("Ollama timeout"), envir = globalenv())
  withr::defer(rm("generate_note", envir = globalenv()))

  # Should not throw — error is caught internally
  expect_no_error(regen_worker(file.path(tmp, "queue.csv")))

  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_equal(df$status[df$section_id == "S2e10"], "regen_queued")
})

# regen_worker() — lock file --------------------------------------------------

test_that("regen_worker removes lock file on success", {
  tmp <- local_tempdir()
  .make_queue(tmp)
  lock <- file.path(tmp, ".regen.lock")
  writeLines(character(0), lock)

  assign("generate_note", function(...) "---\ntags: [session]\n## Summary\nok",
         envir = globalenv())
  withr::defer(rm("generate_note", envir = globalenv()))

  regen_worker(file.path(tmp, "queue.csv"))
  expect_false(file.exists(lock))
})

test_that("regen_worker removes lock file even when generation throws", {
  tmp <- local_tempdir()
  .make_queue(tmp)
  lock <- file.path(tmp, ".regen.lock")
  writeLines(character(0), lock)

  assign("generate_note", function(...) stop("crash"), envir = globalenv())
  withr::defer(rm("generate_note", envir = globalenv()))

  expect_no_error(regen_worker(file.path(tmp, "queue.csv")))
  expect_false(file.exists(lock))
})

# regen_worker() — only touches regenerating rows -----------------------------

test_that("regen_worker ignores non-regenerating rows", {
  tmp <- local_tempdir()
  enqueue_review("pending draft", make_verdict(), "S2e11", "s", .queue_path = tmp)
  enqueue_review("regen draft",   make_verdict(), "S2e12", "s", .queue_path = tmp)
  consolidate_queue(.queue_path = tmp)

  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  df$status[df$section_id == "S2e12"] <- "regenerating"
  readr::write_csv(df, file.path(tmp, "queue.csv"))

  writeLines(character(0), file.path(tmp, ".regen.lock"))
  assign("generate_note", function(...) "---\nnew\n", envir = globalenv())
  withr::defer(rm("generate_note", envir = globalenv()))

  regen_worker(file.path(tmp, "queue.csv"))

  df2 <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_equal(df2$status[df2$section_id == "S2e11"], "pending")
  expect_equal(df2$status[df2$section_id == "S2e12"], "pending")
  expect_equal(df2$draft[df2$section_id == "S2e11"], "pending draft")
})
