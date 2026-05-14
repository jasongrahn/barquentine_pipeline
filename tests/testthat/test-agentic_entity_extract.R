library(testthat)
source(test_path("../../config.R"))
source(test_path("../../R/agentic_extract.R"))
source(test_path("../../R/agentic_entity_schemas.R"))
source(test_path("../../R/agentic_entity_extract.R"))

make_entity_record <- function(note_type = "npc", n_passages = 3L) {
  list(
    entity_id          = "attorrnash",
    entity_name        = "Attorrnash",
    note_type          = note_type,
    source_passages    = paste0("Passage text ", seq_len(n_passages), " about attorrnash."),
    source_episode_ids = "s02e34"
  )
}

# ---- .entity_skill_name() ---------------------------------------------------

test_that(".entity_skill_name selects correct skill per note_type", {
  expect_equal(.entity_skill_name("pc"),       "05_extract_pc")
  expect_equal(.entity_skill_name("npc"),      "06_extract_npc")
  expect_equal(.entity_skill_name("location"), "07_extract_location")
  expect_equal(.entity_skill_name("faction"),  "08_extract_faction")
  expect_error(.entity_skill_name("unknown"))
})

# ---- .truncate_passages() ---------------------------------------------------

test_that(".truncate_passages keeps all passages when under the limit", {
  passages <- c("short one", "short two", "short three")
  result   <- .truncate_passages(passages, word_limit = 1000L)
  expect_equal(result, passages)
})

test_that(".truncate_passages drops trailing passages exceeding word_limit", {
  # Each passage is ~50 words; limit to 60 should keep 1
  long_passage <- paste(rep("word", 50L), collapse = " ")
  passages     <- rep(long_passage, 5L)
  result <- expect_warning(
    .truncate_passages(passages, word_limit = 60L),
    "truncated"
  )
  expect_lt(length(result), length(passages))
  expect_gte(length(result), 1L)
})

test_that(".truncate_passages always keeps at least one passage", {
  huge_passage <- paste(rep("word", 10000L), collapse = " ")
  result <- suppressWarnings(
    .truncate_passages(huge_passage, word_limit = 1L)
  )
  expect_equal(length(result), 1L)
})

# ---- extract_entity() — stub .call_ollama_skill ----------------------------

SKILLS_DIR <- test_path("../../agents/wiki_skills")

test_that("extract_entity returns correct entity_id and note_type", {
  assign(".call_ollama_skill", function(...) '{"description": {"value": "A githyanki soldier.", "line": 1}, "aliases": [], "exhibited_personality": {"value": null, "line": null}, "role_in_story": {"value": null, "line": null}}',
         envir = globalenv())
  on.exit(rm(".call_ollama_skill", envir = globalenv()), add = TRUE)

  rec    <- make_entity_record("npc")
  result <- extract_entity(rec, skills_dir = SKILLS_DIR)

  expect_equal(result$entity_id, "attorrnash")
  expect_equal(result$note_type, "npc")
  expect_false(result$timed_out)
})

test_that("extract_entity sets timed_out=TRUE and extraction=NULL on timeout", {
  assign(".call_ollama_skill", function(...) list(timed_out = TRUE),
         envir = globalenv())
  on.exit(rm(".call_ollama_skill", envir = globalenv()), add = TRUE)

  rec    <- make_entity_record("npc")
  result <- extract_entity(rec, skills_dir = SKILLS_DIR)

  expect_true(result$timed_out)
  expect_null(result$extraction)
})

test_that("extract_entity handles JSON parse failure gracefully", {
  assign(".call_ollama_skill", function(...) "not json at all",
         envir = globalenv())
  on.exit(rm(".call_ollama_skill", envir = globalenv()), add = TRUE)

  rec    <- make_entity_record("location")
  result <- suppressWarnings(extract_entity(rec, skills_dir = SKILLS_DIR))

  expect_false(result$timed_out)
  expect_null(result$extraction)
})

test_that("extract_entity uses pc skill for pc note_type", {
  skill_used <- NULL
  assign(".call_ollama_skill", function(model, base_url, system, user, ...) {
    skill_used <<- if (grepl("player character", system, ignore.case = TRUE)) "pc" else "other"
    '{"bio": {"value": null, "line": null}, "description": {"value": null, "line": null}, "aliases": [], "exhibited_personality": {"value": null, "line": null}, "role_in_story": {"value": null, "line": null}, "relatives": []}'
  }, envir = globalenv())
  on.exit(rm(".call_ollama_skill", envir = globalenv()), add = TRUE)

  rec    <- make_entity_record("pc")
  result <- extract_entity(rec, skills_dir = SKILLS_DIR)

  expect_equal(skill_used, "pc")
  expect_false(result$timed_out)
})
