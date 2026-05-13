library(testthat)
library(withr)

source(test_path("../../config.R"))
source(test_path("../../R/claude.R"))

# --- Signature -----------------------------------------------------------

test_that("claude_generate_note exists and has correct arguments", {
  expect_true(is.function(claude_generate_note))
  args <- names(formals(claude_generate_note))
  expect_true("prompt"        %in% args)
  expect_true("system_prompt" %in% args)
  expect_true("model"         %in% args)
})

test_that("model argument defaults to CLAUDE_MODEL from config", {
  expect_equal(formals(claude_generate_note)$model, as.name("CLAUDE_MODEL"))
})

# --- API key guard -------------------------------------------------------

test_that("claude_generate_note errors informatively when ANTHROPIC_API_KEY is unset", {
  withr::with_envvar(c("ANTHROPIC_API_KEY" = ""), {
    expect_error(
      claude_generate_note("test prompt", "test system"),
      regexp = "ANTHROPIC_API_KEY is not set"
    )
  })
})

# --- Request construction (no live call) ---------------------------------

test_that(".build_claude_request targets the correct API endpoint", {
  req <- .build_claude_request("p", "s", CLAUDE_MODEL, "fake-key")
  expect_equal(req$url, "https://api.anthropic.com/v1/messages")
})

test_that(".build_claude_request sets required Anthropic headers", {
  req <- .build_claude_request("p", "s", CLAUDE_MODEL, "fake-key")
  expect_equal(req$headers[["x-api-key"]],         "fake-key")
  expect_equal(req$headers[["anthropic-version"]], CLAUDE_API_VERSION)
  expect_equal(req$headers[["content-type"]],      "application/json")
})

test_that(".build_claude_request body contains required fields", {
  req <- .build_claude_request("my prompt", "my system", CLAUDE_MODEL, "fake-key")
  body <- req$body$data
  expect_equal(body$model,      CLAUDE_MODEL)
  expect_equal(body$max_tokens, CLAUDE_MAX_TOKENS)
  expect_equal(body$system,     "my system")
  expect_equal(body$messages[[1]]$role,    "user")
  expect_equal(body$messages[[1]]$content, "my prompt")
})

test_that(".build_claude_request configures retry with 3 attempts", {
  req <- .build_claude_request("p", "s", CLAUDE_MODEL, "fake-key")
  expect_equal(req$policies$retry_max_tries, 3)
})

test_that(".build_claude_request backoff produces 10s, 30s, 90s schedule", {
  req    <- .build_claude_request("p", "s", CLAUDE_MODEL, "fake-key")
  backoff <- req$policies$retry_backoff
  expect_equal(backoff(1), 10)
  expect_equal(backoff(2), 30)
  expect_equal(backoff(3), 90)
})

# --- claude_batch_review_note() ------------------------------------------

test_that("claude_batch_review_note exists and has correct signature", {
  expect_true(is.function(claude_batch_review_note))
  args <- names(formals(claude_batch_review_note))
  expect_true("draft"             %in% args)
  expect_true("source"            %in% args)
  expect_true("model"             %in% args)
  expect_true("poll_interval_secs" %in% args)
  expect_true("max_wait_secs"     %in% args)
})

test_that("claude_batch_review_note returns skipped for NULL draft", {
  result <- claude_batch_review_note(NULL, "some source")
  expect_equal(result$verdict, "skipped")
  expect_true(is.na(result$confidence))
})

test_that("claude_batch_review_note errors when ANTHROPIC_API_KEY is unset", {
  withr::with_envvar(c("ANTHROPIC_API_KEY" = ""), {
    expect_error(
      claude_batch_review_note("draft", "source"),
      regexp = "ANTHROPIC_API_KEY is not set"
    )
  })
})

test_that("claude_batch_review_note sets escalated=TRUE on successful result", {
  library(httr2)
  source(test_path("../../R/ollama.R"))
  source(test_path("../../R/critic.R"))

  batch_create_body <- charToRaw(jsonlite::toJSON(
    list(id = "batch_abc123", processing_status = "in_progress"),
    auto_unbox = TRUE
  ))
  batch_status_body <- charToRaw(jsonlite::toJSON(
    list(id = "batch_abc123", processing_status = "ended"),
    auto_unbox = TRUE
  ))
  verdict_json <- '{"verdict":"approved","confidence":0.91,"issues":[],"source_quotes":["quote"]}'
  results_jsonl <- paste0(
    jsonlite::toJSON(
      list(custom_id = "critic_review",
           result = list(
             message = list(
               content = list(list(type = "text", text = verdict_json))
             )
           )),
      auto_unbox = TRUE
    ), "\n"
  )

  call_count <- 0L
  withr::with_envvar(c("ANTHROPIC_API_KEY" = "test-key"), {
    local_mocked_responses(function(req) {
      call_count <<- call_count + 1L
      if (call_count == 1L) {
        response(status_code = 200, headers = list("content-type" = "application/json"),
                 body = batch_create_body)
      } else if (call_count == 2L) {
        response(status_code = 200, headers = list("content-type" = "application/json"),
                 body = batch_status_body)
      } else {
        response(status_code = 200, headers = list("content-type" = "application/json"),
                 body = charToRaw(results_jsonl))
      }
    })
    result <- claude_batch_review_note("draft text", "source text",
                                       poll_interval_secs = 0)
  })
  expect_equal(result$verdict, "approved")
  expect_true(isTRUE(result$escalated))
})
