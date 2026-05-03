library(testthat)

source(test_path("../../R/extract.R"))

# --- is_sparse() -------------------------------------------------------------

test_that("is_sparse returns TRUE for empty string", {
  expect_true(is_sparse(""))
})

test_that("is_sparse returns TRUE for text under 100 words", {
  short_text <- paste(rep("word", 50), collapse = " ")
  expect_true(is_sparse(short_text))
})

test_that("is_sparse returns TRUE for text at exactly 99 words", {
  text_99 <- paste(rep("word", 99), collapse = " ")
  expect_true(is_sparse(text_99))
})

test_that("is_sparse returns FALSE for text at exactly 100 words", {
  text_100 <- paste(rep("word", 100), collapse = " ")
  expect_false(is_sparse(text_100))
})

test_that("is_sparse returns FALSE for text over 100 words", {
  long_text <- paste(rep("word", 200), collapse = " ")
  expect_false(is_sparse(long_text))
})

# --- session_prompt() --------------------------------------------------------

test_that("session_prompt returns a character string", {
  result <- session_prompt("S2e33", "Some prep notes here.")
  expect_type(result, "character")
  expect_equal(length(result), 1L)
})

test_that("session_prompt interpolates episode_id into the output", {
  result <- session_prompt("S2e33", "Some content.")
  expect_true(grepl("S2e33", result))
})

test_that("session_prompt contains the no-fabrication rule using 'never'", {
  result <- session_prompt("S2e33", "Some content.")
  expect_true(grepl("never", result, ignore.case = TRUE))
})

test_that("session_prompt contains explicit [[Basil|the Captain]] instruction", {
  result <- session_prompt("S2e33", "Some content.")
  expect_true(grepl("[[Basil|the Captain]]", result, fixed = TRUE))
})

test_that("session_prompt contains mark-source rule", {
  result <- session_prompt("S2e33", "Some content.")
  expect_true(grepl("source", result))
})

test_that("session_prompt includes the section_text in the prompt body", {
  result <- session_prompt("S2e33", "Unique sentinel content XYZ.")
  expect_true(grepl("Unique sentinel content XYZ.", result, fixed = TRUE))
})

test_that("session_prompt contains review_required instruction", {
  result <- session_prompt("S2e33", "Some content.")
  expect_true(grepl("review_required", result))
})

# --- npc_prompt() ------------------------------------------------------------

test_that("npc_prompt returns a character string", {
  result <- npc_prompt("Attorrnash", list("He is a mind flayer."))
  expect_type(result, "character")
  expect_equal(length(result), 1L)
})

test_that("npc_prompt interpolates npc_name into the output", {
  result <- npc_prompt("Attorrnash", list("He is a mind flayer."))
  expect_true(grepl("Attorrnash", result))
})

test_that("npc_prompt contains the no-fabrication rule using 'never'", {
  result <- npc_prompt("Attorrnash", list("He is a mind flayer."))
  expect_true(grepl("never", result, ignore.case = TRUE))
})

test_that("npc_prompt contains explicit [[Basil|the Captain]] instruction", {
  result <- npc_prompt("Attorrnash", list("He is a mind flayer."))
  expect_true(grepl("[[Basil|the Captain]]", result, fixed = TRUE))
})

test_that("npc_prompt contains mark-source rule", {
  result <- npc_prompt("Attorrnash", list("He is a mind flayer."))
  expect_true(grepl("source", result))
})

test_that("npc_prompt collapses multiple passages with separator", {
  result <- npc_prompt("Attorrnash", list("Passage one.", "Passage two."))
  expect_true(grepl("Passage one.", result, fixed = TRUE))
  expect_true(grepl("Passage two.", result, fixed = TRUE))
  expect_true(grepl("---", result, fixed = TRUE))
})
