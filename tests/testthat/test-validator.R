library(testthat)

source(test_path("../../R/validator.R"))

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

.npc_note <- function(extra_sections = NULL, extra_fm = NULL) {
  fm_extra <- if (!is.null(extra_fm)) paste0(extra_fm, "\n") else ""
  sections <- paste(c(
    "## Overview\n\nA mysterious merchant.",
    "## Personality\n\nGreedy but charming.",
    extra_sections
  ), collapse = "\n\n")
  paste0(
    "---\ntags: [npc]\nslug: merrick\n", fm_extra,
    "aliases: []\nreview_required: true\n---\n\n",
    sections, "\n"
  )
}

.pc_note <- function() {
  paste0(
    "---\ntags: [pc]\nslug: basil\naliases: [the_captain]\n",
    "review_required: true\n---\n\n",
    "## Overview\n\nCaptain of the ship.\n\n",
    "## Personality\n\nStoic.\n\n",
    "## Role in Story\n\nProtagonist.\n\n",
    "## Relationships\n\n- Crew\n"
  )
}

.location_note <- function() {
  paste0(
    "---\ntags: [location]\nslug: the_dock\naliases: []\n",
    "review_required: true\n---\n\n",
    "## Description\n\nA busy port.\n\n",
    "## Region\n\nAstral Sea.\n"
  )
}

.faction_note <- function() {
  paste0(
    "---\ntags: [faction]\nslug: giff_flotilla\naliases: []\n",
    "review_required: true\n---\n\n",
    "## Overview\n\nArmed mercenaries.\n\n",
    "## Goals\n\n- Profit\n\n",
    "## Known Members\n\n- Big Giff\n\n",
    "## Allies\n\n- None\n\n",
    "## Enemies\n\n- The Empire\n"
  )
}

.session_note <- function() {
  paste0(
    "---\ntags: [session-recap, barquentine]\n",
    "session_date: 2025-12-23\nsource: vtt\nreview_required: true\n---\n\n",
    "# Session 2025-12-23\n\n",
    "## Synopsis\n\nThe crew arrived at the dock.\n\n",
    "## Major Events\n\n- (line 10) Docked at port.\n"
  )
}

# ---------------------------------------------------------------------------
# Return shape
# ---------------------------------------------------------------------------

test_that("validate_note_format returns list with valid and issues keys", {
  result <- validate_note_format(.npc_note(), "npc")
  expect_named(result, c("valid", "issues"), ignore.order = TRUE)
})

test_that("issues is a character vector", {
  result <- validate_note_format(.npc_note(), "npc")
  expect_type(result$issues, "character")
})

# ---------------------------------------------------------------------------
# Valid notes pass
# ---------------------------------------------------------------------------

test_that("valid NPC note passes", {
  expect_true(validate_note_format(.npc_note(), "npc")$valid)
})

test_that("valid PC note passes", {
  expect_true(validate_note_format(.pc_note(), "pc")$valid)
})

test_that("valid location note passes", {
  expect_true(validate_note_format(.location_note(), "location")$valid)
})

test_that("valid faction note passes", {
  expect_true(validate_note_format(.faction_note(), "faction")$valid)
})

test_that("valid session note passes", {
  expect_true(validate_note_format(.session_note(), "session")$valid)
})

# ---------------------------------------------------------------------------
# Frontmatter checks
# ---------------------------------------------------------------------------

test_that("empty content fails", {
  result <- validate_note_format("", "npc")
  expect_false(result$valid)
})

test_that("content without frontmatter fails", {
  result <- validate_note_format("## Overview\n\nSome text.\n", "npc")
  expect_false(result$valid)
  expect_true(any(grepl("frontmatter", result$issues)))
})

test_that("unclosed frontmatter fails", {
  content <- "---\ntags: [npc]\nslug: merrick\n\n## Overview\n\nText."
  result <- validate_note_format(content, "npc")
  expect_false(result$valid)
  expect_true(any(grepl("closed", result$issues)))
})

test_that("missing tags field is reported", {
  content <- "---\nslug: merrick\naliases: []\n---\n\n## Overview\n\nText.\n"
  result <- validate_note_format(content, "npc")
  expect_false(result$valid)
  expect_true(any(grepl("tags", result$issues)))
})

test_that("missing slug field is reported for entity notes", {
  content <- "---\ntags: [npc]\naliases: []\n---\n\n## Overview\n\nText.\n"
  result <- validate_note_format(content, "npc")
  expect_false(result$valid)
  expect_true(any(grepl("slug", result$issues)))
})

test_that("session note does not require slug field", {
  result <- validate_note_format(.session_note(), "session")
  issues <- result$issues
  expect_false(any(grepl("slug", issues)))
})

# ---------------------------------------------------------------------------
# Duplicate H1 check
# ---------------------------------------------------------------------------

test_that("duplicate H1 headers in body are flagged", {
  content <- .npc_note()
  content <- paste0(content, "\n# Another Title\n")
  result <- validate_note_format(content, "npc")
  # inject a second H1 by building manually
  bad <- paste0(
    "---\ntags: [npc]\nslug: merrick\naliases: []\n---\n\n",
    "# Merrick\n\n## Overview\n\nText.\n\n# Second\n\nMore.\n"
  )
  result2 <- validate_note_format(bad, "npc")
  expect_false(result2$valid)
  expect_true(any(grepl("H1", result2$issues)))
})

test_that("single H1 in body is allowed", {
  content <- paste0(
    "---\ntags: [session-recap]\nsession_date: 2025-01-01\n---\n\n",
    "# Session 2025-01-01\n\n## Synopsis\n\nText.\n"
  )
  result <- validate_note_format(content, "session")
  issues <- result$issues
  expect_false(any(grepl("H1", issues)))
})

# ---------------------------------------------------------------------------
# Section header check (entity types only)
# ---------------------------------------------------------------------------

test_that("unexpected section in NPC note is flagged", {
  content <- .npc_note(extra_sections = "## Backstory\n\nSome history.")
  result <- validate_note_format(content, "npc")
  expect_false(result$valid)
  expect_true(any(grepl("Backstory", result$issues)))
})

test_that("unexpected section in location note is flagged", {
  content <- paste0(
    "---\ntags: [location]\nslug: dock\naliases: []\n---\n\n",
    "## Description\n\nA dock.\n\n## Politics\n\nComplicated.\n"
  )
  result <- validate_note_format(content, "location")
  expect_false(result$valid)
  expect_true(any(grepl("Politics", result$issues)))
})

test_that("PC sections are valid for pc note_type", {
  result <- validate_note_format(.pc_note(), "pc")
  expect_true(result$valid)
})

test_that("session note body sections are not checked", {
  content <- paste0(
    "---\ntags: [session-recap]\nsource: vtt\n---\n\n",
    "## Whatever Section\n\nFree-form content.\n"
  )
  result <- validate_note_format(content, "session")
  expect_false(any(grepl("Whatever", result$issues)))
})

# ---------------------------------------------------------------------------
# Redundant H1 check
# ---------------------------------------------------------------------------

test_that("H1 that matches frontmatter slug is flagged as redundant", {
  content <- paste0(
    "---\ntags: [npc]\nslug: merrick\naliases: []\n---\n\n",
    "# merrick\n\n## Overview\n\nText.\n"
  )
  result <- validate_note_format(content, "npc")
  expect_false(result$valid)
  expect_true(any(grepl("Redundant", result$issues, ignore.case = TRUE)))
})

test_that("H1 that does not match slug is not flagged as redundant", {
  content <- paste0(
    "---\ntags: [session-recap]\nsession_date: 2025-01-01\n---\n\n",
    "# Session 2025-01-01\n\n## Synopsis\n\nText.\n"
  )
  result <- validate_note_format(content, "session")
  expect_false(any(grepl("Redundant", result$issues, ignore.case = TRUE)))
})

# ---------------------------------------------------------------------------
# Multiple issues can be reported simultaneously
# ---------------------------------------------------------------------------

test_that("multiple issues are all returned", {
  content <- paste0(
    "---\ntags: [npc]\naliases: []\n---\n\n",  # missing slug
    "## Overview\n\nText.\n\n## Backstory\n\nHistory.\n"  # unexpected section
  )
  result <- validate_note_format(content, "npc")
  expect_false(result$valid)
  expect_true(length(result$issues) >= 2L)
})
