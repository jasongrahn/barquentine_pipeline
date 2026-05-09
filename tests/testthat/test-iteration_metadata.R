library(testthat)
library(jsonlite)
library(htmltools)

source(test_path("../../shiny/iteration_metadata.R"))

# ---- .parse_escalation_reason ----------------------------------------------

test_that(".parse_escalation_reason returns NULL for empty / missing input", {
  expect_null(.parse_escalation_reason(NULL))
  expect_null(.parse_escalation_reason(NA_character_))
  expect_null(.parse_escalation_reason(""))
  expect_null(.parse_escalation_reason("[]"))
})

test_that(".parse_escalation_reason returns first non-empty reason", {
  log <- toJSON(list(
    list(iteration = 1L, escalation_reason = NULL),
    list(iteration = 2L, escalation_reason = "cap_hit")
  ), auto_unbox = TRUE, null = "null")
  expect_equal(.parse_escalation_reason(log), "cap_hit")
})

test_that(".parse_escalation_reason picks ollama_timeout when present", {
  log <- toJSON(list(
    list(iteration = 1L, escalation_reason = "ollama_timeout"),
    list(iteration = 2L, escalation_reason = "cap_hit")
  ), auto_unbox = TRUE)
  expect_equal(.parse_escalation_reason(log), "ollama_timeout")
})

test_that(".parse_escalation_reason returns NULL when only nulls present", {
  log <- toJSON(list(
    list(iteration = 1L, escalation_reason = NULL)
  ), auto_unbox = TRUE, null = "null")
  expect_null(.parse_escalation_reason(log))
})

test_that(".parse_escalation_reason tolerates malformed JSON", {
  expect_null(.parse_escalation_reason("{not json"))
})

# ---- .escalation_reason_label ----------------------------------------------

test_that(".escalation_reason_label maps known reasons", {
  expect_equal(.escalation_reason_label("ollama_timeout"), "timed out")
  expect_equal(.escalation_reason_label("cap_hit"), "cap hit")
})

test_that(".escalation_reason_label passes through unknown reasons", {
  expect_equal(.escalation_reason_label("something_else"), "something_else")
})

# ---- .format_iteration_badges ----------------------------------------------

test_that(".format_iteration_badges returns NULL when nothing notable", {
  expect_null(.format_iteration_badges(1L, FALSE, "[]"))
  expect_null(.format_iteration_badges(NA, FALSE, NA_character_))
  expect_null(.format_iteration_badges(NULL, NULL, NULL))
})

test_that(".format_iteration_badges renders draft count when iter > 1", {
  out <- .format_iteration_badges(3L, FALSE, "[]")
  expect_s3_class(out, "shiny.tag")
  html <- as.character(out)
  expect_match(html, "3 drafts before routing")
  expect_no_match(html, "Claude revised")
})

test_that(".format_iteration_badges renders Claude badge when claude_used", {
  out <- .format_iteration_badges(1L, TRUE, "[]")
  html <- as.character(out)
  expect_match(html, "Claude revised")
  expect_no_match(html, "drafts before routing")
})

test_that(".format_iteration_badges renders cap_hit reason label", {
  log <- toJSON(list(list(iteration = 1L, escalation_reason = "cap_hit")),
                auto_unbox = TRUE)
  out <- .format_iteration_badges(2L, TRUE, log)
  html <- as.character(out)
  expect_match(html, "Claude revised")
  expect_match(html, "\\(cap hit\\)")
  expect_match(html, "2 drafts before routing")
})

test_that(".format_iteration_badges renders ollama_timeout reason label", {
  log <- toJSON(list(list(iteration = 1L, escalation_reason = "ollama_timeout")),
                auto_unbox = TRUE)
  out <- .format_iteration_badges(1L, TRUE, log)
  html <- as.character(out)
  expect_match(html, "\\(timed out\\)")
})

test_that(".format_iteration_badges omits reason label when claude_used is FALSE", {
  log <- toJSON(list(list(iteration = 1L, escalation_reason = "cap_hit")),
                auto_unbox = TRUE)
  out <- .format_iteration_badges(2L, FALSE, log)
  html <- as.character(out)
  expect_no_match(html, "cap hit")
})

test_that(".format_iteration_badges coerces character claude_used (CSV round-trip)", {
  out <- .format_iteration_badges(1L, "TRUE", "[]")
  html <- as.character(out)
  expect_match(html, "Claude revised")
})
