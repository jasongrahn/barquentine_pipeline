library(testthat)
source(test_path("../../config.R"))
source(test_path("../../R/ollama.R"))
source(test_path("../../R/agentic_entity_fact_check.R"))

make_passages <- function() c(
  "Attorrnash is a githyanki soldier stationed on the Giff Flotilla.",
  "He spoke briefly with the Captain and seemed suspicious.",
  "The location was confirmed as the Astral Sea region."
)

# ---- .split_draft_claims ----------------------------------------------------

test_that("strips YAML frontmatter before splitting", {
  draft <- "---\nname: Attorrnash\nrole: soldier\n---\nHe is a githyanki soldier. He seems suspicious."
  claims <- .split_draft_claims(draft)
  expect_false(any(grepl("^---", claims)))
  expect_false(any(grepl("name:", claims)))
  expect_true(any(grepl("githyanki", claims)))
})

test_that("strips ## headers", {
  draft <- "## Background\nHe is a githyanki soldier. He seems suspicious."
  claims <- .split_draft_claims(draft)
  expect_false(any(grepl("^##", claims)))
})

test_that("drops claims shorter than 10 chars", {
  draft <- "Hi. A short one. This is a longer valid sentence indeed."
  claims <- .split_draft_claims(draft)
  expect_true(all(nchar(claims) >= 10L))
})

test_that("returns empty for NULL or blank draft", {
  expect_equal(.split_draft_claims(NULL), character(0))
  expect_equal(.split_draft_claims(""), character(0))
})

# ---- fact_check_entity — substring grounding --------------------------------

test_that("claim matching source text exactly is matched", {
  result <- fact_check_entity(
    entity_id       = "attorrnash",
    draft_markdown  = "Attorrnash is a githyanki soldier stationed on the Giff Flotilla.",
    source_passages = make_passages()
  )
  expect_equal(result$pipeline_path, "substring_grounding")
  expect_equal(result$coverage_score, 1.0)
  expect_length(result$matched_claims, 1L)
  expect_length(result$unmatched_claims, 0L)
})

test_that("claim not present in source is unmatched", {
  result <- fact_check_entity(
    entity_id       = "attorrnash",
    draft_markdown  = "Attorrnash is a powerful wizard of great renown.",
    source_passages = make_passages()
  )
  expect_equal(result$pipeline_path, "substring_grounding")
  expect_equal(result$coverage_score, 0.0)
  expect_length(result$matched_claims, 0L)
  expect_length(result$unmatched_claims, 1L)
})

test_that("direction: claim inside source_text (exact substring match)", {
  # Claim is a complete sentence from the source — should match
  result <- fact_check_entity(
    entity_id       = "attorrnash",
    draft_markdown  = "Attorrnash is a githyanki soldier stationed on the Giff Flotilla.",
    source_passages = c("Attorrnash is a githyanki soldier stationed on the Giff Flotilla.")
  )
  expect_equal(result$coverage_score, 1.0)
})

test_that("match is case-insensitive", {
  result <- fact_check_entity(
    entity_id       = "attorrnash",
    draft_markdown  = "ATTORRNASH IS A GITHYANKI SOLDIER STATIONED ON THE GIFF FLOTILLA.",
    source_passages = make_passages()
  )
  expect_equal(result$coverage_score, 1.0)
})

test_that("empty draft returns NA coverage_score with substring_grounding path", {
  result <- fact_check_entity("e", "", make_passages())
  expect_true(is.na(result$coverage_score))
  expect_equal(result$pipeline_path, "substring_grounding")
})

test_that("aps_proposition_count is source sentence count (integer >= 1)", {
  result <- fact_check_entity("e", "A sentence here for testing purposes.", make_passages())
  expect_type(result$aps_proposition_count, "integer")
  expect_gte(result$aps_proposition_count, 1L)
})

test_that("returns expected field names", {
  result <- fact_check_entity("e", "A sentence here for testing purposes.", make_passages())
  expect_true(all(c("matched_claims", "unmatched_claims", "coverage_score",
                    "aps_proposition_count", "pipeline_path") %in% names(result)))
})

test_that("no ollama_generate call is made (pure R, no LLM)", {
  # fact_check_entity must not call ollama_generate; stub it to error if called
  assign("ollama_generate", function(...) stop("should not be called"), envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)

  expect_no_error(
    fact_check_entity("e", "A sentence here for testing purposes.", make_passages())
  )
})
