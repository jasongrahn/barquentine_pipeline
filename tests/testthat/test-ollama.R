library(testthat)
library(httr2)

source(test_path("../../config.R"))
source(test_path("../../R/ollama.R"))

# --- Signature ---------------------------------------------------------------

test_that("ollama_generate exists and has correct arguments", {
  expect_true(is.function(ollama_generate))
  args <- names(formals(ollama_generate))
  expect_true("prompt"        %in% args)
  expect_true("system_prompt" %in% args)
  expect_true("model"         %in% args)
  expect_true("base_url"      %in% args)
})

test_that("model argument defaults to OLLAMA_MODEL from config", {
  expect_equal(formals(ollama_generate)$model, as.name("OLLAMA_MODEL"))
})

test_that("base_url argument defaults to OLLAMA_BASE_URL from config", {
  expect_equal(formals(ollama_generate)$base_url, as.name("OLLAMA_BASE_URL"))
})

# --- Request construction (no live call) -------------------------------------

test_that(".build_ollama_request targets the correct endpoint", {
  req <- .build_ollama_request("p", "s", OLLAMA_MODEL, OLLAMA_BASE_URL)
  expect_equal(req$url, paste0(OLLAMA_BASE_URL, "/api/chat"))
})

test_that(".build_ollama_request sets content-type header", {
  req <- .build_ollama_request("p", "s", OLLAMA_MODEL, OLLAMA_BASE_URL)
  expect_equal(req$headers[["content-type"]], "application/json")
})

test_that(".build_ollama_request body contains model and stream = FALSE", {
  req  <- .build_ollama_request("my prompt", "my system", "qwen3.5:9b", OLLAMA_BASE_URL)
  body <- req$body$data
  expect_equal(body$model,  "qwen3.5:9b")
  expect_false(body$stream)
})

test_that(".build_ollama_request omits format field when format is NULL", {
  req  <- .build_ollama_request("p", "s", OLLAMA_MODEL, OLLAMA_BASE_URL, format = NULL)
  expect_null(req$body$data$format)
})

test_that(".build_ollama_request includes format field when format is provided", {
  schema <- list(type = "object", properties = list(verdict = list(type = "string")))
  req    <- .build_ollama_request("p", "s", OLLAMA_MODEL, OLLAMA_BASE_URL, format = schema)
  expect_equal(req$body$data$format, schema)
})

test_that("ollama_generate passes format argument through to request", {
  schema <- list(type = "object")
  mock_body <- charToRaw(jsonlite::toJSON(
    list(message = list(role = "assistant", content = "{}")),
    auto_unbox = TRUE
  ))
  local_mocked_responses(function(req) {
    response(status_code = 200,
             headers = list("content-type" = "application/json"),
             body = mock_body)
  })
  # Confirm it doesn't error when format is passed
  expect_no_error(
    ollama_generate("p", "s", model = "m", base_url = "http://localhost:11434",
                    format = schema)
  )
})

test_that(".build_ollama_request body messages are in system then user order", {
  req  <- .build_ollama_request("my prompt", "my system", OLLAMA_MODEL, OLLAMA_BASE_URL)
  msgs <- req$body$data$messages
  expect_equal(msgs[[1]]$role,    "system")
  expect_equal(msgs[[1]]$content, "my system")
  expect_equal(msgs[[2]]$role,    "user")
  expect_equal(msgs[[2]]$content, "my prompt")
})

test_that(".build_ollama_request sets timeout to OLLAMA_TIMEOUT seconds", {
  req <- .build_ollama_request("p", "s", OLLAMA_MODEL, OLLAMA_BASE_URL)
  expect_equal(req$options$timeout_ms, OLLAMA_TIMEOUT * 1000L)
})

test_that(".build_ollama_request configures retry with 3 attempts", {
  req <- .build_ollama_request("p", "s", OLLAMA_MODEL, OLLAMA_BASE_URL)
  expect_equal(req$policies$retry_max_tries, 3)
})

test_that(".build_ollama_request backoff produces 5s, 10s, 20s schedule", {
  req     <- .build_ollama_request("p", "s", OLLAMA_MODEL, OLLAMA_BASE_URL)
  backoff <- req$policies$retry_backoff
  expect_equal(backoff(1),  5)
  expect_equal(backoff(2), 10)
  expect_equal(backoff(3), 20)
})

# --- Response parsing (mocked — no live Ollama required) ---------------------

test_that("ollama_generate extracts content from chat response", {
  mock_body <- charToRaw(jsonlite::toJSON(
    list(message = list(role = "assistant", content = "Generated note text")),
    auto_unbox = TRUE
  ))
  local_mocked_responses(function(req) {
    response(
      status_code = 200,
      headers     = list("content-type" = "application/json"),
      body        = mock_body
    )
  })
  result <- ollama_generate("prompt", "system",
                            model    = "test-model",
                            base_url = "http://localhost:11434")
  expect_equal(result, "Generated note text")
})

test_that("ollama_generate returns a single character string", {
  mock_body <- charToRaw(jsonlite::toJSON(
    list(message = list(role = "assistant", content = "Some output")),
    auto_unbox = TRUE
  ))
  local_mocked_responses(function(req) {
    response(
      status_code = 200,
      headers     = list("content-type" = "application/json"),
      body        = mock_body
    )
  })
  result <- ollama_generate("p", "s", model = "m", base_url = "http://localhost:11434")
  expect_type(result, "character")
  expect_length(result, 1)
})

test_that("ollama_generate returns NULL with warning when content is empty string", {
  mock_body <- charToRaw(jsonlite::toJSON(
    list(message = list(role = "assistant", content = "")),
    auto_unbox = TRUE
  ))
  local_mocked_responses(function(req) {
    response(status_code = 200,
             headers = list("content-type" = "application/json"),
             body = mock_body)
  })
  expect_warning(
    result <- ollama_generate("prompt", "system", model = "m",
                              base_url = "http://localhost:11434"),
    regexp = "Empty content"
  )
  expect_null(result)
})

test_that("ollama_generate returns NULL with warning when content is whitespace only", {
  mock_body <- charToRaw(jsonlite::toJSON(
    list(message = list(role = "assistant", content = "   ")),
    auto_unbox = TRUE
  ))
  local_mocked_responses(function(req) {
    response(status_code = 200,
             headers = list("content-type" = "application/json"),
             body = mock_body)
  })
  expect_warning(
    result <- ollama_generate("prompt", "system", model = "m",
                              base_url = "http://localhost:11434"),
    regexp = "Empty content"
  )
  expect_null(result)
})

test_that(".build_ollama_request includes think field only when explicitly set", {
  req_false <- .build_ollama_request("p", "s", OLLAMA_MODEL, OLLAMA_BASE_URL, think = FALSE)
  expect_false(req_false$body$data$think)

  req_true <- .build_ollama_request("p", "s", OLLAMA_MODEL, OLLAMA_BASE_URL, think = TRUE)
  expect_true(req_true$body$data$think)

  req_null <- .build_ollama_request("p", "s", OLLAMA_MODEL, OLLAMA_BASE_URL, think = NULL)
  expect_null(req_null$body$data$think)
})

test_that("ollama_generate think defaults to NULL (omits field from body by default)", {
  expect_null(formals(ollama_generate)$think)
})
