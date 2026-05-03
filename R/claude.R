library(httr2)
library(purrr)

.build_claude_request <- function(prompt, system_prompt, model, api_key) {
  request("https://api.anthropic.com/v1/messages") |>
    req_headers(
      "x-api-key"         = api_key,
      "anthropic-version" = CLAUDE_API_VERSION,
      "content-type"      = "application/json"
    ) |>
    req_body_json(list(
      model      = model,
      max_tokens = CLAUDE_MAX_TOKENS,
      system     = system_prompt,
      messages   = list(list(role = "user", content = prompt))
    )) |>
    req_retry(max_tries = 3, backoff = \(i) 10 * 3^(i - 1))
}

claude_generate_note <- function(prompt, system_prompt, model = CLAUDE_MODEL) {
  api_key <- Sys.getenv("ANTHROPIC_API_KEY")
  if (nchar(api_key) == 0) {
    stop(
      "ANTHROPIC_API_KEY is not set. ",
      "Add it to ~/.Renviron with usethis::edit_r_environ()."
    )
  }

  .build_claude_request(prompt, system_prompt, model, api_key) |>
    req_perform() |>
    resp_body_json() |>
    pluck("content", 1, "text")
}
