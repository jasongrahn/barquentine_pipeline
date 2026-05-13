library(testthat)
source(test_path("../../config.R"))
source(test_path("../../R/queue.R"))
source(test_path("../../R/router.R"))
source(test_path("../../R/agentic_entity_dispatch.R"))

make_entity_record <- function(note_type = "npc") {
  list(
    entity_id          = "attorrnash",
    entity_name        = "Attorrnash",
    note_type          = note_type,
    source_passages    = c("Passage one about attorrnash.", "Passage two."),
    source_episode_ids = c("s02e34")
  )
}

make_fact_check <- function(n_checked = 2L, n_unsupported = 0L,
                             confidence = 1.0) {
  list(
    n_checked     = as.integer(n_checked),
    n_unsupported = as.integer(n_unsupported),
    confidence    = confidence,
    results       = tibble::tibble(
      kind      = character(0),
      line      = integer(0),
      supported = logical(0),
      claim     = character(0)
    )
  )
}

# ---- dispatch_agentic_entity — basic enqueue --------------------------------

test_that("dispatch_agentic_entity enqueues and returns 'enqueued'", {
  enqueue_calls <- list()
  assign("enqueue_review", function(...) {
    enqueue_calls[[length(enqueue_calls) + 1L]] <<- list(...)
    invisible(NULL)
  }, envir = globalenv())
  on.exit(rm("enqueue_review", envir = globalenv()), add = TRUE)

  tmp    <- withr::local_tempfile(fileext = ".csv")
  result <- dispatch_agentic_entity(
    markdown          = "# Attorrnash\nSome content.",
    entity_record     = make_entity_record("npc"),
    fact_check_summary = make_fact_check(),
    .queue_path       = tmp
  )

  expect_equal(result, "enqueued")
  expect_equal(length(enqueue_calls), 1L)
})

test_that("dispatch_agentic_entity passes correct note_type to enqueue_review", {
  received_note_type <- NULL
  assign("enqueue_review", function(...) {
    args <- list(...)
    received_note_type <<- args$note_type
    invisible(NULL)
  }, envir = globalenv())
  on.exit(rm("enqueue_review", envir = globalenv()), add = TRUE)

  tmp <- withr::local_tempfile(fileext = ".csv")
  dispatch_agentic_entity("# PC\nContent.", make_entity_record("pc"),
                           make_fact_check(), .queue_path = tmp)

  expect_equal(received_note_type, "pc")
})

test_that("dispatch_agentic_entity uses verdict = 'agentic_no_critic'", {
  received_verdict_list <- NULL
  assign("enqueue_review", function(...) {
    args <- list(...)
    received_verdict_list <<- args$verdict_list
    invisible(NULL)
  }, envir = globalenv())
  on.exit(rm("enqueue_review", envir = globalenv()), add = TRUE)

  tmp <- withr::local_tempfile(fileext = ".csv")
  dispatch_agentic_entity("# NPC\nContent.", make_entity_record(),
                           make_fact_check(), .queue_path = tmp)

  expect_equal(received_verdict_list$verdict, "agentic_no_critic")
})

# ---- issues surfacing -------------------------------------------------------

test_that("unsupported citations are surfaced as issues in the verdict", {
  received_verdict_list <- NULL
  assign("enqueue_review", function(...) {
    args <- list(...)
    received_verdict_list <<- args$verdict_list
    invisible(NULL)
  }, envir = globalenv())
  on.exit(rm("enqueue_review", envir = globalenv()), add = TRUE)

  fc <- list(
    n_checked     = 2L,
    n_unsupported = 1L,
    confidence    = 0.5,
    results       = tibble::tibble(
      kind      = c("name",        "description"),
      line      = c(3L,            1L),
      supported = c(FALSE,         TRUE),
      claim     = c("some claim",  "a real claim")
    )
  )

  tmp <- withr::local_tempfile(fileext = ".csv")
  dispatch_agentic_entity("# NPC\nContent.", make_entity_record(), fc, .queue_path = tmp)

  expect_equal(length(received_verdict_list$issues), 1L)
  expect_true(grepl("line 3", received_verdict_list$issues[[1L]]))
  expect_true(grepl("not grounded", received_verdict_list$issues[[1L]]))
})

# ---- NA confidence (all-null extraction) ------------------------------------

test_that("NA confidence still enqueues (not skipped)", {
  enqueued <- FALSE
  assign("enqueue_review", function(...) {
    enqueued <<- TRUE
    invisible(NULL)
  }, envir = globalenv())
  on.exit(rm("enqueue_review", envir = globalenv()), add = TRUE)

  fc  <- make_fact_check(n_checked = 0L, n_unsupported = 0L, confidence = NA_real_)
  tmp <- withr::local_tempfile(fileext = ".csv")
  dispatch_agentic_entity("# NPC\nContent.", make_entity_record(), fc, .queue_path = tmp)

  expect_true(enqueued)
})

# ---- empty markdown guard ---------------------------------------------------

test_that("empty markdown throws an error", {
  tmp <- withr::local_tempfile(fileext = ".csv")
  expect_error(
    dispatch_agentic_entity("", make_entity_record(), make_fact_check(), .queue_path = tmp),
    "empty markdown"
  )
})
