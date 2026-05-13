library(testthat)
source(test_path("../../config.R"))
source(test_path("../../R/agentic_entity_fact_check.R"))

make_entity_record <- function(passages = c(
  "Attorrnash is a githyanki soldier stationed on the Giff Flotilla.",
  "He spoke briefly with the Captain and seemed suspicious.",
  "The location was confirmed as the Astral Sea region."
)) {
  list(
    entity_id          = "attorrnash",
    entity_name        = "Attorrnash",
    note_type          = "npc",
    source_passages    = passages,
    source_episode_ids = "s02e34"
  )
}

# ---- verify_entity_citations — null extraction ------------------------------

test_that("NULL extraction returns NA confidence and zero counts", {
  rec    <- make_entity_record()
  result <- verify_entity_citations(NULL, rec)
  expect_equal(result$n_checked, 0L)
  expect_equal(result$n_unsupported, 0L)
  expect_true(is.na(result$confidence))
  expect_equal(nrow(result$results), 0L)
})

test_that("all-null-line extraction returns NA confidence", {
  extraction <- list(
    description           = list(value = NULL, line = NULL),
    aliases               = list(),
    exhibited_personality = list(value = NULL, line = NULL),
    role_in_story         = list(value = NULL, line = NULL),
    affiliations          = list()
  )
  rec    <- make_entity_record()
  result <- verify_entity_citations(extraction, rec)
  expect_equal(result$n_checked, 0L)
  expect_true(is.na(result$confidence))
})

# ---- verify_entity_citations — supported citations --------------------------

test_that("value present in cited passage returns supported = TRUE", {
  extraction <- list(
    description           = list(value = "githyanki soldier", line = 1L),
    aliases               = list(),
    exhibited_personality = list(value = NULL, line = NULL),
    role_in_story         = list(value = NULL, line = NULL),
    affiliations          = list()
  )
  rec    <- make_entity_record()
  result <- verify_entity_citations(extraction, rec)
  expect_equal(result$n_checked, 1L)
  expect_equal(result$n_unsupported, 0L)
  expect_equal(result$confidence, 1.0)
  expect_true(result$results$supported[[1L]])
})

test_that("substring check is case-insensitive", {
  extraction <- list(
    description           = list(value = "GITHYANKI SOLDIER", line = 1L),
    aliases               = list(),
    exhibited_personality = list(value = NULL, line = NULL),
    role_in_story         = list(value = NULL, line = NULL),
    affiliations          = list()
  )
  rec    <- make_entity_record()
  result <- verify_entity_citations(extraction, rec)
  expect_true(result$results$supported[[1L]])
})

# ---- verify_entity_citations — unsupported citations -----------------------

test_that("cited line out of range returns supported = FALSE", {
  extraction <- list(
    description           = list(value = "a soldier", line = 99L),  # passage 99 doesn't exist
    aliases               = list(),
    exhibited_personality = list(value = NULL, line = NULL),
    role_in_story         = list(value = NULL, line = NULL),
    affiliations          = list()
  )
  rec    <- make_entity_record()
  result <- verify_entity_citations(extraction, rec)
  expect_false(result$results$supported[[1L]])
  expect_equal(result$n_unsupported, 1L)
  expect_lt(result$confidence, 1.0)
})

test_that("value not present in cited passage returns supported = FALSE", {
  extraction <- list(
    description           = list(value = "completely fabricated detail", line = 1L),
    aliases               = list(),
    exhibited_personality = list(value = NULL, line = NULL),
    role_in_story         = list(value = NULL, line = NULL),
    affiliations          = list()
  )
  rec    <- make_entity_record()
  result <- verify_entity_citations(extraction, rec)
  expect_false(result$results$supported[[1L]])
})

# ---- verify_entity_citations — array fields ---------------------------------

test_that("array affiliations with line citations are checked", {
  # A data.frame (as fromJSON would produce for an array of objects)
  affiliations_df <- data.frame(name = "Giff Flotilla", line = 1L,
                                stringsAsFactors = FALSE)
  extraction <- list(
    description           = list(value = NULL, line = NULL),
    aliases               = list(),
    exhibited_personality = list(value = NULL, line = NULL),
    role_in_story         = list(value = NULL, line = NULL),
    affiliations          = affiliations_df
  )
  rec    <- make_entity_record()
  result <- verify_entity_citations(extraction, rec)
  expect_equal(result$n_checked, 1L)
  # "Giff Flotilla" appears in passage 1
  expect_true(result$results$supported[[1L]])
})

# ---- confidence arithmetic --------------------------------------------------

test_that("confidence = n_supported / n_checked", {
  extraction <- list(
    description           = list(value = "githyanki soldier", line = 1L),  # supported
    aliases               = list(),
    exhibited_personality = list(value = "fabricated trait xyz", line = 1L),  # unsupported
    role_in_story         = list(value = NULL, line = NULL),
    affiliations          = list()
  )
  rec    <- make_entity_record()
  result <- verify_entity_citations(extraction, rec)
  expect_equal(result$n_checked, 2L)
  expect_equal(result$n_unsupported, 1L)
  expect_equal(result$confidence, 0.5)
})
