library(testthat)

source(test_path("../../config.R"))
source(test_path("../../R/ollama.R"))
source(test_path("../../R/fact_critic.R"))

# --- Constants ---------------------------------------------------------------

test_that("FACT_VERIFY_SCHEMA has required fields", {
  expect_equal(FACT_VERIFY_SCHEMA$type, "object")
  expect_true("supported"    %in% FACT_VERIFY_SCHEMA$required)
  expect_true("source_quote" %in% FACT_VERIFY_SCHEMA$required)
  expect_true("reason"       %in% FACT_VERIFY_SCHEMA$required)
})

test_that("FACT_VERIFY_SYSTEM_PROMPT is a non-empty character string", {
  expect_type(FACT_VERIFY_SYSTEM_PROMPT, "character")
  expect_gt(nchar(FACT_VERIFY_SYSTEM_PROMPT), 10)
})

# --- verify_single_claim() ---------------------------------------------------

test_that("verify_single_claim returns supported=TRUE for supported claim", {
  assign("ollama_generate",
         function(...) '{"supported": true, "source_quote": "the infection spread through the town", "reason": "found in source"}',
         envir = globalenv())
  withr::defer(rm("ollama_generate", envir = globalenv()))

  result <- verify_single_claim("The infection spread", "the infection spread through the town")
  expect_equal(result$claim, "The infection spread")
  expect_true(result$supported)
  expect_equal(result$quote, "the infection spread through the town")
  expect_equal(result$reason, "found in source")
})

test_that("verify_single_claim returns supported=FALSE for unsupported claim", {
  assign("ollama_generate",
         function(...) '{"supported": false, "source_quote": "", "reason": "not found in source"}',
         envir = globalenv())
  withr::defer(rm("ollama_generate", envir = globalenv()))

  result <- verify_single_claim("Lumi fought a dragon", "the party rested at the inn")
  expect_equal(result$claim, "Lumi fought a dragon")
  expect_false(result$supported)
  expect_equal(result$reason, "not found in source")
})

test_that("verify_single_claim handles timeout", {
  assign("ollama_generate",
         function(...) list(timed_out = TRUE, verdict = NULL),
         envir = globalenv())
  withr::defer(rm("ollama_generate", envir = globalenv()))

  result <- verify_single_claim("some claim", "some source")
  expect_true(is.na(result$supported))
  expect_equal(result$reason, "verification_timeout")
  expect_true(is.na(result$quote))
})

test_that("verify_single_claim handles malformed JSON", {
  assign("ollama_generate",
         function(...) "this is not valid json",
         envir = globalenv())
  withr::defer(rm("ollama_generate", envir = globalenv()))

  result <- verify_single_claim("some claim", "some source")
  expect_true(is.na(result$supported))
  expect_equal(result$reason, "parse_error")
})

# --- .extract_claims() -------------------------------------------------------

test_that(".extract_claims extracts correct count and types from full facts", {
  facts <- list(
    events = list(
      list(description = "The party entered the cave", characters_involved = list("Room"), location = "Cave"),
      list(description = "A battle broke out", characters_involved = list("Lumi"), location = "Cave")
    ),
    npcs = list(
      list(name = "Grek", actions = list("attacked the party", "fled"), quotes = list("You shall not pass"))
    ),
    locations = list(
      list(name = "Cave", description = "A dark cavern beneath the mountain")
    ),
    threads = list(
      list(description = "The artifact remains missing", related_characters = list("Room"))
    )
  )

  claims <- .extract_claims(facts)
  expect_equal(length(claims), 7)

  types <- vapply(claims, function(c) c$type, character(1))
  expect_equal(sum(types == "event"), 2)
  expect_equal(sum(types == "npc_action"), 2)
  expect_equal(sum(types == "npc_quote"), 1)
  expect_equal(sum(types == "location"), 1)
  expect_equal(sum(types == "thread"), 1)
})

test_that(".extract_claims returns empty list for empty/NULL facts", {
  expect_equal(.extract_claims(list()), list())
  expect_equal(.extract_claims(list(events = NULL, npcs = NULL, locations = NULL, threads = NULL)), list())
  expect_equal(.extract_claims(list(events = list(), npcs = list())), list())
})

test_that(".extract_claims with NULL events but valid npcs still extracts NPC claims", {
  facts <- list(
    events = NULL,
    npcs = list(
      list(name = "Vex", actions = list("cast a spell"), quotes = list())
    )
  )
  claims <- .extract_claims(facts)
  expect_equal(length(claims), 1)
  expect_equal(claims[[1]]$type, "npc_action")
  expect_equal(claims[[1]]$text, "cast a spell")
})

test_that(".extract_claims skips empty/NA claim text", {
  facts <- list(
    events = list(
      list(description = "valid event", characters_involved = list(), location = ""),
      list(description = "", characters_involved = list(), location = ""),
      list(description = NA, characters_involved = list(), location = ""),
      list(description = "   ", characters_involved = list(), location = "")
    )
  )
  claims <- .extract_claims(facts)
  expect_equal(length(claims), 1)
  expect_equal(claims[[1]]$text, "valid event")
})

# --- .aggregate_verdict() ----------------------------------------------------

test_that(".aggregate_verdict with all supported returns approved and confidence 1.0", {
  results <- list(
    list(claim = "a", supported = TRUE, quote = "x", reason = "ok"),
    list(claim = "b", supported = TRUE, quote = "y", reason = "ok")
  )
  agg <- .aggregate_verdict(results)
  expect_equal(agg$verdict, "approved")
  expect_equal(agg$confidence, 1.0)
  expect_equal(agg$total, 2L)
  expect_equal(agg$supported, 2L)
  expect_equal(agg$unsupported, 0L)
})

test_that(".aggregate_verdict with exactly 80% returns approved", {
  results <- list(
    list(claim = "a", supported = TRUE, quote = "x", reason = "ok"),
    list(claim = "b", supported = TRUE, quote = "y", reason = "ok"),
    list(claim = "c", supported = TRUE, quote = "z", reason = "ok"),
    list(claim = "d", supported = TRUE, quote = "w", reason = "ok"),
    list(claim = "e", supported = FALSE, quote = NA_character_, reason = "not found")
  )
  agg <- .aggregate_verdict(results)
  expect_equal(agg$verdict, "approved")
  expect_equal(agg$confidence, 0.8)
})

test_that(".aggregate_verdict with less than 80% returns flagged", {
  results <- list(
    list(claim = "a", supported = TRUE,  quote = "x", reason = "ok"),
    list(claim = "b", supported = FALSE, quote = NA_character_, reason = "nope"),
    list(claim = "c", supported = FALSE, quote = NA_character_, reason = "nope")
  )
  agg <- .aggregate_verdict(results)
  expect_equal(agg$verdict, "flagged")
  expect_lt(agg$confidence, 0.80)
  expect_equal(agg$unsupported, 2L)
})

test_that(".aggregate_verdict with no claims returns approved and confidence 1.0", {
  agg <- .aggregate_verdict(list())
  expect_equal(agg$verdict, "approved")
  expect_equal(agg$confidence, 1.0)
  expect_equal(agg$total, 0L)
  expect_equal(agg$supported, 0L)
  expect_equal(agg$unsupported, 0L)
})

test_that(".aggregate_verdict filters out NA results", {
  results <- list(
    list(claim = "a", supported = TRUE, quote = "x", reason = "ok"),
    list(claim = "b", supported = NA,   quote = NA_character_, reason = "verification_timeout"),
    list(claim = "c", supported = TRUE, quote = "z", reason = "ok")
  )
  agg <- .aggregate_verdict(results)
  expect_equal(agg$verdict, "approved")
  expect_equal(agg$confidence, 1.0)
  expect_equal(agg$total, 2L)
  expect_equal(agg$supported, 2L)
  # NA result is still in the results list, just not counted
  expect_equal(length(agg$results), 3)
})

# --- verify_facts() end-to-end -----------------------------------------------

test_that("verify_facts end-to-end with mocked ollama_generate", {
  assign("ollama_generate",
         function(...) '{"supported": true, "source_quote": "matching text", "reason": "found in source"}',
         envir = globalenv())
  withr::defer(rm("ollama_generate", envir = globalenv()))

  facts <- list(
    events = list(
      list(description = "The party fought goblins", characters_involved = list("Room"), location = "Forest")
    ),
    npcs = list(
      list(name = "Grek", actions = list("swung his axe"), quotes = list())
    ),
    locations = list(),
    threads = list()
  )

  result <- verify_facts(facts, "The party fought goblins in the forest. Grek swung his axe.")
  expect_equal(result$verdict, "approved")
  expect_equal(result$confidence, 1.0)
  expect_equal(result$total, 2L)
  expect_equal(result$supported, 2L)
  expect_equal(result$unsupported, 0L)
  expect_equal(length(result$results), 2)
  expect_equal(result$results[[1]]$type, "event")
  expect_equal(result$results[[2]]$type, "npc_action")
})
