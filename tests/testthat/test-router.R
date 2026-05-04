library(testthat)
library(withr)

source(test_path("../../config.R"))
source(test_path("../../R/ollama.R"))
source(test_path("../../R/claude.R"))
source(test_path("../../R/critic.R"))
source(test_path("../../R/writer.R"))
source(test_path("../../R/router.R"))

# Stub for enqueue_review — pushed to globalenv so dispatch_note's lexical scope finds it
assign("enqueue_review",
       function(draft, verdict_list, section_id, source_text,
                .queue_path = REVIEW_QUEUE_PATH) invisible(NULL),
       envir = globalenv())

# --- route_verdict() ---------------------------------------------------------

test_that("route_verdict returns skip for skipped verdict", {
  expect_equal(route_verdict("skipped", NA), "skip")
})

test_that("route_verdict returns enqueue for parse_error", {
  expect_equal(route_verdict("parse_error", 0), "enqueue")
})

test_that("route_verdict returns enqueue for rejected", {
  expect_equal(route_verdict("rejected", 0.1), "enqueue")
})

test_that("route_verdict returns auto_approve for approved above threshold", {
  expect_equal(route_verdict("approved", CRITIC_AUTO_APPROVE_THRESHOLD),     "auto_approve")
  expect_equal(route_verdict("approved", CRITIC_AUTO_APPROVE_THRESHOLD + 0.1), "auto_approve")
})

test_that("route_verdict returns enqueue for approved below threshold", {
  expect_equal(route_verdict("approved", CRITIC_AUTO_APPROVE_THRESHOLD - 0.01), "enqueue")
})

test_that("route_verdict returns escalate for flagged below escalate threshold", {
  expect_equal(route_verdict("flagged", CRITIC_ESCALATE_THRESHOLD - 0.01), "escalate")
})

test_that("route_verdict returns enqueue for flagged at or above escalate threshold", {
  expect_equal(route_verdict("flagged", CRITIC_ESCALATE_THRESHOLD),       "enqueue")
  expect_equal(route_verdict("flagged", CRITIC_ESCALATE_THRESHOLD + 0.1), "enqueue")
})

test_that("route_verdict returns enqueue for unknown verdict", {
  expect_equal(route_verdict("unknown_value", 0.5), "enqueue")
})

test_that("route_verdict handles NA confidence gracefully for approved", {
  expect_equal(route_verdict("approved", NA), "enqueue")
})

test_that("route_verdict handles NA confidence gracefully for flagged", {
  expect_equal(route_verdict("flagged", NA), "enqueue")
})

# --- dispatch_note() signature -----------------------------------------------

test_that("dispatch_note exists and has correct arguments", {
  expect_true(is.function(dispatch_note))
  args <- names(formals(dispatch_note))
  expect_true("draft"        %in% args)
  expect_true("verdict_list" %in% args)
  expect_true("section_id"   %in% args)
  expect_true("source_text"  %in% args)
  expect_true("dry_run"      %in% args)
})

# --- dispatch_note() skip path -----------------------------------------------

test_that("dispatch_note returns NULL invisibly for skipped verdict", {
  result <- dispatch_note(
    draft        = NULL,
    verdict_list = list(verdict = "skipped", confidence = NA),
    section_id   = "S2e33",
    source_text  = "some source"
  )
  expect_null(result)
})

# --- dispatch_note() auto_approve path ---------------------------------------

test_that("dispatch_note writes note to vault for auto_approve verdict", {
  tmp <- local_tempdir()
  dispatch_note(
    draft        = "# Note content",
    verdict_list = list(verdict = "approved", confidence = 0.95),
    section_id   = "S2e33",
    source_text  = "source",
    dry_run      = TRUE,
    .dry_run_path = tmp
  )
  expect_true(file.exists(file.path(tmp, "sessions", "S2e33.md")))
})

test_that("dispatch_note returns auto_approved invisibly on success", {
  tmp    <- local_tempdir()
  result <- withVisible(dispatch_note(
    draft        = "content",
    verdict_list = list(verdict = "approved", confidence = 0.95),
    section_id   = "S2e99",
    source_text  = "source",
    dry_run      = TRUE,
    .dry_run_path = tmp
  ))
  expect_false(result$visible)
  expect_equal(result$value, "auto_approved")
})

# --- dispatch_note() enqueue path --------------------------------------------

test_that("dispatch_note returns enqueued for flagged verdict above escalate threshold", {
  tmp_queue <- local_tempdir()

  # Stub enqueue_review so we don't need queue.R loaded yet
  enqueue_review <- function(...) invisible(NULL)

  result <- withVisible(dispatch_note(
    draft        = "content",
    verdict_list = list(verdict  = "flagged",
                        confidence = CRITIC_ESCALATE_THRESHOLD + 0.1,
                        issues   = list("minor issue"),
                        source_quotes = list()),
    section_id   = "S2e33",
    source_text  = "source",
    dry_run      = TRUE,
    .dry_run_path = local_tempdir(),
    .queue_path   = tmp_queue
  ))
  expect_false(result$visible)
  expect_equal(result$value, "enqueued")
})

# --- Safety: no destructive operations ---------------------------------------

test_that("router.R contains no destructive file operations", {
  src <- readr::read_file(test_path("../../R/router.R"))
  expect_false(grepl("file\\.remove", src))
  expect_false(grepl("file_delete",   src))
  expect_false(grepl("\\bunlink\\b",  src))
  expect_false(grepl("dir_delete",    src))
})
