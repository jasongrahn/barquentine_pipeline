library(stringr)
library(glue)
library(yaml)

detect_conflict <- function(existing_value, incoming_value, field) {
  is_empty <- function(x) {
    is.na(x) || nchar(trimws(as.character(x))) == 0 || trimws(as.character(x)) == "unknown"
  }
  if (is_empty(existing_value) || is_empty(incoming_value)) return(FALSE)
  as.character(existing_value) != as.character(incoming_value)
}

build_review_callout <- function(field, source, existing_value, incoming_value) {
  glue(
"> [!warning] DM Review Required
> **Source:** {source}
> **Conflict:** Existing `{field}` was \"{existing_value}\".
> Incoming source suggests \"{incoming_value}\". Verify and update the `{field}` field."
  )
}

append_to_section <- function(note_text, section_header, new_content) {
  lines <- str_split(note_text, "\n")[[1]]

  header_idx <- which(lines == section_header)
  if (length(header_idx) == 0) {
    stop("Section '", section_header, "' not found in note.")
  }
  header_idx <- header_idx[1]

  tail_seq    <- seq_along(lines)[seq_along(lines) > header_idx]
  next_header <- tail_seq[str_starts(lines[tail_seq], "## ")]
  insert_before <- if (length(next_header) > 0) next_header[1] else length(lines) + 1

  new_lines <- c(
    lines[seq_len(insert_before - 1)],
    new_content,
    if (insert_before <= length(lines)) lines[insert_before:length(lines)] else character(0)
  )

  paste(new_lines, collapse = "\n")
}

.parse_frontmatter <- function(note_text) {
  m <- str_match(note_text, "(?s)^---\n(.*?)\n---")
  if (is.na(m[1, 1])) return(list())
  read_yaml(text = m[1, 2])
}

merge_note <- function(existing_text, incoming_text, source, dry_run = DRY_RUN) {
  existing_fm <- .parse_frontmatter(existing_text)
  incoming_fm <- .parse_frontmatter(incoming_text)

  merged       <- existing_text
  has_conflict <- FALSE

  for (field in names(incoming_fm)) {
    if (field == "review_required") next
    if (!field %in% names(existing_fm)) next

    ex_val <- paste(existing_fm[[field]], collapse = " ")
    in_val <- paste(incoming_fm[[field]], collapse = " ")

    if (detect_conflict(ex_val, in_val, field)) {
      has_conflict <- TRUE
      callout <- build_review_callout(field, source, ex_val, in_val)
      merged <- tryCatch(
        append_to_section(merged, "## GM Notes", callout),
        error = function(e) paste0(merged, "\n", callout)
      )
    }
  }

  if (has_conflict) {
    merged <- str_replace(merged, "review_required: false", "review_required: true")
  }

  merged
}

supplement_note <- function(existing_text, new_content, source_id, note_type) {
  merged <- merge_note(existing_text, new_content, source = source_id)

  session_link <- paste0("- [[", source_id, "]]")

  tryCatch(
    append_to_section(merged, "## Session Appearances", session_link),
    error = function(e) paste0(merged, "\n", session_link)
  )
}
