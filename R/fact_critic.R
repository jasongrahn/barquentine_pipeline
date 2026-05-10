library(jsonlite)

FACT_VERIFY_SCHEMA <- list(
  type     = "object",
  required = c("supported", "source_quote", "reason"),
  properties = list(
    supported    = list(type = "boolean"),
    source_quote = list(type = "string"),
    reason       = list(type = "string")
  )
)

FACT_VERIFY_SYSTEM_PROMPT <- paste(
  "You are verifying a claim against source text.",
  "Determine if the claim is supported by the source.",
  "Quote the exact supporting text if found.",
  "If not found, explain why."
)

verify_single_claim <- function(claim, source_text,
                                model = OLLAMA_CRITIC_MODEL,
                                base_url = OLLAMA_BASE_URL) {
  prompt <- paste0(
    "CLAIM: ", claim,
    "\n\nSOURCE TEXT:\n", source_text,
    "\n\nIs this claim supported by the source text?"
  )

  result <- ollama_generate(prompt, FACT_VERIFY_SYSTEM_PROMPT,
                            model = model, base_url = base_url,
                            format = FACT_VERIFY_SCHEMA, think = FALSE)

  if (is.list(result) && isTRUE(result$timed_out)) {
    return(list(claim = claim, supported = NA,
                quote = NA_character_, reason = "verification_timeout"))
  }

  parsed <- tryCatch(
    fromJSON(result, simplifyVector = FALSE),
    error = function(e) NULL
  )

  if (is.null(parsed)) {
    return(list(claim = claim, supported = NA,
                quote = NA_character_, reason = "parse_error"))
  }

  list(
    claim     = claim,
    supported = isTRUE(parsed$supported),
    quote     = if (is.null(parsed$source_quote)) NA_character_ else parsed$source_quote,
    reason    = if (is.null(parsed$reason)) NA_character_ else parsed$reason
  )
}

.is_blank <- function(x) is.null(x) || is.na(x) || !nzchar(trimws(x))

.extract_claims <- function(facts) {
  claims <- list()

  if (!is.null(facts$events) && length(facts$events) > 0) {
    for (evt in facts$events) {
      if (.is_blank(evt$description)) next
      claims <- c(claims, list(list(text = evt$description, type = "event")))
    }
  }

  if (!is.null(facts$npcs) && length(facts$npcs) > 0) {
    for (npc in facts$npcs) {
      if (!is.null(npc$actions) && length(npc$actions) > 0) {
        for (action in npc$actions) {
          if (.is_blank(action)) next
          claims <- c(claims, list(list(text = action, type = "npc_action")))
        }
      }
      if (!is.null(npc$quotes) && length(npc$quotes) > 0) {
        for (q in npc$quotes) {
          if (.is_blank(q)) next
          claims <- c(claims, list(list(text = q, type = "npc_quote")))
        }
      }
    }
  }

  if (!is.null(facts$locations) && length(facts$locations) > 0) {
    for (loc in facts$locations) {
      if (.is_blank(loc$description)) next
      claims <- c(claims, list(list(text = loc$description, type = "location")))
    }
  }

  if (!is.null(facts$threads) && length(facts$threads) > 0) {
    for (thread in facts$threads) {
      if (.is_blank(thread$description)) next
      claims <- c(claims, list(list(text = thread$description, type = "thread")))
    }
  }

  claims
}

.aggregate_verdict <- function(results) {
  verified <- Filter(function(r) !is.na(r$supported), results)

  if (length(verified) == 0) {
    return(list(
      verdict     = "approved",
      confidence  = 1.0,
      total       = 0L,
      supported   = 0L,
      unsupported = 0L,
      results     = results
    ))
  }

  supported_count   <- sum(vapply(verified, function(r) isTRUE(r$supported), logical(1)))
  unsupported_count <- length(verified) - supported_count
  confidence        <- supported_count / length(verified)
  verdict           <- if (confidence >= 0.80) "approved" else "flagged"

  list(
    verdict     = verdict,
    confidence  = confidence,
    total       = as.integer(length(verified)),
    supported   = as.integer(supported_count),
    unsupported = as.integer(unsupported_count),
    results     = results
  )
}

verify_facts <- function(facts, source_text,
                         model = OLLAMA_CRITIC_MODEL,
                         base_url = OLLAMA_BASE_URL) {
  claims <- .extract_claims(facts)

  if (length(claims) == 0) {
    return(.aggregate_verdict(list()))
  }

  results <- lapply(claims, function(cl) {
    res <- verify_single_claim(cl$text, source_text,
                               model = model, base_url = base_url)
    res$type <- cl$type
    res
  })

  .aggregate_verdict(results)
}
