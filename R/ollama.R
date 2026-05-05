library(httr2)
library(purrr)

# format: NULL for free-text generation; a JSON Schema list for structured output.
# Ollama's format parameter enforces the schema at the token level — the model
# cannot produce output that violates it. Use this for any call that must return
# machine-readable JSON (e.g. the critic verdict).
.build_ollama_request <- function(prompt, system_prompt, model, base_url,
                                  format = NULL, options = NULL, think = TRUE) {
  body <- list(
    model    = model,
    messages = list(
      list(role = "system", content = system_prompt),
      list(role = "user",   content = prompt)
    ),
    stream = FALSE,
    think  = think
  )
  if (!is.null(format))  body$format  <- format
  if (!is.null(options)) body$options <- options

  request(paste0(base_url, "/api/chat")) |>
    req_headers("content-type" = "application/json") |>
    req_body_json(body) |>
    req_timeout(OLLAMA_TIMEOUT) |>
    req_retry(max_tries = 3, backoff = \(i) 5 * 2^(i - 1))
}

ollama_generate <- function(prompt, system_prompt, model = OLLAMA_MODEL,
                            base_url = OLLAMA_BASE_URL, format = NULL,
                            options = NULL, think = TRUE) {
  content <- .build_ollama_request(prompt, system_prompt, model, base_url,
                                   format, options, think) |>
    req_perform() |>
    resp_body_json() |>
    pluck("message", "content")

  if (is.null(content) || !nzchar(trimws(content))) {
    warning(sprintf("Empty content from %s (prompt %d chars)", model, nchar(prompt)))
    return(NULL)
  }
  content
}
