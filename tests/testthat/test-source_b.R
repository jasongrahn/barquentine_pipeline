library(testthat)

source(test_path("../../R/source_b.R"))

# Helper: wrap text in a minimal <p class="title"> tag as Google Docs HTML export produces
make_title_p <- function(ep_label) {
  sprintf('<p class="title" style="font-size:26pt">%s</p>', ep_label)
}

make_content_p <- function(text) {
  sprintf('<p style="font-size:11pt">%s</p>', text)
}

# ---- Core splitting behaviour ----

test_that("parse_source_b splits on title paragraph boundaries", {
  doc <- paste0(
    make_title_p("Barquentine S2e14"),
    make_content_p("Some content."),
    make_title_p("Barquentine S2e15"),
    make_content_p("More content.")
  )
  result <- parse_source_b(doc)

  expect_equal(length(result), 2)
  expect_true("S2e14" %in% names(result))
  expect_true("S2e15" %in% names(result))
})

test_that("parse_source_b trims whitespace from sections", {
  doc <- paste0(
    make_title_p("Barquentine S2e14"),
    make_content_p("  Some content.  ")
  )
  result <- parse_source_b(doc)

  # Result should be trimmed plain text, no leading/trailing whitespace
  expect_false(grepl("^\\s", result[["S2e14"]]))
  expect_false(grepl("\\s$", result[["S2e14"]]))
})

test_that("parse_source_b returns named list", {
  doc <- paste0(
    make_title_p("Barquentine S2e33"),
    make_content_p("Previously on Barquentine...")
  )
  result <- parse_source_b(doc)

  expect_type(result, "list")
  expect_false(is.null(names(result)))
})

test_that("parse_source_b handles empty sections gracefully", {
  doc <- paste0(
    make_title_p("Barquentine S2e26"),
    make_title_p("Barquentine S2e27"),
    make_content_p("Content here.")
  )
  result <- parse_source_b(doc)

  expect_true("S2e26" %in% names(result))
  # S2e26 section has no body content, so stripped text is just the heading text
  expect_true(nchar(trimws(gsub("Barquentine S2e26", "", result[["S2e26"]]))) == 0)
})

test_that("parse_source_b handles a single section", {
  doc <- paste0(
    make_title_p("Barquentine S2e14"),
    make_content_p("Only one section here.")
  )
  result <- parse_source_b(doc)

  expect_equal(length(result), 1)
  expect_true("S2e14" %in% names(result))
})

# ---- HTML stripping ----

test_that("parse_source_b strips all HTML tags from output", {
  doc <- paste0(
    make_title_p("Barquentine S2e14"),
    '<p><span style="font-weight:bold">Bold text</span> and <em>italic</em>.</p>'
  )
  result <- parse_source_b(doc)

  # No < or > should remain in output values
  expect_false(grepl("<", result[["S2e14"]], fixed = TRUE))
  expect_false(grepl(">", result[["S2e14"]], fixed = TRUE))
})

# ---- HTML entity decoding ----

test_that("parse_source_b decodes HTML entities", {
  doc <- paste0(
    make_title_p("Barquentine S2e14"),
    '<p>Tom &amp; Jerry, &quot;quoted&quot;, it&#39;s fine &amp; &nbsp; spaced.</p>'
  )
  result <- parse_source_b(doc)
  text <- result[["S2e14"]]

  expect_true(grepl("&", text, fixed = TRUE))
  expect_true(grepl('"quoted"', text, fixed = TRUE))
  expect_true(grepl("it's", text, fixed = TRUE))
})

# ---- Episode ID normalisation ----

test_that("parse_source_b normalises S2 e15 (space variant) to S2e15", {
  doc <- paste0(
    make_title_p("Barquentine S2 e15"),
    make_content_p("Space variant.")
  )
  result <- parse_source_b(doc)

  expect_true("S2e15" %in% names(result))
})

test_that("parse_source_b normalises S2E17 (uppercase E) to S2e17", {
  doc <- paste0(
    make_title_p("Barquentine S2E17"),
    make_content_p("Uppercase E variant.")
  )
  result <- parse_source_b(doc)

  expect_true("S2e17" %in% names(result))
})

test_that("parse_source_b normalises S2 E17 (space + uppercase E) to S2e17", {
  doc <- paste0(
    make_title_p("Barquentine S2 E17"),
    make_content_p("Space and uppercase E variant.")
  )
  result <- parse_source_b(doc)

  expect_true("S2e17" %in% names(result))
})

test_that("parse_source_b normalises bare s2e26 (lowercase) to S2e26", {
  doc <- paste0(
    make_title_p("s2e26"),
    make_content_p("Bare lowercase slug.")
  )
  result <- parse_source_b(doc)

  expect_true("S2e26" %in% names(result))
})

# ---- Deduplication ----

test_that("parse_source_b deduplicates adjacent identical episode IDs", {
  # Two adjacent sections resolve to the same canonical ID (S2e15 and S2 e15)
  doc <- paste0(
    make_title_p("Barquentine S2e15"),
    make_content_p("First copy."),
    make_title_p("Barquentine S2 e15"),
    make_content_p("Second copy — should be dropped.")
  )
  result <- parse_source_b(doc)

  # Only one S2e15 entry should survive
  expect_equal(sum(names(result) == "S2e15"), 1)
  # The first one's content should be kept
  expect_true(grepl("First copy", result[["S2e15"]]))
})

# ---- Non-episode titles are excluded ----

# ---- Heading not leaked into content ----

test_that("parse_source_b does not include heading text in section content", {
  doc <- paste0(
    make_title_p("Barquentine S2e14"),
    make_content_p("Hoovale episode")
  )
  result <- parse_source_b(doc)

  expect_false(grepl("Barquentine S2e14", result[["S2e14"]], fixed = TRUE))
  expect_true(grepl("Hoovale episode", result[["S2e14"]], fixed = TRUE))
})

test_that("parse_source_b sparse section content is only body text, not heading + body", {
  doc <- paste0(
    make_title_p("Barquentine S2e26"),
    make_content_p("Stub content only.")
  )
  result <- parse_source_b(doc)

  expect_false(grepl("Barquentine S2e26", result[["S2e26"]], fixed = TRUE))
  expect_equal(trimws(result[["S2e26"]]), "Stub content only.")
})

# ---- Non-episode titles are excluded ----

test_that("parse_source_b excludes non-episode title sections (e.g. 'Tab 7')", {
  doc <- paste0(
    make_title_p("Tab 7"),
    make_content_p("Some notes without an episode ID."),
    make_title_p("Barquentine S2e32"),
    make_content_p("Real episode content.")
  )
  result <- parse_source_b(doc)

  expect_false("Tab 7" %in% names(result))
  expect_true("S2e32" %in% names(result))
})
