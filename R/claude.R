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

claude_review_note <- function(draft, source, model = CLAUDE_MODEL) {
  if (is.null(draft)) {
    return(list(verdict = "skipped", confidence = NA_real_,
                issues = list(), source_quotes = list()))
  }
  prompt <- paste0("SOURCE:\n", source, "\n\nDRAFT:\n", draft)
  raw    <- claude_generate_note(prompt, CRITIC_SYSTEM_PROMPT, model = model)
  result <- parse_critic_response(raw)
  result$escalated <- TRUE
  result
}

# Out-of-loop (non-blocking) Claude critic call using the Anthropic Batch API.
# Use this for calls where the pipeline does not need the result immediately
# (e.g., Story So Far updates, post-session tiebreaks outside the inner loop).
# For inner-loop escalation (inside draft_with_refinement), use the synchronous
# claude_review_note() instead — the loop needs the verdict to pick best_draft.
claude_batch_review_note <- function(draft, source, model = CLAUDE_MODEL,
                                     poll_interval_secs = 5,
                                     max_wait_secs      = 300) {
  if (is.null(draft)) {
    return(list(verdict = "skipped", confidence = NA_real_,
                issues = list(), source_quotes = list()))
  }
  api_key <- Sys.getenv("ANTHROPIC_API_KEY")
  if (nchar(api_key) == 0) {
    stop("ANTHROPIC_API_KEY is not set. Add it to ~/.Renviron with usethis::edit_r_environ().")
  }

  prompt_text <- paste0("SOURCE:\n", source, "\n\nDRAFT:\n", draft)

  # Submit the batch
  batch_resp <- request("https://api.anthropic.com/v1/message_batches") |>
    req_headers(
      "x-api-key"         = api_key,
      "anthropic-version" = CLAUDE_API_VERSION,
      "anthropic-beta"    = "message-batches-2024-09-24",
      "content-type"      = "application/json"
    ) |>
    req_body_json(list(
      requests = list(list(
        custom_id = "critic_review",
        params    = list(
          model      = model,
          max_tokens = CLAUDE_MAX_TOKENS,
          system     = CRITIC_SYSTEM_PROMPT,
          messages   = list(list(role = "user", content = prompt_text))
        )
      ))
    )) |>
    req_perform() |>
    resp_body_json()

  batch_id <- batch_resp$id

  # Poll until processing_status == "ended"
  elapsed <- 0
  repeat {
    Sys.sleep(poll_interval_secs)
    elapsed <- elapsed + poll_interval_secs
    status_resp <- request(paste0("https://api.anthropic.com/v1/message_batches/", batch_id)) |>
      req_headers(
        "x-api-key"         = api_key,
        "anthropic-version" = CLAUDE_API_VERSION,
        "anthropic-beta"    = "message-batches-2024-09-24"
      ) |>
      req_perform() |>
      resp_body_json()
    if (status_resp$processing_status == "ended") break
    if (elapsed >= max_wait_secs) {
      stop(sprintf("Batch %s did not complete within %d seconds", batch_id, max_wait_secs))
    }
  }

  # Retrieve results
  results_resp <- request(paste0("https://api.anthropic.com/v1/message_batches/", batch_id, "/results")) |>
    req_headers(
      "x-api-key"         = api_key,
      "anthropic-version" = CLAUDE_API_VERSION,
      "anthropic-beta"    = "message-batches-2024-09-24"
    ) |>
    req_perform() |>
    resp_body_string()

  # Results are JSONL; take the first (and only) line
  first_line <- strsplit(trimws(results_resp), "\n")[[1]][[1]]
  result_obj <- jsonlite::fromJSON(first_line, simplifyVector = FALSE)
  raw_text   <- result_obj$result$message$content[[1]]$text

  verdict <- parse_critic_response(raw_text)
  verdict$escalated <- TRUE
  verdict
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
