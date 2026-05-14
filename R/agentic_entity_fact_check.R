# Mechanical citation verification for agentic entity extraction (Phase 4.2).
#
# No LLM. Each {value, line} field in the extraction cites a passage index
# (1..N where N = length(entity_record$source_passages)). This checker
# verifies the index is in range and the value substring is present at that
# passage (case-insensitive, whitespace-collapsed).
#
# Return shape mirrors verify_line_citations() in agentic_fact_check.R:
#   list(n_checked, n_unsupported, confidence, results)
#   results tibble: kind (field name), line, supported, claim

suppressPackageStartupMessages({
  library(stringr); library(tibble)
})

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Recursively collect all {value/name/feature/event, line} leaves.
# Returns a list of named lists: list(kind, value, line).
.collect_entity_citeables <- function(obj) {
  if (is.null(obj)) return(list())

  if (is.data.frame(obj)) {
    if (!"line" %in% names(obj)) return(list())
    value_col <- intersect(c("value", "name", "feature", "event"), names(obj))
    if (length(value_col) == 0L) return(list())
    vc <- value_col[[1L]]
    return(lapply(seq_len(nrow(obj)), function(i) {
      list(kind = vc, value = obj[[vc]][[i]], line = obj$line[[i]])
    }))
  }

  if (is.list(obj) && !is.null(names(obj))) {
    if ("line" %in% names(obj)) {
      vc <- intersect(c("value", "name", "feature", "event"), names(obj))
      if (length(vc) > 0L)
        return(list(list(kind = vc[[1L]], value = obj[[vc[[1L]]]], line = obj$line)))
    }
    result <- list()
    for (child in obj) result <- c(result, .collect_entity_citeables(child))
    return(result)
  }

  list()
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

#' Verify that every line citation in an entity extraction refers to a real
#' passage and that the cited value appears as a substring of that passage.
#'
#' @param extraction   Parsed list from extract_entity()$extraction (may be NULL).
#' @param entity_record  Named list with source_passages (character vector).
#'
#' @return Named list: n_checked (int), n_unsupported (int), confidence (dbl or NA),
#'   results (tibble with columns kind, line, supported, claim).
verify_entity_citations <- function(extraction, entity_record) {
  empty_result <- list(
    n_checked     = 0L,
    n_unsupported = 0L,
    confidence    = NA_real_,
    results       = tibble(kind = character(), line = integer(),
                           supported = logical(), claim = character())
  )
  if (is.null(extraction)) return(empty_result)

  passages <- entity_record$source_passages
  max_line <- length(passages)

  items <- .collect_entity_citeables(extraction)
  # Keep only items with a non-null line citation
  items <- Filter(function(x) !is.null(x$line) && !is.na(x$line), items)

  n_checked <- length(items)
  if (n_checked == 0L) return(empty_result)

  rows <- lapply(items, function(item) {
    line  <- as.integer(item$line)
    value <- item$value
    claim <- if (!is.null(value) && !is.na(value)) substr(as.character(value), 1L, 200L) else ""

    if (is.na(line) || line < 1L || line > max_line) {
      return(list(kind = item$kind, line = line, supported = FALSE, claim = claim))
    }

    if (is.null(value) || is.na(value) || !nzchar(trimws(as.character(value)))) {
      return(list(kind = item$kind, line = line, supported = TRUE, claim = claim))
    }

    needle    <- str_squish(tolower(as.character(value)))
    hay       <- str_squish(tolower(passages[[line]]))
    supported <- str_detect(hay, fixed(needle))

    list(kind = item$kind, line = line, supported = supported, claim = claim)
  })

  results_df <- tibble(
    kind      = vapply(rows, `[[`, character(1L), "kind"),
    line      = vapply(rows, `[[`, integer(1L),   "line"),
    supported = vapply(rows, `[[`, logical(1L),   "supported"),
    claim     = vapply(rows, function(r) r$claim %||% "", character(1L))
  )

  n_supported   <- sum(results_df$supported, na.rm = TRUE)
  n_unsupported <- as.integer(n_checked - n_supported)
  confidence    <- n_supported / n_checked

  list(
    n_checked     = as.integer(n_checked),
    n_unsupported = n_unsupported,
    confidence    = confidence,
    results       = results_df
  )
}

`%||%` <- function(x, y) if (is.null(x)) y else x
