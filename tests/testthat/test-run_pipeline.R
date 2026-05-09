library(testthat)
library(withr)
library(jsonlite)

source(test_path("../../config.R"))
source(test_path("../../R/queue.R"))
source(test_path("../../scripts/run_pipeline.R"))

# ---- .previous_session_id ---------------------------------------------------

test_that(".previous_session_id decrements zero-padded episode number", {
  expect_equal(.previous_session_id("s02e42"), "s02e41")
  expect_equal(.previous_session_id("s01e13"), "s01e12")
  expect_equal(.previous_session_id("s02e10"), "s02e09")
})

test_that(".previous_session_id returns NULL for first episode of a season", {
  expect_null(.previous_session_id("s01e01"))
  expect_null(.previous_session_id("s02e01"))
})

test_that(".previous_session_id returns NULL on unparseable input", {
  expect_null(.previous_session_id(NULL))
  expect_null(.previous_session_id(""))
  expect_null(.previous_session_id("not-a-session"))
  expect_null(.previous_session_id(c("s01e01", "s01e02")))
})

# ---- .session_in_vault ------------------------------------------------------

test_that(".session_in_vault returns FALSE when sessions dir does not exist", {
  vault <- local_tempdir()
  expect_false(.session_in_vault("s02e41", vault))
})

test_that(".session_in_vault returns TRUE when session note exists", {
  vault <- local_tempdir()
  dir.create(file.path(vault, "sessions"))
  writeLines("# notes", file.path(vault, "sessions", "s02e41.md"))
  expect_true(.session_in_vault("s02e41", vault))
})

test_that(".session_in_vault accepts gap-placeholder file as evidence", {
  vault <- local_tempdir()
  dir.create(file.path(vault, "sessions"))
  writeLines("---\ngap: true\n---\n",
             file.path(vault, "sessions", "s01e07.md"))
  expect_true(.session_in_vault("s01e07", vault))
})

# ---- .assert_session_ordering ----------------------------------------------

test_that(".assert_session_ordering skips check when PROCESS_ONE_SESSION is FALSE", {
  vault <- local_tempdir()
  with_envvar(c(), {
    PROCESS_ONE_SESSION <<- FALSE
    on.exit(PROCESS_ONE_SESSION <<- TRUE, add = TRUE)
    expect_true(.assert_session_ordering("s02e42", vault))
  })
})

test_that(".assert_session_ordering passes for first episode of a season", {
  vault <- local_tempdir()
  expect_true(.assert_session_ordering("s01e01", vault))
})

test_that(".assert_session_ordering passes when previous session is in vault", {
  vault <- local_tempdir()
  dir.create(file.path(vault, "sessions"))
  writeLines("# done", file.path(vault, "sessions", "s02e41.md"))
  expect_true(.assert_session_ordering("s02e42", vault))
})

test_that(".assert_session_ordering errors with informative message when prev session missing", {
  vault <- local_tempdir()
  expect_error(
    .assert_session_ordering("s02e42", vault),
    regexp = "Session ordering violation.*s02e41"
  )
})

test_that(".assert_session_ordering error message recommends write_placeholder_note", {
  vault <- local_tempdir()
  expect_error(
    .assert_session_ordering("s02e42", vault),
    regexp = "write_placeholder_note"
  )
})

test_that(".assert_session_ordering passes when current_session is NULL", {
  vault <- local_tempdir()
  expect_true(.assert_session_ordering(NULL, vault))
})

# ---- run_pipeline auto-detect (Step 2.6 wiring) ----------------------------

# ---- .has_cap_hit -----------------------------------------------------------

test_that(".has_cap_hit returns FALSE for empty / missing input", {
  expect_false(.has_cap_hit(NA))
  expect_false(.has_cap_hit(NA_character_))
  expect_false(.has_cap_hit(""))
  expect_false(.has_cap_hit("[]"))
  expect_false(.has_cap_hit(NULL))
})

test_that(".has_cap_hit detects cap_hit entries", {
  log <- toJSON(list(
    list(iteration = 1L, escalation_reason = NULL),
    list(iteration = 2L, escalation_reason = "cap_hit")
  ), auto_unbox = TRUE, null = "null")
  expect_true(.has_cap_hit(log))
})

test_that(".has_cap_hit returns FALSE when only ollama_timeout is present", {
  log <- toJSON(list(
    list(iteration = 1L, escalation_reason = "ollama_timeout")
  ), auto_unbox = TRUE)
  expect_false(.has_cap_hit(log))
})

test_that(".has_cap_hit tolerates malformed JSON", {
  expect_false(.has_cap_hit("{not valid json"))
})

# ---- .compute_run_summary --------------------------------------------------

# Helper: write a queue.csv with given rows under a temp queue path.
.write_test_queue <- function(rows, queue_path) {
  dir.create(queue_path, showWarnings = FALSE, recursive = TRUE)
  csv_path <- file.path(queue_path, "queue.csv")
  readr::write_csv(rows, csv_path)
  invisible(csv_path)
}

# Helper: build a single queue row data.frame with sensible defaults.
.queue_row <- function(section_id, enqueued_at, verdict = "approved",
                       iteration_count = 1L, claude_used = FALSE,
                       iteration_log = "[]") {
  data.frame(
    section_id        = section_id,
    status            = "pending",
    training_exported = FALSE,
    draft             = "draft",
    final_draft       = NA_character_,
    source_text       = "src",
    verdict           = verdict,
    confidence        = 0.7,
    issues            = "[]",
    source_quotes     = "[]",
    escalated         = FALSE,
    claude_verdict    = NA_character_,
    enqueued_at       = enqueued_at,
    resolved_at       = NA_character_,
    note_type         = "session",
    entity_name       = NA_character_,
    chunk_count       = NA_integer_,
    source_episode_ids = NA_character_,
    existing_note     = NA_character_,
    status_detail     = NA_character_,
    merged_into       = NA_character_,
    last_action_at    = NA_character_,
    iteration_count   = as.integer(iteration_count),
    claude_used       = isTRUE(claude_used),
    iteration_log     = iteration_log,
    stringsAsFactors  = FALSE
  )
}

test_that(".compute_run_summary returns empty summary when queue.csv is missing", {
  qp <- local_tempdir()
  s  <- .compute_run_summary(Sys.time() - 60, queue_path = qp)
  expect_equal(s$sections_processed, 0L)
  expect_equal(s$passed_first_attempt, 0L)
  expect_true(is.na(s$avg_iterations_flagged))
  expect_equal(s$hit_iteration_cap, 0L)
  expect_equal(s$claude_escalations, 0L)
  expect_equal(s$est_claude_cost_usd, 0)
})

test_that(".compute_run_summary filters rows older than run_start_time", {
  qp <- local_tempdir()
  rows <- rbind(
    .queue_row("s02e01_old", "2020-01-01T00:00:00"),
    .queue_row("s02e01_new", format(Sys.time() + 5, "%Y-%m-%dT%H:%M:%S"))
  )
  .write_test_queue(rows, qp)
  s <- .compute_run_summary(Sys.time() - 60, queue_path = qp)
  expect_equal(s$sections_processed, 1L)
})

test_that(".compute_run_summary counts passed_first_attempt only when iter==1, no claude, approved", {
  qp <- local_tempdir()
  ts <- format(Sys.time() + 5, "%Y-%m-%dT%H:%M:%S")
  rows <- rbind(
    .queue_row("a", ts, verdict = "approved", iteration_count = 1L, claude_used = FALSE),
    .queue_row("b", ts, verdict = "approved", iteration_count = 1L, claude_used = TRUE),
    .queue_row("c", ts, verdict = "approved", iteration_count = 2L, claude_used = FALSE),
    .queue_row("d", ts, verdict = "flagged",  iteration_count = 1L, claude_used = FALSE)
  )
  .write_test_queue(rows, qp)
  s <- .compute_run_summary(Sys.time() - 60, queue_path = qp)
  expect_equal(s$sections_processed, 4L)
  expect_equal(s$passed_first_attempt, 1L)
})

test_that(".compute_run_summary computes avg_iterations across flagged + rejected only", {
  qp <- local_tempdir()
  ts <- format(Sys.time() + 5, "%Y-%m-%dT%H:%M:%S")
  rows <- rbind(
    .queue_row("a", ts, verdict = "approved", iteration_count = 1L),
    .queue_row("b", ts, verdict = "flagged",  iteration_count = 2L),
    .queue_row("c", ts, verdict = "flagged",  iteration_count = 4L),
    .queue_row("d", ts, verdict = "rejected", iteration_count = 3L)
  )
  .write_test_queue(rows, qp)
  s <- .compute_run_summary(Sys.time() - 60, queue_path = qp)
  expect_equal(s$avg_iterations_flagged, 3.0)
})

test_that(".compute_run_summary sets avg NA when no flagged sections", {
  qp <- local_tempdir()
  ts <- format(Sys.time() + 5, "%Y-%m-%dT%H:%M:%S")
  rows <- .queue_row("a", ts, verdict = "approved")
  .write_test_queue(rows, qp)
  s <- .compute_run_summary(Sys.time() - 60, queue_path = qp)
  expect_true(is.na(s$avg_iterations_flagged))
})

test_that(".compute_run_summary counts cap_hit and claude escalations distinctly", {
  qp <- local_tempdir()
  ts <- format(Sys.time() + 5, "%Y-%m-%dT%H:%M:%S")
  cap_log <- toJSON(list(
    list(iteration = 1L, escalation_reason = NULL),
    list(iteration = 2L, escalation_reason = "cap_hit")
  ), auto_unbox = TRUE, null = "null")
  to_log <- toJSON(list(
    list(iteration = 1L, escalation_reason = "ollama_timeout")
  ), auto_unbox = TRUE)
  rows <- rbind(
    .queue_row("a", ts, verdict = "flagged", claude_used = TRUE,
               iteration_log = cap_log, iteration_count = 2L),
    .queue_row("b", ts, verdict = "flagged", claude_used = TRUE,
               iteration_log = to_log, iteration_count = 1L),
    .queue_row("c", ts, verdict = "approved", claude_used = FALSE)
  )
  .write_test_queue(rows, qp)
  s <- .compute_run_summary(Sys.time() - 60, queue_path = qp)
  expect_equal(s$claude_escalations, 2L)
  expect_equal(s$hit_iteration_cap, 1L)
  expect_equal(s$est_claude_cost_usd, 0.08)
})

# ---- .format_run_summary ---------------------------------------------------

test_that(".format_run_summary renders all fields", {
  out <- .format_run_summary(list(
    sections_processed     = 8L,
    passed_first_attempt   = 3L,
    avg_iterations_flagged = 2.4,
    hit_iteration_cap      = 1L,
    claude_escalations     = 1L,
    est_claude_cost_usd    = 0.04
  ))
  expect_match(out, "Sections processed:\\s+8")
  expect_match(out, "Passed first attempt:\\s+3")
  expect_match(out, "Avg iterations \\(flagged sections\\):\\s+2\\.4")
  expect_match(out, "Hit iteration cap:\\s+1")
  expect_match(out, "Claude escalations:\\s+1")
  expect_match(out, "Est\\. Claude cost:\\s+\\$0\\.04")
})

test_that(".format_run_summary renders em-dash when avg is NA", {
  out <- .format_run_summary(list(
    sections_processed     = 0L,
    passed_first_attempt   = 0L,
    avg_iterations_flagged = NA_real_,
    hit_iteration_cap      = 0L,
    claude_escalations     = 0L,
    est_claude_cost_usd    = 0
  ))
  expect_match(out, "Avg iterations \\(flagged sections\\):\\s+\u2014")
})

# ---- run_pipeline auto-detect (Step 2.6 wiring) ----------------------------

test_that("run_pipeline errors clearly when CURRENT_SESSION is NULL and registry empty", {
  source(test_path("../../R/source_b.R"))
  # Stub tar_make so it does not actually try to run the targets pipeline
  assign("tar_make", function(...) invisible(NULL), envir = globalenv())
  on.exit(rm("tar_make", envir = globalenv()), add = TRUE)

  prev <- CURRENT_SESSION
  CURRENT_SESSION <<- NULL
  on.exit(CURRENT_SESSION <<- prev, add = TRUE)

  # Point at a non-existent registry
  prev_reg <- DOC_REGISTRY_PATH
  DOC_REGISTRY_PATH <<- tempfile()
  on.exit(DOC_REGISTRY_PATH <<- prev_reg, add = TRUE)

  expect_error(run_pipeline(), regexp = "auto-detected.*NULL|next_unprocessed_session")
})
