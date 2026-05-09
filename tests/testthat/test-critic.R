library(testthat)

source(test_path("../../config.R"))
source(test_path("../../R/ollama.R"))
source(test_path("../../R/claude.R"))
source(test_path("../../R/critic.R"))

# --- Constants ---------------------------------------------------------------

test_that("CRITIC_RESPONSE_SCHEMA has required fields defined", {
  expect_equal(CRITIC_RESPONSE_SCHEMA$type, "object")
  expect_true("verdict"       %in% CRITIC_RESPONSE_SCHEMA$required)
  expect_true("confidence"    %in% CRITIC_RESPONSE_SCHEMA$required)
  expect_true("issues"        %in% CRITIC_RESPONSE_SCHEMA$required)
  expect_true("source_quotes" %in% CRITIC_RESPONSE_SCHEMA$required)
})

test_that("CRITIC_RESPONSE_SCHEMA verdict enum contains valid values", {
  enum <- CRITIC_RESPONSE_SCHEMA$properties$verdict$enum
  expect_true("approved" %in% enum)
  expect_true("flagged"  %in% enum)
  expect_true("rejected" %in% enum)
})

test_that("CRITIC_SYSTEM_PROMPT is a non-empty character string", {
  expect_type(CRITIC_SYSTEM_PROMPT, "character")
  expect_gt(nchar(CRITIC_SYSTEM_PROMPT), 100)
})

test_that("CRITIC_SYSTEM_PROMPT contains key instructional elements", {
  expect_true(grepl("approved",      CRITIC_SYSTEM_PROMPT, fixed = TRUE))
  expect_true(grepl("flagged",       CRITIC_SYSTEM_PROMPT, fixed = TRUE))
  expect_true(grepl("rejected",      CRITIC_SYSTEM_PROMPT, fixed = TRUE))
  expect_true(grepl("source_quotes", CRITIC_SYSTEM_PROMPT, fixed = TRUE))
  expect_true(grepl("fabricate",     CRITIC_SYSTEM_PROMPT, fixed = TRUE))
})

# --- .build_critic_prompt() --------------------------------------------------

test_that(".build_critic_prompt labels sections correctly", {
  result <- .build_critic_prompt("draft text", "source text")
  expect_true(grepl("SOURCE:",  result, fixed = TRUE))
  expect_true(grepl("DRAFT:",   result, fixed = TRUE))
  expect_true(grepl("draft text",  result, fixed = TRUE))
  expect_true(grepl("source text", result, fixed = TRUE))
})

test_that(".build_critic_prompt puts SOURCE before DRAFT", {
  result <- .build_critic_prompt("D", "S")
  expect_lt(regexpr("SOURCE:", result, fixed = TRUE)[1],
            regexpr("DRAFT:",  result, fixed = TRUE)[1])
})

# --- parse_critic_response() -------------------------------------------------

test_that("parse_critic_response handles clean JSON string", {
  raw <- '{"verdict":"approved","confidence":0.92,"issues":[],"source_quotes":["quote"]}'
  result <- parse_critic_response(raw)
  expect_equal(result$verdict,    "approved")
  expect_equal(result$confidence, 0.92)
  expect_length(result$issues, 0)
  expect_equal(result$source_quotes[[1]], "quote")
})

test_that("parse_critic_response handles JSON wrapped in markdown fences", {
  raw <- '```json\n{"verdict":"flagged","confidence":0.6,"issues":["problem"],"source_quotes":["line"]}\n```'
  result <- parse_critic_response(raw)
  expect_equal(result$verdict, "flagged")
})

test_that("parse_critic_response handles JSON embedded in prose", {
  raw <- 'Here is my verdict: {"verdict":"rejected","confidence":0.3,"issues":["bad"],"source_quotes":["x"]} Done.'
  result <- parse_critic_response(raw)
  expect_equal(result$verdict, "rejected")
})

test_that("parse_critic_response returns parse_error for invalid JSON", {
  result <- parse_critic_response("this is not json at all")
  expect_equal(result$verdict,    "parse_error")
  expect_equal(result$confidence, 0)
  expect_length(result$issues, 1)
})

test_that("parse_critic_response returns parse_error for missing required fields", {
  raw <- '{"verdict":"approved","confidence":0.9}'
  result <- parse_critic_response(raw)
  expect_equal(result$verdict, "parse_error")
  expect_true(grepl("missing", result$issues[[1]], ignore.case = TRUE))
})

test_that("parse_critic_response returns parse_error for invalid verdict value", {
  raw <- '{"verdict":"maybe","confidence":0.5,"issues":[],"source_quotes":[]}'
  result <- parse_critic_response(raw)
  expect_equal(result$verdict, "parse_error")
})

test_that("parse_critic_response preserves raw_response on error", {
  bad <- "not json"
  result <- parse_critic_response(bad)
  expect_equal(result$raw_response, bad)
})

test_that("parse_critic_response returns list with all four required keys on success", {
  raw <- '{"verdict":"approved","confidence":0.88,"issues":[],"source_quotes":["q"]}'
  result <- parse_critic_response(raw)
  expect_true(all(c("verdict", "confidence", "issues", "source_quotes") %in% names(result)))
})

# --- review_note() -----------------------------------------------------------

test_that("review_note returns skipped verdict for NULL draft", {
  result <- review_note(NULL, "some source text")
  expect_equal(result$verdict, "skipped")
  expect_true(is.na(result$confidence))
  expect_length(result$issues, 0)
})

test_that("review_note has correct argument signature", {
  args <- names(formals(review_note))
  expect_true("draft"    %in% args)
  expect_true("source"   %in% args)
  expect_true("model"    %in% args)
  expect_true("base_url" %in% args)
})

test_that("review_note model defaults to OLLAMA_CRITIC_MODEL", {
  expect_equal(formals(review_note)$model, as.name("OLLAMA_CRITIC_MODEL"))
})

test_that("review_note function body always uses Ollama (no Claude fork)", {
  fn_body <- paste(deparse(body(review_note)), collapse = " ")
  expect_true(grepl("ollama_generate",       fn_body, fixed = TRUE))
  expect_false(grepl("claude_generate_note", fn_body, fixed = TRUE))
})

test_that("review_note function body uses CRITIC_RESPONSE_SCHEMA for Ollama calls", {
  fn_body <- paste(deparse(body(review_note)), collapse = " ")
  expect_true(grepl("CRITIC_RESPONSE_SCHEMA", fn_body, fixed = TRUE))
})

test_that("review_note returns parse_error structure when model returns bad JSON", {
  library(httr2)
  mock_body <- charToRaw(jsonlite::toJSON(
    list(message = list(role = "assistant", content = "not valid json at all")),
    auto_unbox = TRUE
  ))
  local_mocked_responses(function(req) {
    response(status_code = 200,
             headers = list("content-type" = "application/json"),
             body = mock_body)
  })
  result <- review_note("draft", "short source", model = "m",
                        base_url = "http://localhost:11434")
  expect_equal(result$verdict, "parse_error")
})

test_that("review_note propagates timed_out sentinel from ollama_generate", {
  library(httr2)
  local_mocked_responses(function(req) {
    cond <- structure(
      list(message = "Timeout was reached", call = NULL),
      class = c("httr2_error", "error", "condition")
    )
    stop(cond)
  })
  result <- review_note("draft", "short source", model = "m",
                        base_url = "http://localhost:11434")
  expect_true(is.list(result))
  expect_true(isTRUE(result$timed_out))
  expect_null(result$verdict)
})
