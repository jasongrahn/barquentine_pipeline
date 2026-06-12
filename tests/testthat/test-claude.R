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
