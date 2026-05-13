library(testthat)

source(test_path("../../config.R"))
source(test_path("../../R/ollama.R"))
source(test_path("../../R/extract_facts.R"))

# --- Schemas ------------------------------------------------------------------

test_that("EVENT_SCHEMA has required fields", {
  expect_equal(EVENT_SCHEMA$type, "object")
  expect_equal(EVENT_SCHEMA$required, "events")
  props <- EVENT_SCHEMA$properties$events$items$properties
  expect_true("description"         %in% names(props))
  expect_true("characters_involved" %in% names(props))
  expect_true("location"            %in% names(props))
})

test_that("NPC_SCHEMA has required fields", {
  expect_equal(NPC_SCHEMA$type, "object")
  expect_equal(NPC_SCHEMA$required, "npcs")
  props <- NPC_SCHEMA$properties$npcs$items$properties
  expect_true("name"    %in% names(props))
  expect_true("actions" %in% names(props))
  expect_true("quotes"  %in% names(props))
})

test_that("LOCATION_SCHEMA has required fields", {
  expect_equal(LOCATION_SCHEMA$type, "object")
  expect_equal(LOCATION_SCHEMA$required, "locations")
  props <- LOCATION_SCHEMA$properties$locations$items$properties
  expect_true("name"        %in% names(props))
  expect_true("description" %in% names(props))
})

test_that("THREAD_SCHEMA has required fields", {
  expect_equal(THREAD_SCHEMA$type, "object")
  expect_equal(THREAD_SCHEMA$required, "threads")
  props <- THREAD_SCHEMA$properties$threads$items$properties
  expect_true("description"        %in% names(props))
  expect_true("related_characters" %in% names(props))
})

# --- System prompts -----------------------------------------------------------

test_that("system prompts are non-empty and contain key words", {
  expect_gt(nchar(EVENT_SYSTEM_PROMPT), 10)
  expect_true(grepl("event",     EVENT_SYSTEM_PROMPT, ignore.case = TRUE))
  expect_true(grepl("fabricate", EVENT_SYSTEM_PROMPT, ignore.case = TRUE))

  expect_gt(nchar(NPC_SYSTEM_PROMPT), 10)
  expect_true(grepl("NPC",       NPC_SYSTEM_PROMPT, ignore.case = TRUE))
  expect_true(grepl("fabricate", NPC_SYSTEM_PROMPT, ignore.case = TRUE))

  expect_gt(nchar(LOCATION_SYSTEM_PROMPT), 10)
  expect_true(grepl("location",  LOCATION_SYSTEM_PROMPT, ignore.case = TRUE))
  expect_true(grepl("fabricate", LOCATION_SYSTEM_PROMPT, ignore.case = TRUE))

  expect_gt(nchar(THREAD_SYSTEM_PROMPT), 10)
  expect_true(grepl("thread",    THREAD_SYSTEM_PROMPT, ignore.case = TRUE))
  expect_true(grepl("fabricate", THREAD_SYSTEM_PROMPT, ignore.case = TRUE))
})

# --- chunk_source_text() ------------------------------------------------------

test_that("chunk_source_text returns single chunk for short text", {
  short <- paste(rep("word", 100), collapse = " ")
  chunks <- chunk_source_text(short)
  expect_length(chunks, 1)
  expect_equal(chunks[1], short)
})

test_that("chunk_source_text returns multiple chunks for long text", {
  long <- paste(rep("word", 3000), collapse = " ")
  chunks <- chunk_source_text(long, chunk_words = 1500L, overlap_words = 150L)
  expect_gt(length(chunks), 1)
})

test_that("chunk_source_text overlaps chunks", {
  words <- paste(seq_len(200), collapse = " ")
  chunks <- chunk_source_text(words, chunk_words = 100L, overlap_words = 20L)
  expect_length(chunks, 3)
  # words 81-100 from chunk 1 should appear at start of chunk 2
  chunk1_words <- str_split(chunks[1], "\\s+")[[1]]
  chunk2_words <- str_split(chunks[2], "\\s+")[[1]]
  overlap_tail <- tail(chunk1_words, 20)
  overlap_head <- head(chunk2_words, 20)
  expect_equal(overlap_tail, overlap_head)
})

test_that("chunk_source_text handles empty text", {
  expect_length(chunk_source_text(""), 0)
  expect_length(chunk_source_text("   "), 0)
})

# --- extract_events() --------------------------------------------------------

test_that("extract_events parses valid JSON", {
  assign("ollama_generate", function(...) {
    '{"events": [{"description": "Party fought goblins", "characters_involved": ["Room", "Lumi"], "location": "Tavern"}]}'
  }, envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  source(test_path("../../R/extract_facts.R"))

  result <- extract_events("some text")
  expect_length(result, 1)
  expect_equal(result[[1]]$description, "Party fought goblins")
  expect_equal(result[[1]]$characters_involved, list("Room", "Lumi"))
  expect_equal(result[[1]]$location, "Tavern")
})

test_that("extract_events returns empty list on timeout", {
  assign("ollama_generate", function(...) list(timed_out = TRUE, verdict = NULL),
         envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  source(test_path("../../R/extract_facts.R"))

  result <- extract_events("some text")
  expect_length(result, 0)
})

test_that("extract_events returns empty list on malformed JSON", {
  assign("ollama_generate", function(...) "not valid json {{{",
         envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  source(test_path("../../R/extract_facts.R"))

  result <- extract_events("some text")
  expect_length(result, 0)
})

test_that("extract_events returns empty list when events key missing", {
  assign("ollama_generate", function(...) '{"other_key": []}',
         envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  source(test_path("../../R/extract_facts.R"))

  result <- extract_events("some text")
  expect_length(result, 0)
})

# --- extract_npcs() -----------------------------------------------------------

test_that("extract_npcs parses valid JSON", {
  assign("ollama_generate", function(...) {
    '{"npcs": [{"name": "Attorrnash", "actions": ["greeted party"], "quotes": ["Welcome"]}]}'
  }, envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  source(test_path("../../R/extract_facts.R"))

  result <- extract_npcs("some text")
  expect_length(result, 1)
  expect_equal(result[[1]]$name, "Attorrnash")
})

test_that("extract_npcs returns empty list on timeout", {
  assign("ollama_generate", function(...) list(timed_out = TRUE, verdict = NULL),
         envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  source(test_path("../../R/extract_facts.R"))

  result <- extract_npcs("some text")
  expect_length(result, 0)
})

# --- extract_locations() ------------------------------------------------------

test_that("extract_locations parses valid JSON", {
  assign("ollama_generate", function(...) {
    '{"locations": [{"name": "The Giff Flotilla", "description": "A fleet of giff warships"}]}'
  }, envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  source(test_path("../../R/extract_facts.R"))

  result <- extract_locations("some text")
  expect_length(result, 1)
  expect_equal(result[[1]]$name, "The Giff Flotilla")
})

test_that("extract_locations returns empty list on timeout", {
  assign("ollama_generate", function(...) list(timed_out = TRUE, verdict = NULL),
         envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  source(test_path("../../R/extract_facts.R"))

  result <- extract_locations("some text")
  expect_length(result, 0)
})

# --- extract_threads() --------------------------------------------------------

test_that("extract_threads parses valid JSON", {
  assign("ollama_generate", function(...) {
    '{"threads": [{"description": "Who stole the gem?", "related_characters": ["Room"]}]}'
  }, envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  source(test_path("../../R/extract_facts.R"))

  result <- extract_threads("some text")
  expect_length(result, 1)
  expect_equal(result[[1]]$description, "Who stole the gem?")
})

test_that("extract_threads returns empty list on timeout", {
  assign("ollama_generate", function(...) list(timed_out = TRUE, verdict = NULL),
         envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  source(test_path("../../R/extract_facts.R"))

  result <- extract_threads("some text")
  expect_length(result, 0)
})

# --- dedupe_npcs() ------------------------------------------------------------

test_that("dedupe_npcs merges same NPC across chunks (case-insensitive)", {
  chunk1 <- list(
    list(name = "Attorrnash", actions = list("greeted party"), quotes = list("Welcome"))
  )
  chunk2 <- list(
    list(name = "attorrnash", actions = list("attacked"), quotes = list("Die!"))
  )
  result <- dedupe_npcs(list(chunk1, chunk2))
  expect_length(result, 1)
  expect_equal(result[[1]]$name, "Attorrnash")
  expect_true("greeted party" %in% result[[1]]$actions)
  expect_true("attacked"      %in% result[[1]]$actions)
  expect_true("Welcome"       %in% result[[1]]$quotes)
  expect_true("Die!"          %in% result[[1]]$quotes)
})

test_that("dedupe_npcs keeps distinct NPCs separate", {
  chunk1 <- list(
    list(name = "Attorrnash", actions = list("greeted"), quotes = list())
  )
  chunk2 <- list(
    list(name = "Brak", actions = list("fought"), quotes = list())
  )
  result <- dedupe_npcs(list(chunk1, chunk2))
  expect_length(result, 2)
})

test_that("dedupe_npcs handles empty input", {
  expect_length(dedupe_npcs(list()), 0)
  expect_length(dedupe_npcs(list(list())), 0)
})

test_that("dedupe_npcs deduplicates actions within merged NPC", {
  chunk1 <- list(
    list(name = "Attorrnash", actions = list("greeted party"), quotes = list())
  )
  chunk2 <- list(
    list(name = "Attorrnash", actions = list("greeted party", "attacked"), quotes = list())
  )
  result <- dedupe_npcs(list(chunk1, chunk2))
  expect_length(result, 1)
  expect_length(result[[1]]$actions, 2)
})

# --- dedupe_events() ----------------------------------------------------------

test_that("dedupe_events removes duplicate events", {
  chunk1 <- list(
    list(description = "Party entered the cave", characters_involved = list("Room"), location = "Cave")
  )
  chunk2 <- list(
    list(description = "Party entered the cave", characters_involved = list("Room"), location = "Cave")
  )
  result <- dedupe_events(list(chunk1, chunk2))
  expect_length(result, 1)
})

test_that("dedupe_events removes substring matches", {
  chunk1 <- list(
    list(description = "Party entered the cave", characters_involved = list("Room"), location = "Cave")
  )
  chunk2 <- list(
    list(description = "party entered the cave and fought goblins", characters_involved = list("Room"), location = "Cave")
  )
  result <- dedupe_events(list(chunk1, chunk2))
  expect_length(result, 1)
})

test_that("dedupe_events keeps distinct events", {
  chunk1 <- list(
    list(description = "Party entered the cave", characters_involved = list("Room"), location = "Cave")
  )
  chunk2 <- list(
    list(description = "Lumi cast a spell", characters_involved = list("Lumi"), location = "Forest")
  )
  result <- dedupe_events(list(chunk1, chunk2))
  expect_length(result, 2)
})

test_that("dedupe_events handles empty input", {
  expect_length(dedupe_events(list()), 0)
  expect_length(dedupe_events(list(list())), 0)
})

# --- extract_session_facts() --------------------------------------------------

test_that("extract_session_facts returns full structure with mocked ollama", {
  assign("ollama_generate", function(prompt, system_prompt, ...) {
    if (grepl("event", system_prompt, ignore.case = TRUE)) {
      return('{"events": [{"description": "Battle at docks", "characters_involved": ["Room"], "location": "Docks"}]}')
    }
    if (grepl("NPC", system_prompt, ignore.case = TRUE)) {
      return('{"npcs": [{"name": "Brak", "actions": ["fought"], "quotes": ["Argh"]}]}')
    }
    if (grepl("location", system_prompt, ignore.case = TRUE)) {
      return('{"locations": [{"name": "Docks", "description": "Busy harbor"}]}')
    }
    if (grepl("thread", system_prompt, ignore.case = TRUE)) {
      return('{"threads": [{"description": "Missing cargo", "related_characters": ["Brak"]}]}')
    }
    return('{}')
  }, envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  source(test_path("../../R/extract_facts.R"))

  short_text <- paste(rep("word", 100), collapse = " ")
  result <- extract_session_facts(short_text)

  expect_true(is.list(result))
  expect_true(all(c("events", "npcs", "locations", "threads") %in% names(result)))

  expect_length(result$events, 1)
  expect_equal(result$events[[1]]$description, "Battle at docks")

  expect_length(result$npcs, 1)
  expect_equal(result$npcs[[1]]$name, "Brak")

  expect_length(result$locations, 1)
  expect_equal(result$locations[[1]]$name, "Docks")

  expect_length(result$threads, 1)
  expect_equal(result$threads[[1]]$description, "Missing cargo")
})

test_that("extract_session_facts returns empty structure for empty text", {
  result <- extract_session_facts("")
  expect_equal(result, list(events = list(), npcs = list(),
                            locations = list(), threads = list()))
})

test_that("extract_session_facts deduplicates NPCs across chunks", {
  assign("ollama_generate", function(prompt, system_prompt, ...) {
    if (grepl("NPC", system_prompt, ignore.case = TRUE)) {
      return('{"npcs": [{"name": "Brak", "actions": ["fought"], "quotes": []}]}')
    }
    if (grepl("event", system_prompt, ignore.case = TRUE))    return('{"events": []}')
    if (grepl("location", system_prompt, ignore.case = TRUE)) return('{"locations": []}')
    if (grepl("thread", system_prompt, ignore.case = TRUE))   return('{"threads": []}')
    return('{}')
  }, envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  source(test_path("../../R/extract_facts.R"))

  # 3000 words = 2+ chunks, each returning the same NPC
  long_text <- paste(rep("word", 3000), collapse = " ")
  result <- extract_session_facts(long_text)

  expect_length(result$npcs, 1)
  expect_equal(result$npcs[[1]]$name, "Brak")
})

test_that("extract_session_facts handles all-timeout gracefully", {
  assign("ollama_generate", function(...) list(timed_out = TRUE, verdict = NULL),
         envir = globalenv())
  on.exit(rm("ollama_generate", envir = globalenv()), add = TRUE)
  source(test_path("../../R/extract_facts.R"))

  short_text <- paste(rep("word", 100), collapse = " ")
  result <- extract_session_facts(short_text)

  expect_true(is.list(result))
  expect_length(result$events, 0)
  expect_length(result$npcs, 0)
  expect_length(result$locations, 0)
  expect_length(result$threads, 0)
})
