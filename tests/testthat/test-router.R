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
       function(draft, verdict_list, section_id, source_text, ...) invisible(NULL),
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

test_that("route_verdict returns enqueue for all approved verdicts (auto_approve disabled in Phase 0)", {
  # auto_approve path removed; all approved drafts go to human review queue
  expect_equal(route_verdict("approved", 0.99),  "enqueue")
  expect_equal(route_verdict("approved", 0.85),  "enqueue")
  expect_equal(route_verdict("approved", Inf),   "enqueue")
  expect_equal(route_verdict("approved", NA),    "enqueue")
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
  expect_true("refinement_result" %in% args)
  expect_true("section_id"        %in% args)
  expect_true("source_text"       %in% args)
  expect_true("dry_run"           %in% args)
})

# --- dispatch_note() skip path -----------------------------------------------

test_that("dispatch_note returns NULL invisibly for skipped verdict (refinement_result path)", {
  result <- dispatch_note(
    refinement_result = list(
      best_draft      = NULL,
      final_verdict   = list(verdict = "skipped", confidence = NA),
      iteration_count = 1L,
      claude_used     = FALSE,
      iteration_log   = list()
    ),
    section_id  = "S2e33",
    source_text = "some source"
  )
  expect_null(result)
})

test_that("dispatch_note returns NULL invisibly for skipped verdict (legacy path)", {
  result <- dispatch_note(
    refinement_result = NULL,
    draft        = NULL,
    verdict_list = list(verdict = "skipped", confidence = NA),
    section_id   = "S2e33",
    source_text  = "some source"
  )
  expect_null(result)
})

# --- dispatch_note() auto_approve path (disabled — CRITIC_AUTO_APPROVE_THRESHOLD = Inf) ----
# With Inf threshold, any finite confidence routes to enqueue, not auto_approve.
# The auto_approve branch is preserved in code but unreachable in normal operation.

test_that("dispatch_note enqueues approved note at finite confidence (auto-approve disabled)", {
  tmp_queue <- local_tempdir()
  enqueue_review <- function(...) invisible(NULL)

  result <- withVisible(dispatch_note(
    refinement_result = list(
      best_draft      = "# Note content",
      final_verdict   = list(verdict = "approved", confidence = 0.95,
                             issues = list(), source_quotes = list()),
      iteration_count = 1L, claude_used = FALSE, iteration_log = list()
    ),
    section_id   = "S2e33",
    source_text  = "source",
    dry_run      = TRUE,
    .dry_run_path = local_tempdir(),
    .queue_path   = tmp_queue
  ))
  expect_false(result$visible)
  expect_equal(result$value, "enqueued")
})

# --- dispatch_note() enqueue path --------------------------------------------

test_that("dispatch_note returns enqueued for flagged verdict above escalate threshold", {
  tmp_queue <- local_tempdir()
  enqueue_review <- function(...) invisible(NULL)

  result <- withVisible(dispatch_note(
    refinement_result = list(
      best_draft      = "content",
      final_verdict   = list(verdict = "flagged",
                             confidence = CRITIC_ESCALATE_THRESHOLD + 0.1,
                             issues = list("minor issue"),
                             source_quotes = list()),
      iteration_count = 1L, claude_used = FALSE, iteration_log = list()
    ),
    section_id   = "S2e33",
    source_text  = "source",
    dry_run      = TRUE,
    .dry_run_path = local_tempdir(),
    .queue_path   = tmp_queue
  ))
  expect_false(result$visible)
  expect_equal(result$value, "enqueued")
})

# --- dispatch_note() Phase 0: writes iteration metadata to queue ---------------

test_that("dispatch_note writes iteration_count and claude_used from refinement_result", {
  library(jsonlite)
  source(test_path("../../R/queue.R"))

  tmp_queue <- local_tempdir()
  dispatch_note(
    refinement_result = list(
      best_draft      = "draft",
      final_verdict   = list(verdict = "approved", confidence = 0.90,
                             issues = list(), source_quotes = list()),
      iteration_count = 3L,
      claude_used     = TRUE,
      iteration_log   = list(list(iteration = 1L, verdict = "flagged"))
    ),
    section_id  = "S2e33",
    source_text = "source",
    .queue_path = tmp_queue
  )
  row <- readr::read_csv(file.path(tmp_queue, "staging", "S2e33.csv"),
                         show_col_types = FALSE)
  expect_equal(row$iteration_count, 3L)
  expect_true(row$claude_used)
  expect_true(nzchar(row$iteration_log))
})

# --- Safety: no destructive operations ---------------------------------------

test_that("router.R contains no destructive file operations", {
  src <- readr::read_file(test_path("../../R/router.R"))
  expect_false(grepl("file\\.remove", src))
  expect_false(grepl("file_delete",   src))
  expect_false(grepl("\\bunlink\\b",  src))
  expect_false(grepl("dir_delete",    src))
})

# --- .entity_relative_path() -------------------------------------------------

test_that(".entity_relative_path returns correct path for npc", {
  expect_equal(.entity_relative_path("Attorrnash", "npc"), "npcs/Attorrnash.md")
})

test_that(".entity_relative_path returns correct path for location", {
  expect_equal(.entity_relative_path("the_giff_flotilla", "location"),
               "locations/the_giff_flotilla.md")
})

test_that(".entity_relative_path returns correct path for faction", {
  expect_equal(.entity_relative_path("giff_military", "faction"),
               "factions/giff_military.md")
})

test_that(".entity_relative_path stops on unknown note_type", {
  expect_error(.entity_relative_path("foo", "item"), "Unknown note_type")
})

# --- dispatch_extracted_note() ------------------------------------------------

test_that("dispatch_extracted_note enqueues approved extraction result", {
  tmp <- withr::local_tempdir()
  captured <- list()
  assign("enqueue_review", function(draft, verdict_list, section_id, source_text, ...) {
    captured$draft <<- draft
    captured$verdict <<- verdict_list$verdict
    captured$section_id <<- section_id
    invisible(NULL)
  }, envir = globalenv())
  on.exit(rm("enqueue_review", envir = globalenv()), add = TRUE)

  verification <- list(
    verdict = "approved", confidence = 0.9,
    total = 10L, supported = 9L, unsupported = 1L,
    results = list(
      list(claim = "event 1", supported = TRUE, quote = "source text"),
      list(claim = "event 2", supported = FALSE, quote = NA_character_)
    )
  )
  result <- dispatch_extracted_note("assembled draft", verification,
                                     "s02e34", "source text",
                                     .queue_path = tmp)
  expect_equal(result, "enqueued")
  expect_equal(captured$draft, "assembled draft")
  expect_equal(captured$verdict, "approved")
  expect_equal(captured$section_id, "s02e34")
})

test_that("dispatch_extracted_note passes unsupported claims as issues", {
  tmp <- withr::local_tempdir()
  captured_issues <- NULL
  assign("enqueue_review", function(draft, verdict_list, ...) {
    captured_issues <<- verdict_list$issues
    invisible(NULL)
  }, envir = globalenv())
  on.exit(rm("enqueue_review", envir = globalenv()), add = TRUE)

  verification <- list(
    verdict = "flagged", confidence = 0.5,
    total = 2L, supported = 1L, unsupported = 1L,
    results = list(
      list(claim = "good claim", supported = TRUE, quote = "proof"),
      list(claim = "bad claim", supported = FALSE, quote = NA_character_)
    )
  )
  dispatch_extracted_note("draft", verification, "s02e34", "source",
                           .queue_path = tmp)
  expect_equal(length(captured_issues), 1)
  expect_equal(captured_issues[[1]], "bad claim")
})

test_that("dispatch_extracted_note skips on skipped verdict", {
  verification <- list(
    verdict = "skipped", confidence = NA_real_,
    total = 0L, supported = 0L, unsupported = 0L, results = list()
  )
  result <- dispatch_extracted_note("draft", verification, "s02e34", "source")
  expect_null(result)
})
