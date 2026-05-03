library(httr2)
library(purrr)

.build_ollama_request <- function(prompt, system_prompt, model, base_url) {
  request(paste0(base_url, "/api/chat")) |>
    req_headers("content-type" = "application/json") |>
    req_body_json(list(
      model    = model,
      messages = list(
        list(role = "system", content = system_prompt),
        list(role = "user",   content = prompt)
      ),
      stream   = FALSE
    )) |>
    req_timeout(OLLAMA_TIMEOUT) |>
    req_retry(max_tries = 3, backoff = \(i) 5 * 2^(i - 1))
}

ollama_generate <- function(prompt, system_prompt, model = OLLAMA_MODEL,
                            base_url = OLLAMA_BASE_URL) {
  .build_ollama_request(prompt, system_prompt, model, base_url) |>
    req_perform() |>
    resp_body_json() |>
    pluck("message", "content")
}
