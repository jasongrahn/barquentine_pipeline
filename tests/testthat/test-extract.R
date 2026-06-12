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

test_that("session_prompt without story_so_far has no campaign context block", {
  result <- session_prompt("S2e33", "Some content.")
  expect_false(grepl("CAMPAIGN CONTEXT", result, fixed = TRUE))
  expect_false(grepl("Story So Far", result, fixed = TRUE))
})

test_that("session_prompt with story_so_far prepends campaign context block", {
  ssf <- "The party is currently aboard the Barquentine, en route to Hoovale."
  result <- session_prompt("S2e33", "Some content.", story_so_far = ssf)
  expect_true(grepl("CAMPAIGN CONTEXT", result, fixed = TRUE))
  expect_true(grepl("Story So Far", result, fixed = TRUE))
  expect_true(grepl(ssf, result, fixed = TRUE))
})

test_that("session_prompt with empty/whitespace story_so_far does NOT add the block", {
  result_empty <- session_prompt("S2e33", "Some content.", story_so_far = "")
  result_ws    <- session_prompt("S2e33", "Some content.", story_so_far = "   \n   ")
  expect_false(grepl("CAMPAIGN CONTEXT", result_empty, fixed = TRUE))
  expect_false(grepl("CAMPAIGN CONTEXT", result_ws,    fixed = TRUE))
})

test_that("session_prompt story_so_far precedes source text in the prompt", {
  ssf    <- "PRIOR_CONTEXT_MARKER"
  result <- session_prompt("S2e33", "SOURCE_BODY_MARKER", story_so_far = ssf)
  pos_ssf    <- regexpr("PRIOR_CONTEXT_MARKER", result, fixed = TRUE)
  pos_source <- regexpr("SOURCE_BODY_MARKER",   result, fixed = TRUE)
  expect_true(pos_ssf < pos_source)
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

# --- select_best_draft() ----------------------------------------------------

.iter_log_entry <- function(iter, verdict, confidence, draft, issues_count = 0L) {
  list(iteration = iter, verdict = verdict, confidence = confidence,
       draft = draft, issues_count = issues_count)
}

test_that("select_best_draft picks approved over higher-confidence rejected", {
  log <- list(
    .iter_log_entry(1L, "rejected", 1.00, "rejected draft", 4L),
    .iter_log_entry(2L, "rejected", 1.00, "still bad",      4L),
    .iter_log_entry(3L, "flagged",  0.95, "meta",           1L),
    .iter_log_entry(4L, "approved", 0.97, "approved draft", 0L)
  )
  best <- select_best_draft(log)
  expect_equal(best$draft, "approved draft")
  expect_equal(best$iteration, 4L)
})

test_that("select_best_draft picks fewest-issues among rejected when none approved", {
  log <- list(
    .iter_log_entry(1L, "rejected", 0.95, "iter1", 6L),
    .iter_log_entry(3L, "rejected", 0.99, "iter3", 4L),
    .iter_log_entry(4L, "rejected", 0.97, "iter4", 3L),
    .iter_log_entry(5L, "rejected", 0.95, "iter5", 4L),
    .iter_log_entry(6L, "rejected", 0.97, "iter6", 3L)
  )
  best <- select_best_draft(log)
  # Tied at 3 issues (iter4 and iter6), latest wins
  expect_equal(best$draft, "iter6")
  expect_equal(best$iteration, 6L)
})

test_that("select_best_draft prefers latest approved iteration", {
  log <- list(
    .iter_log_entry(1L, "approved", 0.85, "early approved", 0L),
    .iter_log_entry(2L, "rejected", 0.95, "regression",     5L),
    .iter_log_entry(3L, "approved", 0.78, "late approved",  0L)
  )
  best <- select_best_draft(log)
  expect_equal(best$draft, "late approved")
})

test_that("select_best_draft skips parse_error iterations", {
  log <- list(
    .iter_log_entry(1L, "parse_error", 0,    "junk",    1L),
    .iter_log_entry(2L, "approved",    0.80, "good",    0L)
  )
  best <- select_best_draft(log)
  expect_equal(best$draft, "good")
  expect_equal(best$iteration, 2L)
})

test_that("select_best_draft falls back to latest drafted iter when all parse_error", {
  log <- list(
    .iter_log_entry(1L, "parse_error", 0, "first attempt",  1L),
    .iter_log_entry(2L, "parse_error", 0, "second attempt", 1L)
  )
  best <- select_best_draft(log)
  expect_equal(best$draft, "second attempt")
})

test_that("select_best_draft returns NULL on empty log", {
  best <- select_best_draft(list())
  expect_null(best$draft)
})
