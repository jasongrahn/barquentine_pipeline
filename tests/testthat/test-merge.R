library(testthat)

source(test_path("../../config.R"))
source(test_path("../../R/merge.R"))

# --- detect_conflict() -------------------------------------------------------

test_that("detect_conflict returns TRUE when values differ and are both non-empty/non-unknown", {
  expect_true(detect_conflict("alive", "dead", "status"))
  expect_true(detect_conflict("Giff Military", "Eladrin/Fey Noble", "faction"))
})

test_that("detect_conflict returns FALSE when values match", {
  expect_false(detect_conflict("alive", "alive", "status"))
})

test_that("detect_conflict returns FALSE when either value is 'unknown'", {
  expect_false(detect_conflict("unknown", "Giff Military", "faction"))
  expect_false(detect_conflict("Giff Military", "unknown", "faction"))
  expect_false(detect_conflict("unknown", "unknown", "faction"))
})

test_that("detect_conflict returns FALSE when either value is blank", {
  expect_false(detect_conflict("", "Giff Military", "faction"))
  expect_false(detect_conflict("Giff Military", "", "faction"))
  expect_false(detect_conflict("   ", "alive", "status"))
})

test_that("detect_conflict returns FALSE when either value is NA", {
  expect_false(detect_conflict(NA, "alive", "status"))
  expect_false(detect_conflict("alive", NA, "status"))
  expect_false(detect_conflict(NA_character_, NA_character_, "status"))
})

# --- build_review_callout() --------------------------------------------------

test_that("build_review_callout output contains [!warning]", {
  result <- build_review_callout("faction", "S2e38 prep notes", "Giff Military", "Eladrin/Fey Noble")
  expect_true(grepl("[!warning]", result, fixed = TRUE))
})

test_that("build_review_callout output contains the field name", {
  result <- build_review_callout("faction", "S2e38 prep notes", "Giff Military", "Eladrin/Fey Noble")
  expect_true(grepl("faction", result))
})

test_that("build_review_callout output contains both the existing and incoming values", {
  result <- build_review_callout("faction", "S2e38 prep notes", "Giff Military", "Eladrin/Fey Noble")
  expect_true(grepl("Giff Military",    result, fixed = TRUE))
  expect_true(grepl("Eladrin/Fey Noble", result, fixed = TRUE))
})

test_that("build_review_callout output contains the source", {
  result <- build_review_callout("status", "S2e38 prep notes", "alive", "dead")
  expect_true(grepl("S2e38 prep notes", result, fixed = TRUE))
})

test_that("build_review_callout output uses Obsidian blockquote syntax", {
  result <- build_review_callout("status", "S2e38", "alive", "dead")
  # Every line should start with >
  lines <- strsplit(result, "\n")[[1]]
  expect_true(all(startsWith(lines, ">")))
})

# --- append_to_section() -----------------------------------------------------

note_fixture <- paste(
  "---",
  "tags: [npc]",
  "name: Attorrnash",
  "review_required: false",
  "---",
  "",
  "## Overview",
  "Some overview text.",
  "",
  "## Session Appearances",
  "- S2e33",
  "",
  "## GM Notes",
  "",
  sep = "\n"
)

test_that("append_to_section adds content after the target section", {
  result <- append_to_section(note_fixture, "## Session Appearances", "- S2e38")
  # S2e38 should appear in the output
  expect_true(grepl("S2e38", result))
  # S2e38 must appear before the next section header
  s38_pos    <- regexpr("S2e38",          result)
  gm_pos     <- regexpr("## GM Notes",    result)
  expect_true(s38_pos < gm_pos)
})

test_that("append_to_section does not modify other sections", {
  result <- append_to_section(note_fixture, "## Session Appearances", "- S2e38")
  expect_true(grepl("Some overview text.", result, fixed = TRUE))
  expect_true(grepl("- S2e33",            result, fixed = TRUE))
})

test_that("append_to_section preserves original content of the target section", {
  result <- append_to_section(note_fixture, "## Session Appearances", "- S2e38")
  expect_true(grepl("- S2e33", result, fixed = TRUE))
})

test_that("append_to_section errors informatively when section is not found", {
  expect_error(
    append_to_section(note_fixture, "## Nonexistent Section", "- content"),
    regexp = "not found"
  )
})

test_that("append_to_section works when the target section is the last section", {
  result <- append_to_section(note_fixture, "## GM Notes", "Extra GM note.")
  expect_true(grepl("Extra GM note.", result, fixed = TRUE))
})

# --- merge_note() ------------------------------------------------------------

existing_note <- paste(
  "---",
  "tags: [npc]",
  "name: Attorrnash",
  "status: alive",
  "faction: Mind Flayer Collective",
  "review_required: false",
  "---",
  "",
  "## Overview",
  "",
  "## GM Notes",
  "",
  sep = "\n"
)

incoming_conflict <- paste(
  "---",
  "tags: [npc]",
  "name: Attorrnash",
  "status: alive",
  "faction: Githyanki Empire",
  "review_required: false",
  "---",
  "",
  sep = "\n"
)

incoming_no_conflict <- paste(
  "---",
  "tags: [npc]",
  "name: Attorrnash",
  "status: alive",
  "faction: Mind Flayer Collective",
  "review_required: false",
  "---",
  "",
  sep = "\n"
)

test_that("merge_note returns a character string", {
  result <- merge_note(existing_note, incoming_conflict, "S2e38 prep notes")
  expect_type(result, "character")
})

test_that("merge_note returns text containing the review callout when conflict detected", {
  result <- merge_note(existing_note, incoming_conflict, "S2e38 prep notes")
  expect_true(grepl("[!warning]", result, fixed = TRUE))
})

test_that("merge_note sets review_required to true when conflict is detected", {
  result <- merge_note(existing_note, incoming_conflict, "S2e38 prep notes")
  expect_true(grepl("review_required: true", result, fixed = TRUE))
})

test_that("merge_note does not set review_required to true when no conflict", {
  result <- merge_note(existing_note, incoming_no_conflict, "S2e38 prep notes")
  expect_false(grepl("review_required: true", result, fixed = TRUE))
  expect_false(grepl("[!warning]",            result, fixed = TRUE))
})

test_that("merge_note includes the conflicting field name in the callout", {
  result <- merge_note(existing_note, incoming_conflict, "S2e38 prep notes")
  expect_true(grepl("faction", result))
})

test_that("merge_note preserves all existing note content", {
  result <- merge_note(existing_note, incoming_no_conflict, "S2e38 prep notes")
  expect_true(grepl("Attorrnash", result))
  expect_true(grepl("Mind Flayer Collective", result))
})

# --- Safety: no filesystem operations in merge.R ----------------------------

test_that("merge.R contains no filesystem or write operations", {
  src <- readr::read_file(test_path("../../R/merge.R"))
  expect_false(grepl("write_note",     src, fixed = TRUE))
  expect_false(grepl("write_file",     src, fixed = TRUE))
  expect_false(grepl("file\\.remove",  src))
  expect_false(grepl("file_delete",    src, fixed = TRUE))
  expect_false(grepl("\\bunlink\\b",   src))
  expect_false(grepl("dir_delete",     src, fixed = TRUE))
})

# --- supplement_note() -------------------------------------------------------

.make_npc_note <- function(status = "unknown") {
  paste0(
    "---\ntags: [npc]\nname: Attorrnash\nstatus: ", status, "\nreview_required: false\n---\n\n",
    "## Overview\nSome content.\n\n",
    "## Session Appearances\n-\n\n",
    "## GM Notes\n"
  )
}

test_that("supplement_note returns a character string", {
  note   <- .make_npc_note()
  result <- supplement_note(note, note, "S2e38", "npc")
  expect_type(result, "character")
  expect_equal(length(result), 1L)
})

test_that("supplement_note appends session link to Session Appearances section", {
  note   <- .make_npc_note()
  result <- supplement_note(note, note, "S2e38", "npc")
  expect_true(grepl("[[S2e38]]", result, fixed = TRUE))
})

test_that("supplement_note triggers warning callout on frontmatter conflict", {
  existing <- .make_npc_note("alive")
  incoming <- .make_npc_note("dead")
  result   <- supplement_note(existing, incoming, "S2e38", "npc")
  expect_true(grepl("[!warning]", result, fixed = TRUE))
  expect_true(grepl("review_required: true", result, fixed = TRUE))
})

test_that("supplement_note with no conflict preserves existing content", {
  existing <- paste0(
    "---\ntags: [npc]\nname: Attorrnash\nstatus: alive\nreview_required: false\n---\n\n",
    "## Overview\nExisting overview.\n\n",
    "## Session Appearances\n- [[S2e35]]\n\n",
    "## GM Notes\n"
  )
  incoming <- paste0(
    "---\ntags: [npc]\nname: Attorrnash\nstatus: alive\nreview_required: false\n---\n\n",
    "## Overview\nNew overview.\n\n",
    "## Session Appearances\n-\n\n",
    "## GM Notes\n"
  )
  result <- supplement_note(existing, incoming, "S2e38", "npc")
  expect_true(grepl("Existing overview.", result, fixed = TRUE))
  expect_false(grepl("[!warning]", result, fixed = TRUE))
})

test_that("supplement_note falls back to appending at end when Session Appearances missing", {
  note_no_section <- paste0(
    "---\ntags: [npc]\nname: Attorrnash\nstatus: unknown\nreview_required: false\n---\n\n",
    "## Overview\nSome content.\n"
  )
  result <- supplement_note(note_no_section, note_no_section, "S2e38", "npc")
  expect_true(grepl("[[S2e38]]", result, fixed = TRUE))
})
