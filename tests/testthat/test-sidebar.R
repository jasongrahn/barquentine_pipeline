library(testthat)

source(test_path("../../shiny/review_queue/R/sidebar.R"))

test_that(".similar_ids catches lowercase substring", {
  expect_equal(.similar_ids("captain", c("the_captain", "basil")), "the_captain")
})

test_that(".similar_ids catches mixed-case", {
  result <- .similar_ids("The Captain", c("captain", "basil"))
  expect_true("captain" %in% result)
})

test_that(".similar_ids returns empty for unrelated", {
  expect_equal(.similar_ids("unrelated", c("basil", "lumi")), character(0))
})

test_that(".similar_ids returns empty for short section_id", {
  expect_equal(.similar_ids("ab", c("abc", "abd")), character(0))
})
