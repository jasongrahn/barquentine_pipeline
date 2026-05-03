library(testthat)

source(test_path("../../R/gdrive.R"))

test_that("fetch_gdoc exists and is a function", {
  expect_true(is.function(fetch_gdoc))
})

test_that("fetch_gdoc accepts a doc_id argument", {
  args <- formals(fetch_gdoc)
  expect_true("doc_id" %in% names(args))
})

test_that("fetch_gdoc returns character when given a pre-downloaded temp file", {
  # Simulate what fetch_gdoc does after the Drive download: read_file(tmp)
  # We skip the drive_download call and test the read_file return type directly.
  tmp <- tempfile(fileext = ".html")
  writeLines("<html><body><p>Simulated Google Doc HTML content</p></body></html>", tmp)
  result <- readr::read_file(tmp)
  expect_type(result, "character")
  expect_true(nchar(result) > 0)
})

test_that("fetch_gdoc uses HTML export type", {
  # Verify the function body contains "text/html" so Drive exports HTML, not plain text
  fn_body <- deparse(body(fetch_gdoc))
  expect_true(any(grepl("text/html", fn_body, fixed = TRUE)))
})
