library(testthat)

source(test_path("../../config.R"))
source(test_path("../../R/git_commit.R"))

# --- dry_run = TRUE ----------------------------------------------------------

test_that("commit_vault dry_run = TRUE prints a message without calling gert", {
  gert_called <- FALSE

  local_mocked_bindings(
    git_add    = function(...) { gert_called <<- TRUE },
    git_commit = function(...) { gert_called <<- TRUE },
    .package   = "gert"
  )

  expect_message(
    commit_vault("S2e42", vault_path = "/fake/vault", dry_run = TRUE),
    regexp = "DRY RUN"
  )
  expect_false(gert_called)
})

test_that("commit_vault dry_run = TRUE message contains the would-be commit message", {
  local_mocked_bindings(
    git_add    = function(...) invisible(NULL),
    git_commit = function(...) "fake",
    .package   = "gert"
  )
  expect_message(
    commit_vault("S2e42", vault_path = "/fake/vault", dry_run = TRUE),
    regexp = "S2e42"
  )
})

test_that("commit_vault dry_run = TRUE returns invisibly", {
  local_mocked_bindings(
    git_add    = function(...) invisible(NULL),
    git_commit = function(...) "fake",
    .package   = "gert"
  )
  result <- withVisible(
    suppressMessages(commit_vault("S2e42", vault_path = "/fake/vault", dry_run = TRUE))
  )
  expect_false(result$visible)
  expect_null(result$value)
})

# --- dry_run = FALSE ---------------------------------------------------------

test_that("commit_vault dry_run = FALSE calls git_add with the correct vault_path", {
  captured_add_repo <- NULL

  local_mocked_bindings(
    git_add    = function(files, repo = ".") { captured_add_repo <<- repo; invisible(NULL) },
    git_commit = function(message, repo = ".")  invisible("abc123"),
    .package   = "gert"
  )

  commit_vault("S2e42", vault_path = "/the/vault", dry_run = FALSE)
  expect_equal(captured_add_repo, "/the/vault")
})

test_that("commit_vault dry_run = FALSE calls git_add with '.'", {
  captured_files <- NULL

  local_mocked_bindings(
    git_add    = function(files, repo = ".") { captured_files <<- files; invisible(NULL) },
    git_commit = function(message, repo = ".") invisible("abc123"),
    .package   = "gert"
  )

  commit_vault("S2e42", vault_path = "/the/vault", dry_run = FALSE)
  expect_equal(captured_files, ".")
})

test_that("commit_vault dry_run = FALSE calls git_commit with the correct vault_path", {
  captured_commit_repo <- NULL

  local_mocked_bindings(
    git_add    = function(files, repo = ".") invisible(NULL),
    git_commit = function(message, repo = ".") { captured_commit_repo <<- repo; "abc123" },
    .package   = "gert"
  )

  commit_vault("S2e42", vault_path = "/the/vault", dry_run = FALSE)
  expect_equal(captured_commit_repo, "/the/vault")
})

test_that("commit_vault dry_run = FALSE commit message contains the session_id", {
  captured_msg <- NULL

  local_mocked_bindings(
    git_add    = function(files, repo = ".") invisible(NULL),
    git_commit = function(message, repo = ".") { captured_msg <<- message; "abc123" },
    .package   = "gert"
  )

  commit_vault("S2e42", vault_path = "/the/vault", dry_run = FALSE)
  expect_true(grepl("S2e42", captured_msg, fixed = TRUE))
})

test_that("commit_vault dry_run = FALSE commit message contains today's date", {
  captured_msg <- NULL

  local_mocked_bindings(
    git_add    = function(files, repo = ".") invisible(NULL),
    git_commit = function(message, repo = ".") { captured_msg <<- message; "abc123" },
    .package   = "gert"
  )

  commit_vault("S2e42", vault_path = "/the/vault", dry_run = FALSE)
  expect_true(grepl(as.character(Sys.Date()), captured_msg, fixed = TRUE))
})

test_that("commit_vault dry_run = FALSE commit message contains 'auto-generated'", {
  captured_msg <- NULL

  local_mocked_bindings(
    git_add    = function(files, repo = ".") invisible(NULL),
    git_commit = function(message, repo = ".") { captured_msg <<- message; "abc123" },
    .package   = "gert"
  )

  commit_vault("S2e42", vault_path = "/the/vault", dry_run = FALSE)
  expect_true(grepl("auto-generated", captured_msg, fixed = TRUE))
})

test_that("commit_vault dry_run = FALSE returns the commit hash invisibly", {
  local_mocked_bindings(
    git_add    = function(files, repo = ".") invisible(NULL),
    git_commit = function(message, repo = ".") "deadbeef",
    .package   = "gert"
  )

  result <- withVisible(commit_vault("S2e42", vault_path = "/the/vault", dry_run = FALSE))
  expect_false(result$visible)
  expect_equal(result$value, "deadbeef")
})

# --- Safety: pipeline repo string absent from source -------------------------

test_that("git_commit.R never references barquentine_pipeline", {
  src <- readr::read_file(test_path("../../R/git_commit.R"))
  expect_false(grepl("barquentine_pipeline", src, fixed = TRUE))
})
