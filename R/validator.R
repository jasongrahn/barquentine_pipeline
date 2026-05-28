# Format validation for vault notes (pre- and post-write).
# validate_note_format(content, note_type) → list(valid, issues)
# Returns valid = TRUE and issues = character(0) on success.
# note_type: "npc" | "pc" | "location" | "faction" | "session"

.VALID_SECTIONS <- list(
  npc      = c("## Overview", "## Personality"),
  pc       = c("## Overview", "## Personality", "## Role in Story", "## Relationships"),
  location = c("## Description", "## Region", "## Notable Features", "## Events"),
  faction  = c("## Overview", "## Goals", "## Known Members", "## Allies", "## Enemies")
  # session omitted — structure varies between legacy (LLM) and agentic (R-assembled) paths
)

.REQUIRED_FM_FIELDS <- list(
  npc      = c("tags", "slug"),
  pc       = c("tags", "slug"),
  location = c("tags", "slug"),
  faction  = c("tags", "slug"),
  session  = c("tags")
)

validate_note_format <- function(content, note_type) {
  issues <- character(0)

  if (is.null(content) || !nzchar(trimws(content)))
    return(list(valid = FALSE, issues = "Note content is empty"))

  lines <- strsplit(content, "\n", fixed = TRUE)[[1]]

  # 1. YAML frontmatter must be present and closed
  if (length(lines) < 3L || trimws(lines[1L]) != "---")
    return(list(valid = FALSE,
                issues = "Missing YAML frontmatter (note must start with ---)"))

  close_idx <- which(trimws(lines[-1L]) == "---")[1L] + 1L
  if (is.na(close_idx))
    return(list(valid = FALSE,
                issues = "YAML frontmatter not closed (missing closing ---)"))

  yaml_text  <- paste(lines[2L:(close_idx - 1L)], collapse = "\n")
  body_lines <- if (close_idx < length(lines)) lines[(close_idx + 1L):length(lines)]
                else character(0)

  # 2. Required frontmatter fields
  required <- .REQUIRED_FM_FIELDS[[note_type]]
  if (is.null(required)) required <- character(0)
  for (field in required) {
    if (!grepl(paste0("(^|\n)", field, ":"), yaml_text, perl = TRUE))
      issues <- c(issues, paste0("Missing frontmatter field: ", field))
  }

  # 3. No duplicate H1 headers in body
  h1_lines <- body_lines[grepl("^# [^#]", body_lines)]
  if (length(h1_lines) > 1L)
    issues <- c(issues, paste0(length(h1_lines),
                               " H1 headers found — at most one allowed"))

  # 4. Section headers match the expected template (entity types only)
  valid_sections <- .VALID_SECTIONS[[note_type]]
  if (!is.null(valid_sections)) {
    h2_headers <- body_lines[grepl("^## ", body_lines)]
    bad <- h2_headers[!h2_headers %in% valid_sections]
    if (length(bad) > 0L)
      issues <- c(issues, paste0("Unexpected section(s): ",
                                 paste(bad, collapse = ", ")))
  }

  # 5. Redundant H1: entity name repeated as H1 when slug is already in frontmatter
  if (length(h1_lines) > 0L) {
    m <- regmatches(yaml_text, regexpr("(?m)^slug: *(\\S+)", yaml_text, perl = TRUE))
    if (length(m) > 0L) {
      slug    <- sub("^slug: *", "", m[1L])
      h1_text <- sub("^# ", "", h1_lines[1L])
      h1_slug <- tolower(gsub("[^a-z0-9]+", "_", trimws(h1_text)))
      if (h1_slug == slug)
        issues <- c(issues, paste0("Redundant H1 '", h1_text,
                                   "' duplicates the frontmatter slug"))
    }
  }

  list(valid = length(issues) == 0L, issues = issues)
}
