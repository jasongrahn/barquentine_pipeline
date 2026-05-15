# APS-based grounding check for agentic entity extraction (Phase C).
#
# Replaces the broken citation-index verifier. Source passages are fed to the
# gemma-aps model, which returns a list of atomic propositions. Draft sentences
# are matched against those propositions by substring search.
#
# Public API:
#   fact_check_entity(entity_id, draft_markdown, source_passages, model, base_url)
#
# Return shape:
#   list(matched_claims, unmatched_claims, coverage_score, aps_proposition_count,
#        pipeline_path)
#   On APS timeout or empty proposition list: coverage_score=NA,
#   pipeline_path="aps_error".

suppressPackageStartupMessages({
  library(stringr)
})

APS_MODEL <- "gurubot/gemma-2b-aps-it:Q4_K_M"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

.parse_aps_propositions <- function(raw) {
  if (is.null(raw) || !nzchar(trimws(raw))) return(character(0))
  lines <- str_split(raw, "\n")[[1]]
  # Drop header line(s), <s>/<\/s> sentinels, empty lines
  lines <- lines[!str_detect(lines, "^\\s*:?\\s*PROPOSITIONS:")]
  lines <- lines[!str_detect(lines, "^\\s*</?s>\\s*$")]
  # Strip bullet/number prefixes: "- ", "* ", "1. ", "1) " etc.
  lines <- str_replace(lines, "^\\s*[-*]\\s+", "")
  lines <- str_replace(lines, "^\\s*\\d+[.):]\\s+", "")
  lines <- str_trim(lines)
  lines[nzchar(lines)]
}

.split_draft_claims <- function(draft_markdown) {
  if (is.null(draft_markdown) || !nzchar(trimws(draft_markdown))) return(character(0))
  text <- draft_markdown

  # Strip YAML frontmatter between --- fences
  text <- str_replace(text, "(?s)^---\\s*\n.*?\n---\\s*\n", "")

  # Strip ## headers
  lines <- str_split(text, "\n")[[1]]
  lines <- lines[!str_detect(lines, "^#{1,6}\\s+")]
  text  <- paste(lines, collapse = " ")

  # Split on sentence boundaries or newlines
  claims <- str_split(text, "[.!?]\\s+|\n")[[1]]
  claims <- str_trim(claims)
  claims <- claims[nchar(claims) >= 10L]
  claims
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

fact_check_entity <- function(entity_id,
                               draft_markdown,
                               source_passages,
                               model    = APS_MODEL,
                               base_url = OLLAMA_BASE_URL) {
  error_result <- function() list(
    matched_claims        = character(0),
    unmatched_claims      = character(0),
    coverage_score        = NA_real_,
    aps_proposition_count = 0L,
    pipeline_path         = "aps_error"
  )

  # Build passages prompt
  passages_text <- paste(
    vapply(seq_along(source_passages), function(i)
      paste0("PASSAGE [", i, "]:\n", source_passages[[i]]),
    character(1)),
    collapse = "\n\n"
  )

  # APS call
  raw <- tryCatch(
    ollama_generate(
      prompt        = passages_text,
      system_prompt = "",
      model         = model,
      base_url      = base_url,
      format        = NULL,
      think         = FALSE
    ),
    error = function(e) {
      message("fact_check_entity APS error for ", entity_id, ": ", conditionMessage(e))
      list(timed_out = TRUE)
    }
  )

  if (is.list(raw) && isTRUE(raw$timed_out)) return(error_result())

  propositions <- .parse_aps_propositions(raw)
  if (length(propositions) == 0L) return(error_result())

  # Split draft into claims
  claims <- .split_draft_claims(draft_markdown)
  if (length(claims) == 0L) {
    return(list(
      matched_claims        = character(0),
      unmatched_claims      = character(0),
      coverage_score        = NA_real_,
      aps_proposition_count = length(propositions),
      pipeline_path         = "aps_grounding"
    ))
  }

  # Match each claim against any proposition
  is_matched <- vapply(claims, function(claim) {
    any(str_detect(claim, regex(propositions, ignore_case = TRUE)))
  }, logical(1))

  list(
    matched_claims        = unname(claims[is_matched]),
    unmatched_claims      = unname(claims[!is_matched]),
    coverage_score        = mean(is_matched),
    aps_proposition_count = length(propositions),
    pipeline_path         = "aps_grounding"
  )
}
