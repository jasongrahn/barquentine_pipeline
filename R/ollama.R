library(httr2)
library(purrr)
library(jsonlite)

# format: NULL for free-text generation; a JSON Schema list for structured output.
# Ollama's format parameter enforces the schema at the token level — the model
# cannot produce output that violates it. Use this for any call that must return
# machine-readable JSON (e.g. the critic verdict).
.build_ollama_request <- function(prompt, system_prompt, model, base_url,
                                  format = NULL, options = NULL, think = NULL) {
  body <- list(
    model    = model,
    messages = list(
      list(role = "system", content = system_prompt),
      list(role = "user",   content = prompt)
    ),
    stream = FALSE
  )
  if (!is.null(format))  body$format  <- format
  if (!is.null(options)) body$options <- options
  if (!is.null(think))   body$think   <- think

  request(paste0(base_url, "/api/chat")) |>
    req_headers("content-type" = "application/json") |>
    req_body_json(body) |>
    req_timeout(OLLAMA_TIMEOUT)
}

# Uses Gemma4's native <think> token via the /api/generate raw endpoint.
# Constructs the full Gemma4 chat template so thinking mode fires correctly.
# Returns the answer after </think>, discarding the thinking block.
# Returns NULL on empty response; returns list(timed_out=TRUE) on network error.
#
# format= (constrained decoding) is incompatible with raw mode and is NOT
# supported here. JSON structure is enforced by the prompt; parse with
# .parse_skill_json() / .strip_json_fences().
ollama_generate_thinking <- function(system_prompt, user_prompt,
                                     model    = OLLAMA_MODEL,
                                     base_url = OLLAMA_BASE_URL,
                                     options  = NULL) {
  # Gemma4's <start_of_turn>system role is not reliably supported via Ollama's
  # raw endpoint. Prepend system content to the user turn — same layout as the
  # confirmed-working A1 diagnostic, where only <start_of_turn>user was used.
  full_prompt <- paste0(
    "<start_of_turn>user\n",
    system_prompt, "\n\n",
    user_prompt,
    "<end_of_turn>\n",
    "<start_of_turn>model\n<think>\n"
  )

  body <- list(model = model, prompt = full_prompt, stream = FALSE, raw = TRUE)
  if (!is.null(options)) body$options <- options

  content <- tryCatch(
    request(paste0(base_url, "/api/generate")) |>
      req_headers("content-type" = "application/json") |>
      req_body_json(body) |>
      req_timeout(OLLAMA_TIMEOUT) |>
      req_perform() |>
      resp_body_json() |>
      pluck("response"),
    httr2_error = function(e) {
      message(sprintf("Ollama timeout/error (thinking) for model %s: %s",
                      model, conditionMessage(e)))
      list(timed_out = TRUE)
    }
  )

  if (is.list(content) && isTRUE(content$timed_out)) return(content)
  if (is.null(content) || !nzchar(trimws(content))) {
    warning(sprintf("Empty content from %s (thinking mode)", model))
    return(NULL)
  }

  think_end <- regexpr("</think>", content, fixed = TRUE)
  if (think_end > 0L) {
    answer <- trimws(substr(content, think_end[1L] + 8L, nchar(content)))
    if (!nzchar(answer)) {
      warning("Thinking block present but answer portion is empty")
      return(NULL)
    }
    return(answer)
  }

  content
}

ollama_generate <- function(prompt, system_prompt, model = OLLAMA_MODEL,
                            base_url = OLLAMA_BASE_URL, format = NULL,
                            options = NULL, think = NULL) {
  # On httr2_error (which covers curl timeout), return a sentinel the caller
  # can distinguish from empty content. Only httr2_error is caught here —
  # malformed JSON, schema violations, and empty content are distinct failure
  # modes and must not be silently swallowed as timeouts.
  content <- tryCatch(
    .build_ollama_request(prompt, system_prompt, model, base_url,
                          format, options, think) |>
      req_perform() |>
      resp_body_json() |>
      pluck("message", "content"),
    httr2_error = function(e) {
      message(sprintf("Ollama timeout/error for model %s: %s", model, conditionMessage(e)))
      list(timed_out = TRUE, verdict = NULL)
    }
  )

  # Propagate the timeout sentinel directly without further processing
  if (is.list(content) && isTRUE(content$timed_out)) return(content)

  if (is.null(content) || !nzchar(trimws(content))) {
    warning(sprintf("Empty content from %s (prompt %d chars)", model, nchar(prompt)))
    return(NULL)
  }
  content
}
