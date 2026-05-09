library(testthat)
library(httr2)

source(test_path("../../config.R"))
source(test_path("../../R/ollama.R"))
source(test_path("../../R/extract.R"))

# --- is_sparse() -------------------------------------------------------------

test_that("is_sparse returns TRUE for empty string", {
  expect_true(is_sparse(""))
})

test_that("is_sparse returns TRUE for text under 100 words", {
  short_text <- paste(rep("word", 50), collapse = " ")
  expect_true(is_sparse(short_text))
})

test_that("is_sparse returns TRUE for text at exactly 99 words", {
  text_99 <- paste(rep("word", 99), collapse = " ")
  expect_true(is_sparse(text_99))
})

test_that("is_sparse returns FALSE for text at exactly 100 words", {
  text_100 <- paste(rep("word", 100), collapse = " ")
  expect_false(is_sparse(text_100))
})

test_that("is_sparse returns FALSE for text over 100 words", {
  long_text <- paste(rep("word", 200), collapse = " ")
  expect_false(is_sparse(long_text))
})

# --- session_prompt() --------------------------------------------------------

test_that("session_prompt returns a character string", {
  result <- session_prompt("S2e33", "Some prep notes here.")
  expect_type(result, "character")
  expect_equal(length(result), 1L)
})

test_that("session_prompt interpolates episode_id into the output", {
  result <- session_prompt("S2e33", "Some content.")
  expect_true(grepl("S2e33", result))
})

test_that("session_prompt contains the no-fabrication rule using 'never'", {
  result <- session_prompt("S2e33", "Some content.")
  expect_true(grepl("never", result, ignore.case = TRUE))
})

test_that("session_prompt contains explicit [[Basil|the Captain]] instruction", {
  result <- session_prompt("S2e33", "Some content.")
  expect_true(grepl("[[Basil|the Captain]]", result, fixed = TRUE))
})

test_that("session_prompt contains mark-source rule", {
  result <- session_prompt("S2e33", "Some content.")
  expect_true(grepl("source", result))
})

test_that("session_prompt includes the section_text in the prompt body", {
  result <- session_prompt("S2e33", "Unique sentinel content XYZ.")
  expect_true(grepl("Unique sentinel content XYZ.", result, fixed = TRUE))
})

test_that("session_prompt contains review_required instruction", {
  result <- session_prompt("S2e33", "Some content.")
  expect_true(grepl("review_required", result))
})

# --- npc_prompt() ------------------------------------------------------------

test_that("npc_prompt returns a character string", {
  result <- npc_prompt("Attorrnash", list("He is a mind flayer."))
  expect_type(result, "character")
  expect_equal(length(result), 1L)
})

test_that("npc_prompt interpolates npc_name into the output", {
  result <- npc_prompt("Attorrnash", list("He is a mind flayer."))
  expect_true(grepl("Attorrnash", result))
})

test_that("npc_prompt contains the no-fabrication rule using 'never'", {
  result <- npc_prompt("Attorrnash", list("He is a mind flayer."))
  expect_true(grepl("never", result, ignore.case = TRUE))
})

test_that("npc_prompt contains explicit [[Basil|the Captain]] instruction", {
  result <- npc_prompt("Attorrnash", list("He is a mind flayer."))
  expect_true(grepl("[[Basil|the Captain]]", result, fixed = TRUE))
})

test_that("npc_prompt contains mark-source rule", {
  result <- npc_prompt("Attorrnash", list("He is a mind flayer."))
  expect_true(grepl("source", result))
})

test_that("npc_prompt collapses multiple passages with separator", {
  result <- npc_prompt("Attorrnash", list("Passage one.", "Passage two."))
  expect_true(grepl("Passage one.", result, fixed = TRUE))
  expect_true(grepl("Passage two.", result, fixed = TRUE))
  expect_true(grepl("---", result, fixed = TRUE))
})

# --- generate_note() ---------------------------------------------------------

test_that("generate_note returns NULL for sparse section", {
  sparse <- paste(rep("word", 50), collapse = " ")
  result <- generate_note("S2e33", sparse)
  expect_null(result)
})

test_that("generate_note has correct argument signature", {
  args <- names(formals(generate_note))
  expect_true("episode_id"    %in% args)
  expect_true("section_text"  %in% args)
  expect_true("model"         %in% args)
  expect_true("base_url"      %in% args)
})

test_that("generate_note model defaults to OLLAMA_MODEL", {
  expect_equal(formals(generate_note)$model, as.name("OLLAMA_MODEL"))
})

test_that("generate_note base_url defaults to OLLAMA_BASE_URL", {
  expect_equal(formals(generate_note)$base_url, as.name("OLLAMA_BASE_URL"))
})

test_that("generate_note calls ollama_generate for non-sparse input", {
  long_text  <- paste(rep("word", 200), collapse = " ")
  mock_body  <- charToRaw(jsonlite::toJSON(
    list(message = list(role = "assistant", content = "# Note\n## Summary\nContent.")),
    auto_unbox = TRUE
  ))
  local_mocked_responses(function(req) {
    response(status_code = 200,
             headers = list("content-type" = "application/json"),
             body = mock_body)
  })
  result <- generate_note("S2e33", long_text, model = "m",
                          base_url = "http://localhost:11434")
  expect_type(result, "character")
  expect_true(nchar(result) > 0)
})

# --- session_prompt() few_shot_paths -----------------------------------------

test_that("session_prompt with NULL few_shot_paths produces no EXAMPLE block", {
  result <- session_prompt("S2e33", "Some source.", few_shot_paths = NULL)
  expect_false(grepl("FEW-SHOT EXAMPLES", result, fixed = TRUE))
})

test_that("session_prompt with empty few_shot_paths produces no EXAMPLE block", {
  result <- session_prompt("S2e33", "Some source.", few_shot_paths = character(0))
  expect_false(grepl("FEW-SHOT EXAMPLES", result, fixed = TRUE))
})

test_that("session_prompt with valid SFT jsonl prepends few-shot block", {
  tmp  <- withr::local_tempdir()
  path <- file.path(tmp, "sft.jsonl")
  writeLines(
    jsonlite::toJSON(list(type = "sft", section_id = "S2e10",
                          prompt = "src", completion = "# Note"),
                     auto_unbox = TRUE),
    path
  )
  result <- session_prompt("S2e33", "Some source.", few_shot_paths = path)
  expect_true(grepl("FEW-SHOT EXAMPLES", result, fixed = TRUE))
  expect_true(grepl("EXAMPLE OUTPUT", result, fixed = TRUE))
})

test_that("session_prompt includes source text after the few-shot block", {
  tmp  <- withr::local_tempdir()
  path <- file.path(tmp, "sft.jsonl")
  writeLines(
    jsonlite::toJSON(list(type = "sft", section_id = "S2e10",
                          prompt = "src", completion = "# Note"),
                     auto_unbox = TRUE),
    path
  )
  result <- session_prompt("S2e33", "SENTINEL_SOURCE_TEXT", few_shot_paths = path)
  examples_pos <- regexpr("FEW-SHOT EXAMPLES", result, fixed = TRUE)[1]
  sentinel_pos <- regexpr("SENTINEL_SOURCE_TEXT", result, fixed = TRUE)[1]
  expect_lt(examples_pos, sentinel_pos)
})

test_that("session_prompt ignores nonexistent file paths", {
  result <- session_prompt("S2e33", "Some source.",
                           few_shot_paths = "/nonexistent/path.jsonl")
  expect_false(grepl("FEW-SHOT EXAMPLES", result, fixed = TRUE))
})

test_that("generate_note passes few_shot_paths to session_prompt", {
  fn_body <- paste(deparse(body(generate_note)), collapse = " ")
  expect_true(grepl("few_shot_paths", fn_body, fixed = TRUE))
})

test_that("generate_note has few_shot_paths parameter defaulting to NULL", {
  expect_equal(formals(generate_note)$few_shot_paths, NULL)
})

# --- location_prompt() -------------------------------------------------------

test_that("location_prompt returns a character string", {
  result <- location_prompt("The Giff Flotilla", list("It is a large ship."))
  expect_type(result, "character")
  expect_equal(length(result), 1L)
})

test_that("location_prompt interpolates location_name into the output", {
  result <- location_prompt("The Giff Flotilla", list("It is a large ship."))
  expect_true(grepl("The Giff Flotilla", result, fixed = TRUE))
})

test_that("location_prompt contains the no-fabrication rule using 'never'", {
  result <- location_prompt("The Giff Flotilla", list("Some content."))
  expect_true(grepl("never", result, ignore.case = TRUE))
})

test_that("location_prompt contains explicit [[Basil|the Captain]] instruction", {
  result <- location_prompt("The Giff Flotilla", list("Some content."))
  expect_true(grepl("[[Basil|the Captain]]", result, fixed = TRUE))
})

test_that("location_prompt contains mark-source rule", {
  result <- location_prompt("The Giff Flotilla", list("Some content."))
  expect_true(grepl("source", result))
})

test_that("location_prompt collapses multiple passages with separator", {
  result <- location_prompt("The Giff Flotilla", list("Passage one.", "Passage two."))
  expect_true(grepl("Passage one.", result, fixed = TRUE))
  expect_true(grepl("Passage two.", result, fixed = TRUE))
  expect_true(grepl("---", result, fixed = TRUE))
})

test_that("location_prompt contains review_required instruction", {
  result <- location_prompt("The Giff Flotilla", list("Some content."))
  expect_true(grepl("review_required", result))
})

test_that("location_prompt contains [unclear] instruction for transcript artifacts", {
  result <- location_prompt("The Giff Flotilla", list("Some content."))
  expect_true(grepl("[unclear]", result, fixed = TRUE))
})

# --- faction_prompt() --------------------------------------------------------

test_that("faction_prompt returns a character string", {
  result <- faction_prompt("Giff Military", list("They are well-armed."))
  expect_type(result, "character")
  expect_equal(length(result), 1L)
})

test_that("faction_prompt interpolates faction_name into the output", {
  result <- faction_prompt("Giff Military", list("They are well-armed."))
  expect_true(grepl("Giff Military", result, fixed = TRUE))
})

test_that("faction_prompt contains the no-fabrication rule using 'never'", {
  result <- faction_prompt("Giff Military", list("Some content."))
  expect_true(grepl("never", result, ignore.case = TRUE))
})

test_that("faction_prompt contains explicit [[Basil|the Captain]] instruction", {
  result <- faction_prompt("Giff Military", list("Some content."))
  expect_true(grepl("[[Basil|the Captain]]", result, fixed = TRUE))
})

test_that("faction_prompt contains mark-source rule", {
  result <- faction_prompt("Giff Military", list("Some content."))
  expect_true(grepl("source", result))
})

test_that("faction_prompt collapses multiple passages with separator", {
  result <- faction_prompt("Giff Military", list("Passage one.", "Passage two."))
  expect_true(grepl("Passage one.", result, fixed = TRUE))
  expect_true(grepl("Passage two.", result, fixed = TRUE))
  expect_true(grepl("---", result, fixed = TRUE))
})

test_that("faction_prompt contains review_required instruction", {
  result <- faction_prompt("Giff Military", list("Some content."))
  expect_true(grepl("review_required", result))
})

test_that("faction_prompt contains [unclear] instruction for transcript artifacts", {
  result <- faction_prompt("Giff Military", list("Some content."))
  expect_true(grepl("[unclear]", result, fixed = TRUE))
})

# --- generate_entity_note() --------------------------------------------------

test_that("generate_entity_note returns NULL for sparse combined passages", {
  sparse <- list(paste(rep("word", 30), collapse = " "))
  result <- generate_entity_note("Attorrnash", sparse, "npc")
  expect_null(result)
})

test_that("generate_entity_note has correct argument signature", {
  args <- names(formals(generate_entity_note))
  expect_true("entity_name"     %in% args)
  expect_true("source_passages" %in% args)
  expect_true("note_type"       %in% args)
  expect_true("model"           %in% args)
  expect_true("base_url"        %in% args)
})

test_that("generate_entity_note model defaults to OLLAMA_MODEL", {
  expect_equal(formals(generate_entity_note)$model, as.name("OLLAMA_MODEL"))
})

test_that("generate_entity_note base_url defaults to OLLAMA_BASE_URL", {
  expect_equal(formals(generate_entity_note)$base_url, as.name("OLLAMA_BASE_URL"))
})

test_that("generate_entity_note stops on unknown note_type", {
  passages <- list(paste(rep("word", 200), collapse = " "))
  expect_error(
    generate_entity_note("Foo", passages, "item"),
    "Unknown note_type"
  )
})

test_that("generate_entity_note dispatches to npc_prompt for note_type = 'npc'", {
  captured <- NULL
  assign("ollama_generate", function(prompt, ...) { captured <<- prompt; "# NPC" },
         envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  passages <- list(paste(rep("word", 200), collapse = " "))
  generate_entity_note("Attorrnash", passages, "npc", model = "m", base_url = "http://localhost:11434")
  expect_true(grepl("npc", captured, ignore.case = TRUE))
  expect_true(grepl("Attorrnash", captured, fixed = TRUE))
})

test_that("generate_entity_note dispatches to location_prompt for note_type = 'location'", {
  captured <- NULL
  assign("ollama_generate", function(prompt, ...) { captured <<- prompt; "# Location" },
         envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  passages <- list(paste(rep("word", 200), collapse = " "))
  generate_entity_note("The Giff Flotilla", passages, "location", model = "m", base_url = "http://localhost:11434")
  expect_true(grepl("location", captured, ignore.case = TRUE))
  expect_true(grepl("The Giff Flotilla", captured, fixed = TRUE))
})

test_that("generate_entity_note dispatches to faction_prompt for note_type = 'faction'", {
  captured <- NULL
  assign("ollama_generate", function(prompt, ...) { captured <<- prompt; "# Faction" },
         envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  passages <- list(paste(rep("word", 200), collapse = " "))
  generate_entity_note("Giff Military", passages, "faction", model = "m", base_url = "http://localhost:11434")
  expect_true(grepl("faction", captured, ignore.case = TRUE))
  expect_true(grepl("Giff Military", captured, fixed = TRUE))
})

test_that("generate_entity_note strips preamble before first --- when model adds prose", {
  assign("ollama_generate",
         function(...) "Based on the dialogue provided, here is the note.\n\n---\ntags: [npc]\n---\n\n## Overview\n",
         envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  passages <- list(paste(rep("word", 150), collapse = " "))
  result <- generate_entity_note("Foo", passages, "npc",
                                 model = "m", base_url = "http://localhost:11434")
  expect_true(startsWith(result, "---"))
})

# --- revise_note() -----------------------------------------------------------

test_that("revise_note exists and has correct signature", {
  expect_true(is.function(revise_note))
  args <- names(formals(revise_note))
  expect_true("draft"       %in% args)
  expect_true("issues"      %in% args)
  expect_true("quotes"      %in% args)
  expect_true("source_text" %in% args)
  expect_true("model"       %in% args)
  expect_true("base_url"    %in% args)
})

test_that("revise_note prompt includes both issues and source quotes", {
  captured_prompt <- NULL
  assign("ollama_generate", function(prompt, ...) {
    captured_prompt <<- prompt
    "revised draft text"
  }, envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)

  revise_note(
    draft       = "original draft",
    issues      = list("Wrong NPC name used"),
    quotes      = list("Source says Attorrnash, not Mordecai"),
    source_text = "source text here",
    model       = "m", base_url = "http://localhost:11434"
  )
  expect_true(grepl("Wrong NPC name used",                captured_prompt, fixed = TRUE))
  expect_true(grepl("Source says Attorrnash, not Mordecai", captured_prompt, fixed = TRUE))
})

test_that("revise_note prompt includes source_text and original draft", {
  captured_prompt <- NULL
  assign("ollama_generate", function(prompt, ...) {
    captured_prompt <<- prompt
    "revised"
  }, envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)

  revise_note("my draft", list("issue"), list("quote"), "my source",
              model = "m", base_url = "http://localhost:11434")
  expect_true(grepl("my draft",  captured_prompt, fixed = TRUE))
  expect_true(grepl("my source", captured_prompt, fixed = TRUE))
})

test_that("revise_note calls ollama_generate with think=FALSE", {
  captured_args <- NULL
  assign("ollama_generate", function(prompt, system_prompt, ...) {
    captured_args <<- list(...)
    "revised"
  }, envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)

  revise_note("draft", list(), list(), "source",
              model = "m", base_url = "http://localhost:11434")
  expect_false(captured_args$think)
})

test_that("revise_note calls ollama_generate without a format schema (free text)", {
  captured_args <- NULL
  assign("ollama_generate", function(prompt, system_prompt, ...) {
    captured_args <<- list(...)
    "revised"
  }, envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)

  revise_note("draft", list(), list(), "source",
              model = "m", base_url = "http://localhost:11434")
  expect_null(captured_args$format)
})

test_that("revise_note propagates timed_out sentinel from ollama_generate", {
  assign("ollama_generate", function(...) list(timed_out = TRUE, verdict = NULL),
         envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)

  result <- revise_note("draft", list("issue"), list("quote"), "source",
                        model = "m", base_url = "http://localhost:11434")
  expect_identical(result, list(timed_out = TRUE, verdict = NULL))
})

# --- draft_with_refinement() -------------------------------------------------

source(test_path("../../R/critic.R"))

.approved_verdict <- function(confidence = 0.92) {
  list(verdict = "approved", confidence = confidence,
       issues = list(), source_quotes = list("confirming quote"),
       escalated = FALSE)
}
.flagged_verdict <- function(confidence = 0.55) {
  list(verdict = "flagged", confidence = confidence,
       issues = list("an issue"), source_quotes = list("a quote"),
       escalated = FALSE)
}

test_that("draft_with_refinement exists and has correct signature", {
  expect_true(is.function(draft_with_refinement))
  args <- names(formals(draft_with_refinement))
  expect_true("source_text" %in% args)
  expect_true("section_id"  %in% args)
  expect_true("note_type"   %in% args)
})

test_that("draft_with_refinement returns list with required fields", {
  assign("generate_note",    function(...) "draft text", envir = globalenv())
  assign("review_note",      function(...) .approved_verdict(), envir = globalenv())
  on.exit({
    rm("generate_note", "review_note", envir = globalenv())
  }, add = TRUE)

  src <- paste(rep("word", 150), collapse = " ")
  result <- draft_with_refinement(src, "S2e33_test1")
  expect_true(is.list(result))
  expected_fields <- c("best_draft", "best_confidence", "final_verdict",
                        "iteration_log", "iteration_count", "claude_used",
                        "escalation_reason")
  expect_true(all(expected_fields %in% names(result)))
})

test_that("draft_with_refinement returns approved draft without revision when first critic passes", {
  assign("generate_note", function(...) "first draft", envir = globalenv())
  assign("review_note",   function(...) .approved_verdict(0.90), envir = globalenv())
  on.exit({
    rm("generate_note", "review_note", envir = globalenv())
  }, add = TRUE)

  src    <- paste(rep("word", 150), collapse = " ")
  result <- draft_with_refinement(src, "S2e33_test2")
  expect_equal(result$best_draft,      "first draft")
  expect_equal(result$best_confidence, 0.90)
  expect_equal(result$iteration_count, 1L)
  expect_false(result$claude_used)
})

test_that("draft_with_refinement iteration_log has one record per iteration", {
  assign("generate_note", function(...) "draft", envir = globalenv())
  assign("review_note",   function(...) .approved_verdict(), envir = globalenv())
  on.exit({
    rm("generate_note", "review_note", envir = globalenv())
  }, add = TRUE)

  src    <- paste(rep("word", 150), collapse = " ")
  result <- draft_with_refinement(src, "S2e33_test3")
  expect_equal(length(result$iteration_log), 1L)
  entry  <- result$iteration_log[[1]]
  expect_true(all(c("section_id", "iteration", "model", "verdict",
                     "confidence", "issues_count", "escalated_to_claude",
                     "timestamp") %in% names(entry)))
})

test_that("draft_with_refinement escalation_reason is NULL when no timeout or cap", {
  assign("generate_note", function(...) "draft", envir = globalenv())
  assign("review_note",   function(...) .approved_verdict(), envir = globalenv())
  on.exit({
    rm("generate_note", "review_note", envir = globalenv())
  }, add = TRUE)

  src    <- paste(rep("word", 150), collapse = " ")
  result <- draft_with_refinement(src, "S2e33_test4")
  expect_null(result$escalation_reason)
})

test_that("draft_with_refinement escalates to Claude on review_note timeout", {
  call_seq <- 0L
  assign("generate_note", function(...) "draft", envir = globalenv())
  assign("review_note",
         function(...) list(timed_out = TRUE, verdict = NULL),
         envir = globalenv())
  claude_called <- FALSE
  assign("claude_review_note",
         function(...) { claude_called <<- TRUE; .approved_verdict(0.88) },
         envir = globalenv())
  on.exit({
    rm("generate_note", "review_note", "claude_review_note", envir = globalenv())
  }, add = TRUE)

  src    <- paste(rep("word", 150), collapse = " ")
  result <- draft_with_refinement(src, "S2e33_test5")
  expect_true(claude_called)
  expect_equal(result$escalation_reason, "ollama_timeout")
})
