library(testthat)
library(withr)

source(test_path("../../config.R"))
source(test_path("../../scripts/run_pipeline.R"))

# ---- .previous_session_id ---------------------------------------------------

test_that(".previous_session_id decrements zero-padded episode number", {
  expect_equal(.previous_session_id("s02e42"), "s02e41")
  expect_equal(.previous_session_id("s01e13"), "s01e12")
  expect_equal(.previous_session_id("s02e10"), "s02e09")
})

test_that(".previous_session_id returns NULL for first episode of a season", {
  expect_null(.previous_session_id("s01e01"))
  expect_null(.previous_session_id("s02e01"))
})

test_that(".previous_session_id returns NULL on unparseable input", {
  expect_null(.previous_session_id(NULL))
  expect_null(.previous_session_id(""))
  expect_null(.previous_session_id("not-a-session"))
  expect_null(.previous_session_id(c("s01e01", "s01e02")))
})

# ---- .session_in_vault ------------------------------------------------------

test_that(".session_in_vault returns FALSE when sessions dir does not exist", {
  vault <- local_tempdir()
  expect_false(.session_in_vault("s02e41", vault))
})

test_that(".session_in_vault returns TRUE when session note exists", {
  vault <- local_tempdir()
  dir.create(file.path(vault, "sessions"))
  writeLines("# notes", file.path(vault, "sessions", "s02e41.md"))
  expect_true(.session_in_vault("s02e41", vault))
})

test_that(".session_in_vault accepts gap-placeholder file as evidence", {
  vault <- local_tempdir()
  dir.create(file.path(vault, "sessions"))
  writeLines("---\ngap: true\n---\n",
             file.path(vault, "sessions", "s01e07.md"))
  expect_true(.session_in_vault("s01e07", vault))
})

# ---- .assert_session_ordering ----------------------------------------------

test_that(".assert_session_ordering skips check when PROCESS_ONE_SESSION is FALSE", {
  vault <- local_tempdir()
  with_envvar(c(), {
    PROCESS_ONE_SESSION <<- FALSE
    on.exit(PROCESS_ONE_SESSION <<- TRUE, add = TRUE)
    expect_true(.assert_session_ordering("s02e42", vault))
  })
})

test_that(".assert_session_ordering passes for first episode of a season", {
  vault <- local_tempdir()
  expect_true(.assert_session_ordering("s01e01", vault))
})

test_that(".assert_session_ordering passes when previous session is in vault", {
  vault <- local_tempdir()
  dir.create(file.path(vault, "sessions"))
  writeLines("# done", file.path(vault, "sessions", "s02e41.md"))
  expect_true(.assert_session_ordering("s02e42", vault))
})

test_that(".assert_session_ordering errors with informative message when prev session missing", {
  vault <- local_tempdir()
  expect_error(
    .assert_session_ordering("s02e42", vault),
    regexp = "Session ordering violation.*s02e41"
  )
})

test_that(".assert_session_ordering error message recommends write_placeholder_note", {
  vault <- local_tempdir()
  expect_error(
    .assert_session_ordering("s02e42", vault),
    regexp = "write_placeholder_note"
  )
})

test_that(".assert_session_ordering passes when current_session is NULL", {
  vault <- local_tempdir()
  expect_true(.assert_session_ordering(NULL, vault))
})

# ---- run_pipeline auto-detect (Step 2.6 wiring) ----------------------------

test_that("run_pipeline errors clearly when CURRENT_SESSION is NULL and registry empty", {
  source(test_path("../../R/source_b.R"))
  # Stub tar_make so it does not actually try to run the targets pipeline
  assign("tar_make", function(...) invisible(NULL), envir = globalenv())
  on.exit(rm("tar_make", envir = globalenv()), add = TRUE)

  prev <- CURRENT_SESSION
  CURRENT_SESSION <<- NULL
  on.exit(CURRENT_SESSION <<- prev, add = TRUE)

  # Point at a non-existent registry
  prev_reg <- DOC_REGISTRY_PATH
  DOC_REGISTRY_PATH <<- tempfile()
  on.exit(DOC_REGISTRY_PATH <<- prev_reg, add = TRUE)

  expect_error(run_pipeline(), regexp = "auto-detected.*NULL|next_unprocessed_session")
})
