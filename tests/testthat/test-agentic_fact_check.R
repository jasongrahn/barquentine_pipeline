library(testthat)
suppressPackageStartupMessages({
  library(dplyr); library(stringr); library(tibble)
})
source(test_path("../../R/agentic_fact_check.R"))

# ---------------------------------------------------------------------------
# verify_line_citations() — line citation correctness + claim propagation
# ---------------------------------------------------------------------------

raw_lines_fx <- c(
  "Room: I never got the chance to look back at the city.",
  "The Admiral: You're at the dock.",
  "The Captain: May fate be with you."
)
vtt_fx <- list(raw_lines = raw_lines_fx)

test_that("supported rows are marked TRUE and unsupported FALSE with kind+line", {
  merged <- list(
    events    = data.frame(line = c(1L, 99L), event = c("ok", "out-of-range"),
                            type = c("pc_action", "pc_action"),
                            stringsAsFactors = FALSE),
    npcs      = tibble(name = "Room", description = "x",
                       appeared = 1L, line = 1L),
    locations = tibble(name = "dock", description = "y", line = 2L),
    dialogue  = tibble(speaker = c("Room","The Captain"),
                       line = c(1L, 3L),
                       dialogue = c("I never got the chance",
                                    "actually missing"),
                       context = c("","")
                      )
  )
  fc <- verify_line_citations(merged, vtt_fx)

  expect_equal(fc$n_checked, 6L)
  # one unsupported event (line 99 OOR), one unsupported dialogue (quote missing)
  expect_equal(fc$n_unsupported, 2L)
  expect_true(all(c("kind","line","supported","claim") %in% names(fc$results)))
})

test_that("results carry the claim text so the reviewer can identify the failing item", {
  merged <- list(
    events    = data.frame(line = 99L, event = "an OOR claim",
                            type = "pc_action", stringsAsFactors = FALSE),
    npcs      = tibble(name = character(), description = character(),
                       appeared = integer(), line = integer()),
    locations = tibble(name = character(), description = character(),
                       line = integer()),
    dialogue  = tibble(speaker = "Room", line = 1L,
                       dialogue = "something not in source",
                       context = "")
  )
  fc <- verify_line_citations(merged, vtt_fx)
  unsup <- fc$results[!fc$results$supported, ]
  expect_equal(nrow(unsup), 2L)
  # Event claim text retained
  expect_true("an OOR claim"            %in% unsup$claim)
  # Dialogue claim text retained
  expect_true("something not in source" %in% unsup$claim)
})

# ---------------------------------------------------------------------------
# dispatch_agentic_session — issues array populated from fact_check
# ---------------------------------------------------------------------------

# Stub enqueue_review at the global env so dispatch_agentic_session can find
# it without sourcing R/queue.R (which pulls in jsonlite/readr/fs).
suppressPackageStartupMessages({ library(jsonlite) })
source(test_path("../../R/router.R"))         # provides route_verdict()
source(test_path("../../R/agentic_writer.R")) # provides agentic_section_id()
source(test_path("../../R/agentic_dispatch.R"))

test_that("dispatch_agentic_session propagates unsupported fact_check rows into verdict_list$issues", {
  captured <- new.env(parent = emptyenv())
  assign("enqueue_review", function(draft, verdict_list, section_id, source_text,
                                     ...) {
    captured$verdict_list <- verdict_list
    captured$section_id   <- section_id
    invisible(section_id)
  }, envir = globalenv())
  withr::defer(rm("enqueue_review", envir = globalenv()))

  results <- tibble(
    kind      = c("dialogue", "dialogue", "event"),
    line      = c(1L, 5L, NA_integer_),
    supported = c(FALSE, TRUE, FALSE),
    claim     = c("\"May fate be with you.\"", "supported text", "ungrounded event")
  )
  fact_check <- list(
    n_checked     = 3L,
    n_unsupported = 2L,
    confidence    = 1/3,
    results       = results
  )

  dispatch_agentic_session(
    markdown    = "# session\nbody\n",
    session_id  = "s02e99",
    source_text = "some source text",
    fact_check  = fact_check,
    .queue_path = tempdir()
  )

  vl <- captured$verdict_list
  expect_equal(vl$verdict, "agentic_no_critic")
  expect_length(vl$issues, 2L)
  joined <- paste(unlist(vl$issues), collapse = " | ")
  expect_true(grepl("dialogue, line 1", joined))
  expect_true(grepl("event, no line cited", joined))
  expect_true(grepl("May fate be with you", joined))
})

test_that("dispatch_agentic_session leaves issues empty when fact_check has no unsupported rows", {
  captured <- new.env(parent = emptyenv())
  assign("enqueue_review", function(draft, verdict_list, section_id, source_text,
                                     ...) {
    captured$verdict_list <- verdict_list
    invisible(section_id)
  }, envir = globalenv())
  withr::defer(rm("enqueue_review", envir = globalenv()))

  results <- tibble(kind = "dialogue", line = 1L, supported = TRUE,
                    claim = "ok")
  fact_check <- list(n_checked = 1L, n_unsupported = 0L,
                     confidence = 1, results = results)

  dispatch_agentic_session(markdown    = "# session\n",
                           session_id  = "s02e99",
                           source_text = "x",
                           fact_check  = fact_check,
                           .queue_path = tempdir())
  expect_length(captured$verdict_list$issues, 0L)
})
