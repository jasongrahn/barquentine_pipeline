library(testthat)
source(test_path("../../config.R"))
source(test_path("../../R/ollama.R"))
source(test_path("../../R/agentic_entity_fact_check.R"))

make_passages <- function() c(
  "Attorrnash is a githyanki soldier stationed on the Giff Flotilla.",
  "He spoke briefly with the Captain and seemed suspicious.",
  "The location was confirmed as the Astral Sea region."
)

# ---- .parse_aps_propositions ------------------------------------------------

test_that("parses hyphen-bullet propositions correctly", {
  raw <- ": PROPOSITIONS:\n<s>\n- Attorrnash is a soldier.\n- He is suspicious.\n</s>"
  props <- .parse_aps_propositions(raw)
  expect_equal(props, c("Attorrnash is a soldier.", "He is suspicious."))
})

test_that("strips numbered bullets", {
  raw <- ": PROPOSITIONS:\n<s>\n1. First prop.\n2. Second prop.\n</s>"
  props <- .parse_aps_propositions(raw)
  expect_equal(props, c("First prop.", "Second prop."))
})

test_that("drops empty lines and sentinel tags", {
  raw <- ": PROPOSITIONS:\n<s>\n\n- Real prop.\n\n</s>"
  props <- .parse_aps_propositions(raw)
  expect_equal(props, "Real prop.")
})

test_that("returns empty character for NULL or blank input", {
  expect_equal(.parse_aps_propositions(NULL), character(0))
  expect_equal(.parse_aps_propositions(""), character(0))
  expect_equal(.parse_aps_propositions("   "), character(0))
})

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

# ---- fact_check_entity — coverage score -------------------------------------

test_that("coverage_score = 1.0 when all claims match a proposition", {
  assign("ollama_generate", function(...) {
    ": PROPOSITIONS:\n<s>\n- Attorrnash is a githyanki soldier.\n- He seems suspicious.\n</s>"
  }, envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)

  result <- fact_check_entity(
    entity_id       = "attorrnash",
    draft_markdown  = "Attorrnash is a githyanki soldier. He seems suspicious.",
    source_passages = make_passages()
  )
  expect_equal(result$pipeline_path, "aps_grounding")
  expect_gte(result$coverage_score, 0)
  expect_lte(result$coverage_score, 1)
  expect_true(is.character(result$matched_claims))
  expect_true(is.character(result$unmatched_claims))
})

test_that("aps_error path returned on timeout", {
  assign("ollama_generate", function(...) list(timed_out = TRUE),
         envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)

  result <- fact_check_entity("e", "Some draft.", make_passages())
  expect_equal(result$pipeline_path, "aps_error")
  expect_true(is.na(result$coverage_score))
})

test_that("aps_error path returned on empty proposition list", {
  assign("ollama_generate", function(...) ": PROPOSITIONS:\n<s>\n</s>",
         envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)

  result <- fact_check_entity("e", "Some draft.", make_passages())
  expect_equal(result$pipeline_path, "aps_error")
  expect_true(is.na(result$coverage_score))
})

# ---- matcher direction: proposition text must appear INSIDE claim (not vice-versa) ----

test_that("claim containing proposition text is matched (direction check)", {
  # Proposition is a short phrase; claim is a longer sentence containing it.
  # Correct direction: str_detect(claim, proposition) → TRUE
  assign("ollama_generate", function(...) {
    ": PROPOSITIONS:\n<s>\n- githyanki soldier\n- seems suspicious\n</s>"
  }, envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)

  result <- fact_check_entity(
    entity_id       = "attorrnash",
    draft_markdown  = "Attorrnash is a githyanki soldier stationed on the Flotilla.",
    source_passages = make_passages()
  )
  expect_length(result$matched_claims, 1L)
  expect_length(result$unmatched_claims, 0L)
  expect_equal(result$coverage_score, 1.0)
})

test_that("claim NOT containing any proposition text is unmatched (direction check)", {
  assign("ollama_generate", function(...) {
    ": PROPOSITIONS:\n<s>\n- completely unrelated text\n</s>"
  }, envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)

  result <- fact_check_entity(
    entity_id       = "attorrnash",
    draft_markdown  = "Attorrnash is a githyanki soldier stationed on the Flotilla.",
    source_passages = make_passages()
  )
  expect_length(result$matched_claims, 0L)
  expect_length(result$unmatched_claims, 1L)
  expect_equal(result$coverage_score, 0.0)
})

test_that("returns expected field names", {
  assign("ollama_generate", function(...) {
    ": PROPOSITIONS:\n<s>\n- A proposition.\n</s>"
  }, envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)

  result <- fact_check_entity("e", "A sentence here for testing purposes.", make_passages())
  expect_true(all(c("matched_claims", "unmatched_claims", "coverage_score",
                    "aps_proposition_count", "pipeline_path") %in% names(result)))
})
