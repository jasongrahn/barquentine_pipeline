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

make_fact_check <- function(coverage_score   = 0.8,
                             matched_claims   = c("Attorrnash is an NPC."),
                             unmatched_claims = character(0),
                             pipeline_path    = "aps_grounding") {
  list(
    matched_claims        = matched_claims,
    unmatched_claims      = unmatched_claims,
    coverage_score        = coverage_score,
    aps_proposition_count = 3L,
    pipeline_path         = pipeline_path
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
    markdown           = "# Attorrnash\nSome content.",
    entity_record      = make_entity_record("npc"),
    fact_check_summary = make_fact_check(),
    .queue_path        = tmp
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

# ---- APS grounding fields ---------------------------------------------------

test_that("coverage_score and claim counts passed to enqueue_review", {
  received_args <- NULL
  assign("enqueue_review", function(...) {
    received_args <<- list(...)
    invisible(NULL)
  }, envir = globalenv())
  on.exit(rm("enqueue_review", envir = globalenv()), add = TRUE)

  fc <- make_fact_check(
    coverage_score   = 0.6,
    matched_claims   = c("Claim A.", "Claim B."),
    unmatched_claims = c("Ungrounded claim.")
  )
  tmp <- withr::local_tempfile(fileext = ".csv")
  dispatch_agentic_entity("# NPC\nContent.", make_entity_record(), fc, .queue_path = tmp)

  expect_equal(received_args$coverage_score, 0.6)
  expect_equal(received_args$matched_claim_count, 2L)
  expect_equal(received_args$unmatched_claim_count, 1L)
  expect_equal(received_args$pipeline_path, "aps_grounding")
})

test_that("aps_error pipeline_path is forwarded", {
  received_args <- NULL
  assign("enqueue_review", function(...) {
    received_args <<- list(...)
    invisible(NULL)
  }, envir = globalenv())
  on.exit(rm("enqueue_review", envir = globalenv()), add = TRUE)

  fc <- make_fact_check(coverage_score = NA_real_, matched_claims = character(0),
                         unmatched_claims = character(0), pipeline_path = "aps_error")
  tmp <- withr::local_tempfile(fileext = ".csv")
  dispatch_agentic_entity("# NPC\nContent.", make_entity_record(), fc, .queue_path = tmp)

  expect_equal(received_args$pipeline_path, "aps_error")
  expect_true(is.na(received_args$coverage_score))
})

# ---- NA coverage still enqueues ---------------------------------------------

test_that("NA coverage_score still enqueues (not skipped)", {
  enqueued <- FALSE
  assign("enqueue_review", function(...) {
    enqueued <<- TRUE
    invisible(NULL)
  }, envir = globalenv())
  on.exit(rm("enqueue_review", envir = globalenv()), add = TRUE)

  fc  <- make_fact_check(coverage_score = NA_real_, pipeline_path = "aps_error",
                          matched_claims = character(0), unmatched_claims = character(0))
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
