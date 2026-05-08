library(jsonlite)
library(stringr)

CRITIC_SYSTEM_PROMPT <- paste(
  "You are a fact-checker for a D&D campaign wiki.",
  "",
  "You will be given:",
  "- SOURCE: raw session notes written by the Dungeon Master",
  "- DRAFT: a structured wiki entry generated from those notes",
  "",
  "Campaign character note: the player character formerly known as 'Basil' is",
  "referred to as 'the Captain'. When checking character attribution, verify",
  "actions against the Captain specifically — do not confuse him with other",
  "named NPCs.",
  "",
  "Your task: verify every factual claim in the DRAFT against the SOURCE.",
  "Check character names, locations, events, and stated relationships.",
  "",
  "Rules:",
  "- verdict: \"approved\" if the draft accurately reflects the source,",
  "  \"flagged\" if there are minor inaccuracies or unsupported claims,",
  "  \"rejected\" if the draft contains significant fabrications or contradictions",
  "- confidence: your confidence in your verdict, 0.0 to 1.0",
  "- issues: array of strings describing each inaccuracy (empty array if approved)",
  "- source_quotes: verbatim excerpts from SOURCE that ground your verdict",
  "  (required even if approved — quote the confirming lines)",
  "- ONLY raise an issue if you can quote a specific line from SOURCE that",
  "  directly contradicts the claim in the DRAFT. No quote = no issue.",
  "- Paraphrased summaries of events are acceptable. Only flag paraphrasing if",
  "  it introduces a fact that is absent from or contradicted by the source.",
  "- Two descriptions that are consistent with each other are not a contradiction.",
  "  (e.g. 'commoner clothes' and 'worn attire' describe the same thing.)",
  "- The source text is an automated transcript and may contain garbled words.",
  "  Do not flag transcript artifacts as draft inaccuracies.",
  "- Do not fabricate issues not supported by the source.",
  "- Quote source text exactly — no paraphrase.",
  "- Absence from source is not an inaccuracy.",
  sep = "\n"
)

CRITIC_RESPONSE_SCHEMA <- list(
  type     = "object",
  required = c("verdict", "confidence", "issues", "source_quotes"),
  properties = list(
    verdict       = list(type = "string", enum = list("approved", "flagged", "rejected")),
    confidence    = list(type = "number", minimum = 0, maximum = 1),
    issues        = list(type = "array",  items = list(type = "string")),
    source_quotes = list(type = "array",  items = list(type = "string"))
  )
)

.build_critic_prompt <- function(draft, source) {
  paste0("SOURCE:\n", source, "\n\nDRAFT:\n", draft)
}

# Extracts and validates the critic JSON from a raw model response string.
# Handles Ollama structured output (clean JSON string) and Claude responses
# (may include prose or fences). Returns a parse_error verdict on any failure.
parse_critic_response <- function(raw) {
  tryCatch({
    json_str <- str_extract(raw, "\\{[\\s\\S]*\\}")
    if (is.na(json_str)) stop("no JSON object found in response")

    parsed <- fromJSON(json_str, simplifyVector = FALSE)

    missing_fields <- setdiff(c("verdict", "confidence", "issues", "source_quotes"),
                              names(parsed))
    if (length(missing_fields) > 0) {
      stop(paste("missing required fields:", paste(missing_fields, collapse = ", ")))
    }
    if (!parsed$verdict %in% c("approved", "flagged", "rejected")) {
      stop(paste("invalid verdict value:", parsed$verdict))
    }

    parsed
  }, error = function(e) {
    list(
      verdict      = "parse_error",
      confidence   = 0,
      issues       = list(conditionMessage(e)),
      source_quotes = list(),
      raw_response  = raw
    )
  })
}

review_note <- function(draft, source, model = OLLAMA_CRITIC_MODEL,
                        base_url = OLLAMA_BASE_URL) {
  if (is.null(draft)) {
    return(list(verdict = "skipped", confidence = NA_real_,
                issues = list(), source_quotes = list()))
  }

  source_words <- str_count(source, "\\S+")
  if (!is.na(source_words) && source_words > CRITIC_CONTEXT_WORD_LIMIT) {
    return(claude_review_note(draft, source))
  }

  prompt <- .build_critic_prompt(draft, source)

  raw <- ollama_generate(prompt, CRITIC_SYSTEM_PROMPT,
                         model    = model,
                         base_url = base_url,
                         format   = CRITIC_RESPONSE_SCHEMA,
                         think    = FALSE)

  parse_critic_response(raw)
}
