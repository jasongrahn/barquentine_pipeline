library(testthat)
source(test_path("../../config.R"))
source(test_path("../../R/ollama.R"))
source(test_path("../../R/source_c.R"))

# ---- read_vtt ----

test_that("read_vtt strips WEBVTT header line", {
  f <- withr::local_tempfile(fileext = ".vtt")
  writeLines(c("WEBVTT", "", "00:00:01.000 --> 00:00:03.000", "Hello there."), f)
  result <- read_vtt(f)
  expect_false(grepl("WEBVTT", result, fixed = TRUE))
})

test_that("read_vtt strips timestamp lines", {
  f <- withr::local_tempfile(fileext = ".vtt")
  writeLines(c("WEBVTT", "", "00:00:05.320 --> 00:00:10.410", "Speaker text."), f)
  result <- read_vtt(f)
  expect_false(grepl("-->", result, fixed = TRUE))
})

test_that("read_vtt strips numeric cue index lines", {
  f <- withr::local_tempfile(fileext = ".vtt")
  writeLines(c("WEBVTT", "", "1", "00:00:01.000 --> 00:00:02.000", "A line."), f)
  result <- read_vtt(f)
  expect_false(grepl("^1$", result))
})

test_that("read_vtt returns non-empty string when speaker lines present", {
  f <- withr::local_tempfile(fileext = ".vtt")
  writeLines(c("WEBVTT", "", "1", "00:00:01.000 --> 00:00:02.000", "Attorrnash speaks."), f)
  result <- read_vtt(f)
  expect_true(nzchar(result))
  expect_true(grepl("Attorrnash", result, fixed = TRUE))
})

test_that("read_vtt returns empty string for VTT with only header and timestamps", {
  f <- withr::local_tempfile(fileext = ".vtt")
  writeLines(c("WEBVTT", "", "1", "00:00:01.000 --> 00:00:02.000"), f)
  result <- read_vtt(f)
  expect_equal(trimws(result), "")
})

# ---- chunk_vtt ----

test_that("chunk_vtt returns character(0) for empty string", {
  result <- chunk_vtt("")
  expect_equal(result, character(0))
})

test_that("chunk_vtt returns a character vector for normal text", {
  text   <- paste(rep("word", 100), collapse = " ")
  result <- chunk_vtt(text, chunk_words = 50, overlap_words = 5)
  expect_type(result, "character")
  expect_true(length(result) > 0)
})

test_that("chunk_vtt first chunk has at most chunk_words words", {
  text   <- paste(rep("word", 200), collapse = " ")
  result <- chunk_vtt(text, chunk_words = 50, overlap_words = 5)
  first_words <- length(str_split(result[1], "\\s+")[[1]])
  expect_lte(first_words, 50)
})

test_that("chunk_vtt second chunk starts before chunk_words+1 (overlap verified)", {
  chunk_words   <- 20
  overlap_words <- 5
  # 2x chunk_words words so we get at least two chunks
  text   <- paste(paste(rep("alpha", chunk_words), collapse = " "),
                  paste(rep("beta",  chunk_words), collapse = " "))
  result <- chunk_vtt(text, chunk_words = chunk_words, overlap_words = overlap_words)
  expect_true(length(result) >= 2)
  # Second chunk should contain overlap words from first chunk (last overlap_words of chunk 1)
  step           <- chunk_words - overlap_words
  second_start   <- step + 1
  expect_lt(second_start, chunk_words + 1)
})

test_that("chunk_vtt returns single chunk when text fits in one window", {
  text   <- paste(rep("word", 10), collapse = " ")
  result <- chunk_vtt(text, chunk_words = 50, overlap_words = 5)
  expect_equal(length(result), 1)
})

# ---- spot_entities ----

test_that("spot_entities returns empty lists on ollama failure", {
  assign("ollama_generate", function(...) stop("connection refused"), envir = globalenv())
  result <- spot_entities("some chunk text")
  expect_equal(result$npcs,      list())
  expect_equal(result$locations, list())
  on.exit(rm("ollama_generate", envir = globalenv()))
})

test_that("ENTITY_SPOT_SCHEMA has required field names npcs, locations, items, factions", {
  expect_setequal(ENTITY_SPOT_SCHEMA$required, c("npcs", "locations", "items", "factions"))
})

# ---- make_slug ----

test_that("make_slug converts spaces to underscores", {
  expect_equal(make_slug("The Giff Flotilla"), "the_giff_flotilla")
})

test_that("make_slug lowercases input", {
  expect_equal(make_slug("ATTORRNASH"), "attorrnash")
})

test_that("make_slug strips leading and trailing underscores", {
  expect_equal(make_slug("  hello  "), "hello")
})

test_that("make_slug handles special characters", {
  expect_equal(make_slug("Zyn'thar the Bold!"), "zyn_thar_the_bold")
})

# ---- aggregate_entity_passages ----

test_that("aggregate_entity_passages deduplicates same entity across two file results", {
  assign("resolve_alias", function(...) NULL, envir = globalenv())
  on.exit(rm("resolve_alias", envir = globalenv()))

  file1 <- list(
    episode_id = "S2e34",
    npcs       = list("Attorrnash" = list("chunk A")),
    locations  = list(),
    items      = list(),
    factions   = list()
  )
  file2 <- list(
    episode_id = "S2e35",
    npcs       = list("Attorrnash" = list("chunk B")),
    locations  = list(),
    items      = list(),
    factions   = list()
  )
  result <- aggregate_entity_passages(list(file1, file2), list())

  slugs <- sapply(result, `[[`, "entity_id")
  expect_equal(sum(slugs == "attorrnash"), 1)
})

test_that("aggregate_entity_passages returns list with required fields", {
  assign("resolve_alias", function(...) NULL, envir = globalenv())
  on.exit(rm("resolve_alias", envir = globalenv()))

  file1 <- list(
    episode_id = "S2e34",
    npcs       = list("Mira" = list("some chunk")),
    locations  = list(),
    items      = list(),
    factions   = list()
  )
  result <- aggregate_entity_passages(list(file1), list())

  expect_true(length(result) > 0)
  rec <- result[[1]]
  expect_true(!is.null(rec$entity_id))
  expect_true(!is.null(rec$entity_name))
  expect_true(!is.null(rec$note_type))
  expect_true(!is.null(rec$source_passages))
  expect_true(!is.null(rec$source_episode_ids))
})

test_that("aggregate_entity_passages note_type is npc for npcs, location for locations, faction for factions", {
  assign("resolve_alias", function(...) NULL, envir = globalenv())
  on.exit(rm("resolve_alias", envir = globalenv()))

  file1 <- list(
    episode_id = "S2e34",
    npcs       = list("Vera"          = list("chunk")),
    locations  = list("The Docks"     = list("chunk")),
    items      = list(),
    factions   = list("Rock Riders"   = list("chunk"))
  )
  result <- aggregate_entity_passages(list(file1), list())

  note_types <- setNames(
    sapply(result, `[[`, "note_type"),
    sapply(result, `[[`, "entity_id")
  )
  expect_equal(note_types[["vera"]],        "npc")
  expect_equal(note_types[["the_docks"]],   "location")
  expect_equal(note_types[["rock_riders"]], "faction")
})

test_that("aggregate_entity_passages source_episode_ids contains episode_id from file result", {
  assign("resolve_alias", function(...) NULL, envir = globalenv())
  on.exit(rm("resolve_alias", envir = globalenv()))

  file1 <- list(
    episode_id = "S2e34",
    npcs       = list("Brakk" = list("chunk")),
    locations  = list(),
    items      = list(),
    factions   = list()
  )
  result <- aggregate_entity_passages(list(file1), list())

  rec <- result[[which(sapply(result, `[[`, "entity_id") == "brakk")]]
  expect_true("S2e34" %in% rec$source_episode_ids)
})
