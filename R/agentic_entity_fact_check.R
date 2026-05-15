# Source-sentence substring grounding check for agentic entity extraction (Phase F4).
#
# Replaces APS-based grounding (Phase C). Each claim extracted from the draft is
# checked for literal presence in the concatenated source passages via fixed-string
# substring match.
#
# Public API:
#   fact_check_entity(entity_id, draft_markdown, source_passages, model, base_url)
#
# Return shape (unchanged from APS version for Shiny UI compatibility):
#   list(matched_claims, unmatched_claims, coverage_score, aps_proposition_count,
#        pipeline_path)
#   aps_proposition_count holds source sentence count (column name preserved).

suppressPackageStartupMessages({
  library(stringr)
})

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

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

.count_source_sentences <- function(source_text) {
  if (!nzchar(trimws(source_text))) return(0L)
  sentences <- str_split(source_text, "[.!?]\\s+|\n")[[1]]
  as.integer(sum(nzchar(str_trim(sentences))))
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

fact_check_entity <- function(entity_id,
                               draft_markdown,
                               source_passages,
                               model    = NULL,   # unused; retained for API compatibility
                               base_url = NULL) { # unused; retained for API compatibility
  source_text    <- paste(source_passages, collapse = " ")
  sentence_count <- .count_source_sentences(source_text)

  claims <- .split_draft_claims(draft_markdown)
  if (length(claims) == 0L) {
    return(list(
      matched_claims        = character(0),
      unmatched_claims      = character(0),
      coverage_score        = NA_real_,
      aps_proposition_count = sentence_count,
      pipeline_path         = "substring_grounding"
    ))
  }

  # Direction: claim inside source_text (NOT proposition inside claim)
  is_matched <- vapply(claims, function(claim) {
    str_detect(source_text, fixed(claim, ignore_case = TRUE))
  }, logical(1))

  list(
    matched_claims        = unname(claims[is_matched]),
    unmatched_claims      = unname(claims[!is_matched]),
    coverage_score        = mean(is_matched),
    aps_proposition_count = sentence_count,
    pipeline_path         = "substring_grounding"
  )
}
