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

test_that("route_verdict returns auto_approve for approved above threshold", {
  expect_equal(route_verdict("approved", CRITIC_AUTO_APPROVE_THRESHOLD),     "auto_approve")
  expect_equal(route_verdict("approved", CRITIC_AUTO_APPROVE_THRESHOLD + 0.1), "auto_approve")
})

test_that("route_verdict returns enqueue for approved below threshold", {
  # CRITIC_AUTO_APPROVE_THRESHOLD is Inf; any finite confidence is below it
  expect_equal(route_verdict("approved", 0.99), "enqueue")
  expect_equal(route_verdict("approved", 0.85), "enqueue")
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

# --- dispatch_note() auto_approve path (disabled — CRITIC_AUTO_APPROVE_THRESHOLD = Inf) ----
# With Inf threshold, any finite confidence routes to enqueue, not auto_approve.
# The auto_approve branch is preserved in code but unreachable in normal operation.

test_that("dispatch_note enqueues approved note at finite confidence (auto-approve disabled)", {
  tmp_queue <- local_tempdir()
  enqueue_review <- function(...) invisible(NULL)

  result <- withVisible(dispatch_note(
    draft        = "# Note content",
    verdict_list = list(verdict = "approved", confidence = 0.95),
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

# --- dispatch_entity_note() --------------------------------------------------

.make_entity_verdict <- function(verdict = "approved", confidence = 0.90) {
  list(verdict = verdict, confidence = confidence,
       issues = list(), source_quotes = list(),
       escalated = FALSE, claude_verdict = NA_character_)
}

test_that("dispatch_entity_note returns NULL invisibly on skipped verdict", {
  v      <- .make_entity_verdict("skipped", NA)
  result <- withVisible(
    dispatch_entity_note("draft", v, "Attorrnash", "Attorrnash", "npc",
                          list("passage"), list("S2e38"))
  )
  expect_null(result$value)
  expect_false(result$visible)
})

test_that("dispatch_entity_note enqueues approved entity at finite confidence (auto-approve disabled)", {
  tmp <- withr::local_tempdir()
  captured_id <- NULL
  assign("enqueue_review", function(draft, verdict_list, section_id, ...) {
    captured_id <<- section_id
    invisible(section_id)
  }, envir = globalenv())
  on.exit(rm("enqueue_review", envir = globalenv()), add = TRUE)

  v <- .make_entity_verdict("approved", 0.95)  # finite confidence → enqueue with Inf threshold
  dispatch_entity_note("draft", v, "Attorrnash", "Attorrnash", "npc",
                        list("passage"), list("S2e38"),
                        .vault_path = tmp, .dry_run_path = tmp,
                        .queue_path = tmp)
  expect_equal(captured_id, "Attorrnash")
})

test_that("dispatch_entity_note enqueue calls enqueue_review with entity_id as section_id", {
  tmp <- withr::local_tempdir()
  captured_id <- NULL
  assign("enqueue_review", function(draft, verdict_list, section_id, ...) {
    captured_id <<- section_id
    invisible(section_id)
  }, envir = globalenv())
  on.exit(rm("enqueue_review", envir = globalenv()), add = TRUE)

  v <- .make_entity_verdict("approved", 0.50)  # below auto-approve threshold → enqueue
  dispatch_entity_note("draft", v, "Attorrnash", "Attorrnash", "npc",
                        list("passage"), list("S2e38"),
                        .vault_path = tmp, .dry_run_path = tmp,
                        .queue_path = tmp)
  expect_equal(captured_id, "Attorrnash")
})

test_that("dispatch_entity_note supplement path calls supplement_note when note exists (via auto_approve with Inf confidence)", {
  tmp <- withr::local_tempdir()
  note_path <- file.path(tmp, "npcs", "Attorrnash.md")
  dir.create(dirname(note_path), recursive = TRUE)
  writeLines("---\ntags: [npc]\nname: Attorrnash\nreview_required: false\n---\n\n## Session Appearances\n-\n\n## GM Notes\n",
             note_path)

  assign("note_exists",     function(...) TRUE,    envir = globalenv())
  assign("get_output_path", function(...) note_path, envir = globalenv())
  supplement_called <- FALSE
  assign("supplement_note", function(...) { supplement_called <<- TRUE; "merged" },
         envir = globalenv())
  assign("write_note", function(...) invisible(NULL), envir = globalenv())
  on.exit(rm("note_exists", "get_output_path", "supplement_note", "write_note",
             envir = globalenv()), add = TRUE)

  # Inf confidence triggers the auto_approve branch (confidence >= Inf is TRUE),
  # exercising the supplement_note path even though auto-approve is effectively disabled.
  v <- .make_entity_verdict("approved", Inf)
  dispatch_entity_note("draft", v, "Attorrnash", "Attorrnash", "npc",
                        list("passage"), list("S2e38"),
                        dry_run = TRUE,
                        .vault_path = tmp, .dry_run_path = tmp,
                        .queue_path = tmp)
  expect_true(supplement_called)
})
