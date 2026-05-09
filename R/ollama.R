library(httr2)
library(purrr)

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

ollama_generate <- function(prompt, system_prompt, model = OLLAMA_MODEL,
                            base_url = OLLAMA_BASE_URL, format = NULL,
                            options = NULL, think = NULL) {
  # On httr2_error (which covers curl timeout), return a sentinel the caller
  # can distinguish from empty content. Only httr2_error is caught here —
  # malformed JSON, schema violations, and empty content are distinct failure
  # modes and must not be silently swallowed as timeouts.
  # claude_review_note() in R/claude.R is the direct escalation target from the
  # inner loop (draft_with_refinement); no signature change needed there.
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
