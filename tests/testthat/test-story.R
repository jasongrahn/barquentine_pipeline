library(testthat)
library(withr)

source(test_path("../../config.R"))
source(test_path("../../R/story.R"))

# ---- read_story_so_far ------------------------------------------------------

test_that("read_story_so_far returns NULL when story_so_far dir does not exist", {
  vault <- local_tempdir()
  expect_null(read_story_so_far("s02e42", vault))
})

test_that("read_story_so_far returns NULL when no snapshot precedes current_session", {
  vault <- local_tempdir()
  dir.create(file.path(vault, "story_so_far"))
  writeLines("dummy", file.path(vault, "story_so_far", "through_s02e45.md"))
  # Looking for snapshot < s02e42 — only s02e45 exists, which is greater
  expect_null(read_story_so_far("s02e42", vault))
})

test_that("read_story_so_far returns content of highest-numbered snapshot < current_session", {
  vault <- local_tempdir()
  dir.create(file.path(vault, "story_so_far"))
  writeLines("v1 content", file.path(vault, "story_so_far", "through_s02e40.md"))
  writeLines("v2 content", file.path(vault, "story_so_far", "through_s02e41.md"))
  writeLines("v3 content", file.path(vault, "story_so_far", "through_s02e43.md"))
  # current_session = s02e42 → should pick s02e41 (highest < s02e42)
  result <- read_story_so_far("s02e42", vault)
  expect_true(grepl("v2 content", result, fixed = TRUE))
})

test_that("read_story_so_far ignores files that don't match through_*.md pattern", {
  vault <- local_tempdir()
  dir.create(file.path(vault, "story_so_far"))
  writeLines("snapshot", file.path(vault, "story_so_far", "through_s02e40.md"))
  writeLines("garbage",  file.path(vault, "story_so_far", "README.md"))
  result <- read_story_so_far("s02e42", vault)
  expect_true(grepl("snapshot", result, fixed = TRUE))
})

test_that("read_story_so_far returns NULL when story_so_far is empty", {
  vault <- local_tempdir()
  dir.create(file.path(vault, "story_so_far"))
  expect_null(read_story_so_far("s02e42", vault))
})

# ---- update_story_so_far ----------------------------------------------------

test_that("update_story_so_far errors when session note is missing", {
  vault <- local_tempdir()
  expect_error(
    update_story_so_far("s02e42", vault),
    regexp = "Session note not found"
  )
})

test_that("update_story_so_far skips gap sessions and returns NULL", {
  vault <- local_tempdir()
  dir.create(file.path(vault, "sessions"))
  gap_content <- "---\ntype: session_note\nsession: s01e07\ngap: true\n---\n\nNo session notes available for s01e07.\n"
  writeLines(gap_content, file.path(vault, "sessions", "s01e07.md"))
  expect_message(
    result <- update_story_so_far("s01e07", vault),
    regexp = "Skipping gap session"
  )
  expect_null(result)
  # No snapshot should have been written
  expect_false(dir.exists(file.path(vault, "story_so_far")))
})

# ---- .parse_sessions_covered ------------------------------------------------

test_that(".parse_sessions_covered returns character(0) when prior_summary is NULL", {
  expect_equal(.parse_sessions_covered(NULL), character(0))
})

test_that(".parse_sessions_covered extracts session list from frontmatter", {
  prior <- "---\ntype: campaign_summary\nsessions_covered: [s02e40, s02e41, s02e42]\n---\nbody"
  result <- .parse_sessions_covered(prior)
  expect_equal(result, c("s02e40", "s02e41", "s02e42"))
})

test_that(".parse_sessions_covered returns character(0) when sessions_covered is missing", {
  prior <- "---\ntype: campaign_summary\nthrough_session: s02e42\n---\nbody"
  expect_equal(.parse_sessions_covered(prior), character(0))
})
