library(testthat)
library(withr)
library(jsonlite)

source(test_path("../../config.R"))
source(test_path("../../R/queue.R"))
source(test_path("../../R/ollama.R"))
source(test_path("../../R/agentic_extract.R"))
source(test_path("../../R/agentic_entity_schemas.R"))
source(test_path("../../R/agentic_entity_extract.R"))
source(test_path("../../R/agentic_entity_writer.R"))
source(test_path("../../R/agentic_entity_fact_check.R"))
source(test_path("../../R/regen.R"))

# Helpers ---------------------------------------------------------------------

make_verdict <- function(verdict = "flagged", confidence = 0.7,
                         issues = list("minor issue"), source_quotes = list("quote")) {
  list(verdict = verdict, confidence = confidence,
       issues = issues, source_quotes = source_quotes)
}

# Stub a function in globalenv, restoring the original (or removing if it was
# absent) when the calling test's frame exits. Needed because the real
# extract_entity / regenerate_entity_draft are sourced into globalenv at the top
# of this file — a plain assign()+rm() pattern would delete the real binding.
.stub_global <- function(name, fn, .envir = parent.frame()) {
  had <- exists(name, envir = globalenv(), inherits = FALSE)
  old <- if (had) get(name, envir = globalenv()) else NULL
  assign(name, fn, envir = globalenv())
  withr::defer(
    if (had) assign(name, old, envir = globalenv())
    else if (exists(name, envir = globalenv(), inherits = FALSE))
      rm(list = name, envir = globalenv()),
    envir = .envir
  )
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

test_that("regen_worker processes npc row via agentic regenerate_entity_draft", {
  tmp <- local_tempdir()
  .make_queue(tmp, section_id = "npc-elara", note_type = "npc",
              entity_name = "Elara",
              source_text = "passage one\n\n---\n\npassage two",
              existing_note = "# Elara\nold content",
              user_feedback = "add her motivation")
  writeLines(character(0), file.path(tmp, ".regen.lock"))

  capture <- list()
  .stub_global("regenerate_entity_draft", function(row, user_feedback = NULL, ...) {
    capture[[length(capture) + 1]] <<- list(
      entity_name   = row$entity_name,
      n_passages    = length(strsplit(row$source_text, "\n\n---\n\n",
                                      fixed = TRUE)[[1]]),
      user_feedback = user_feedback
    )
    list(markdown = "---\ntags: [npc]\n## Overview\nregenerated",
         verdict  = list(verdict = "agentic_no_critic", confidence = 0.8,
                         issues = list(), source_quotes = list()))
  })

  regen_worker(file.path(tmp, "queue.csv"))

  expect_equal(capture[[1]]$entity_name,   "Elara")
  expect_equal(capture[[1]]$n_passages,    2L)
  expect_equal(capture[[1]]$user_feedback, "add her motivation")

  df <- readr::read_csv(file.path(tmp, "queue.csv"), show_col_types = FALSE)
  expect_equal(df$status[df$section_id == "npc-elara"], "pending")
  expect_equal(df$draft[df$section_id == "npc-elara"],
               "---\ntags: [npc]\n## Overview\nregenerated")
})

# regenerate_entity_draft() — row -> entity_record mapping ---------------------

test_that("regenerate_entity_draft builds entity_record from row fields", {
  captured_record <- NULL
  .stub_global("extract_entity", function(entity_record, user_feedback = NULL, ...) {
    captured_record <<- entity_record
    list(entity_id = entity_record$entity_id, note_type = entity_record$note_type,
         extraction = list(description = list(value = "x", line = 1L)),
         timed_out = FALSE, pipeline_path = "substring_grounding",
         existing_note = "")
  })
  .stub_global("assemble_entity_markdown",
         function(extraction, entity_record, existing_note = "", ...) "## md")
  .stub_global("fact_check_entity",
         function(entity_id, draft_markdown, source_passages, existing_note = "", ...)
           list(coverage_score = 0.75, matched_claims = "a", unmatched_claims = character(0),
                aps_proposition_count = 1L, pipeline_path = "substring_grounding"))

  row <- data.frame(
    section_id         = "npc-elara",
    entity_name        = "Elara",
    note_type          = "npc",
    source_text        = "p1\n\n---\n\np2\n\n---\n\n",
    source_episode_ids = '["s02e34","s02e35"]',
    stringsAsFactors   = FALSE
  )

  res <- regenerate_entity_draft(row)

  expect_equal(captured_record$entity_id,          "npc-elara")
  expect_equal(captured_record$entity_name,        "Elara")
  expect_equal(captured_record$note_type,          "npc")
  expect_equal(captured_record$source_passages,    c("p1", "p2"))  # empty dropped
  expect_equal(captured_record$source_episode_ids, c("s02e34", "s02e35"))
})

test_that("regenerate_entity_draft falls back to character(0) on bad episode JSON", {
  captured_record <- NULL
  .stub_global("extract_entity", function(entity_record, user_feedback = NULL, ...) {
    captured_record <<- entity_record
    list(extraction = list(x = 1), timed_out = FALSE, existing_note = "")
  })
  .stub_global("assemble_entity_markdown",
         function(extraction, entity_record, existing_note = "", ...) "## md")
  .stub_global("fact_check_entity",
         function(entity_id, draft_markdown, source_passages, existing_note = "", ...)
           list(coverage_score = 0.5))

  row <- data.frame(
    section_id = "npc-x", entity_name = "X", note_type = "npc",
    source_text = "p1", source_episode_ids = "not json",
    stringsAsFactors = FALSE
  )
  res <- regenerate_entity_draft(row)
  expect_equal(captured_record$source_episode_ids, character(0))
})

# regenerate_entity_draft() — verdict shape -----------------------------------

test_that("regenerate_entity_draft returns markdown + agentic verdict with coverage confidence", {
  .stub_global("extract_entity", function(entity_record, user_feedback = NULL, ...)
    list(extraction = list(x = 1), timed_out = FALSE, existing_note = ""))
  .stub_global("assemble_entity_markdown",
         function(extraction, entity_record, existing_note = "", ...) "## generated md")
  .stub_global("fact_check_entity",
         function(entity_id, draft_markdown, source_passages, existing_note = "", ...)
           list(coverage_score = 0.42, matched_claims = "c",
                unmatched_claims = character(0), aps_proposition_count = 2L,
                pipeline_path = "substring_grounding"))

  row <- data.frame(section_id = "npc-y", entity_name = "Y", note_type = "npc",
                    source_text = "p1", source_episode_ids = "[]",
                    stringsAsFactors = FALSE)
  res <- regenerate_entity_draft(row)

  expect_equal(res$markdown, "## generated md")
  expect_equal(res$verdict$verdict, "agentic_no_critic")
  expect_equal(res$verdict$confidence, 0.42)            # == coverage_score
  expect_equal(res$verdict$issues, list())
  expect_equal(res$verdict$source_quotes, list())
})

# regenerate_entity_draft() — NULL extraction ---------------------------------

test_that("regenerate_entity_draft returns NULL when extraction times out", {
  .stub_global("extract_entity", function(entity_record, user_feedback = NULL, ...)
    list(extraction = NULL, timed_out = TRUE, existing_note = ""))

  row <- data.frame(section_id = "npc-z", entity_name = "Z", note_type = "npc",
                    source_text = "p1", source_episode_ids = "[]",
                    stringsAsFactors = FALSE)
  expect_null(regenerate_entity_draft(row))
})

test_that("regenerate_entity_draft returns NULL when extraction is NULL", {
  .stub_global("extract_entity", function(entity_record, user_feedback = NULL, ...) NULL)

  row <- data.frame(section_id = "npc-z", entity_name = "Z", note_type = "npc",
                    source_text = "p1", source_episode_ids = "[]",
                    stringsAsFactors = FALSE)
  expect_null(regenerate_entity_draft(row))
})

# extract_entity() — user_feedback reaches the prompt -------------------------

test_that("extract_entity appends reviewer feedback to the user prompt", {
  captured_prompt <- NULL
  .stub_global("ollama_generate", function(prompt, system_prompt, ...) {
    captured_prompt <<- prompt
    '{"description": {"value": null, "line": null}, "aliases": [], "exhibited_personality": {"value": null, "line": null}, "role_in_story": {"value": null, "line": null}}'
  })

  rec <- list(entity_id = "npc-fb", entity_name = "Feedback NPC", note_type = "npc",
              source_passages = "Some passage about the npc.",
              source_episode_ids = "s02e34")
  extract_entity(rec, skills_dir = test_path("../../agents/wiki_skills"),
                 user_feedback = "Clarify her allegiance.")

  expect_true(grepl("REVIEWER FEEDBACK", captured_prompt, fixed = TRUE))
  expect_true(grepl("Clarify her allegiance.", captured_prompt, fixed = TRUE))
})

test_that("extract_entity omits feedback block when user_feedback is NULL", {
  captured_prompt <- NULL
  .stub_global("ollama_generate", function(prompt, system_prompt, ...) {
    captured_prompt <<- prompt
    '{"description": {"value": null, "line": null}, "aliases": [], "exhibited_personality": {"value": null, "line": null}, "role_in_story": {"value": null, "line": null}}'
  })

  rec <- list(entity_id = "npc-fb", entity_name = "Feedback NPC", note_type = "npc",
              source_passages = "Some passage about the npc.",
              source_episode_ids = "s02e34")
  extract_entity(rec, skills_dir = test_path("../../agents/wiki_skills"))

  expect_false(grepl("REVIEWER FEEDBACK", captured_prompt, fixed = TRUE))
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
