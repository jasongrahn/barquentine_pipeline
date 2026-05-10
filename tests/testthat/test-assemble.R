library(testthat)

source(test_path("../../R/assemble.R"))

# --- .wikify_name() -----------------------------------------------------------

test_that(".wikify_name wraps plain names in wikilinks", {
  expect_equal(.wikify_name("War Saint"), "[[War Saint]]")
})

test_that(".wikify_name resolves Captain to Basil alias", {
  expect_equal(.wikify_name("Captain"), "[[Basil|the Captain]]")
})

test_that(".wikify_name resolves 'the Captain' to Basil alias", {
  expect_equal(.wikify_name("the Captain"), "[[Basil|the Captain]]")
})

test_that(".wikify_name resolves Basil to the Captain display", {
  expect_equal(.wikify_name("Basil"), "[[Basil|the Captain]]")
})

test_that(".wikify_name passes through already-linked names unchanged", {
  expect_equal(.wikify_name("[[already linked]]"), "[[already linked]]")
})

test_that(".wikify_name returns empty string for empty input", {
  expect_equal(.wikify_name(""), "")
})

test_that(".wikify_name returns empty string for NA", {
  expect_equal(.wikify_name(NA), "")
})

test_that(".wikify_name returns empty string for NULL", {
  expect_equal(.wikify_name(NULL), "")
})

test_that(".wikify_name resolves Room without display alias", {
  expect_equal(.wikify_name("Room"), "[[Room]]")
})

# --- .format_event_line() -----------------------------------------------------

test_that(".format_event_line includes dash separator and wikified location", {
  event <- list(
    description = "The infection spread",
    characters_involved = c("Room"),
    location = "Ship"
  )
  result <- .format_event_line(event)
  expect_true(grepl("^- The infection spread", result))
  expect_true(grepl("\\[\\[Room\\]\\]", result))
  expect_true(grepl("— \\[\\[Ship\\]\\]", result))
})

test_that(".format_event_line omits dash when location is missing", {
  event <- list(
    description = "Something happened",
    characters_involved = c("Lumi"),
    location = NA
  )
  result <- .format_event_line(event)
  expect_false(grepl("—", result))
  expect_true(grepl("\\[\\[Lumi\\]\\]", result))
})

test_that(".format_event_line omits dash when location is NULL", {
  event <- list(
    description = "Something happened",
    characters_involved = c("Lumi"),
    location = NULL
  )
  result <- .format_event_line(event)
  expect_false(grepl("—", result))
})

test_that(".format_event_line handles empty characters", {
  event <- list(
    description = "A quiet moment",
    characters_involved = character(0),
    location = "Tavern"
  )
  result <- .format_event_line(event)
  expect_true(grepl("^- A quiet moment", result))
  expect_false(grepl("\\(\\)", result))
  expect_true(grepl("— \\[\\[Tavern\\]\\]", result))
})

# --- .build_summary() ---------------------------------------------------------

test_that(".build_summary uses only first 3 events", {
  events <- lapply(1:5, function(i) list(description = paste("Event", i)))
  result <- .build_summary(events)
  expect_true(grepl("Event 1", result))
  expect_true(grepl("Event 3", result))
  expect_false(grepl("Event 4", result))
})

test_that(".build_summary returns empty string for 0 events", {
  expect_equal(.build_summary(list()), "")
})

test_that(".build_summary returns empty string for NULL events", {
  expect_equal(.build_summary(NULL), "")
})

test_that(".build_summary adds trailing period if missing", {
  events <- list(list(description = "Something happened"))
  result <- .build_summary(events)
  expect_true(grepl("\\.$", result))
})

test_that(".build_summary does not double-add period", {
  events <- list(list(description = "Already has a period."))
  result <- .build_summary(events)
  expect_false(grepl("\\.\\.$", result))
})

test_that(".build_summary joins with period-space", {
  events <- list(
    list(description = "First event"),
    list(description = "Second event")
  )
  result <- .build_summary(events)
  expect_true(grepl("First event\\. Second event", result))
})

# --- assemble_session_note() --------------------------------------------------

test_that("assemble_session_note with full facts has correct structure", {
  facts <- list(
    events = list(
      list(description = "The infection spread",
           characters_involved = c("Room", "Captain"),
           location = "Ship")
    ),
    npcs = list(
      list(name = "War Saint",
           actions = c("Cast Wish to cure infection"),
           quotes = c("This will hurt."))
    ),
    locations = list(
      list(name = "Giff Flotilla", description = "An astral fortress city")
    ),
    threads = list(
      list(description = "Shadow entity appeared twice",
           related_characters = c("Lumi"))
    )
  )

  result <- assemble_session_note("s02e34", facts)

  expect_true(grepl("^---\n", result))
  expect_true(grepl("tags: \\[session\\]", result))
  expect_true(grepl("episode: s02e34", result))
  expect_true(grepl("review_required: false", result))
  expect_true(grepl("## Summary", result))
  expect_true(grepl("## Key Events", result))
  expect_true(grepl("## NPCs Present", result))
  expect_true(grepl("## Locations", result))
  expect_true(grepl("## Items / Artifacts", result))
  expect_true(grepl("## Open Threads", result))
  expect_true(grepl("## GM Notes", result))
})

test_that("assemble_session_note with empty events sets review_required: true", {
  facts <- list(events = list(), npcs = list(), locations = list(), threads = list())
  result <- assemble_session_note("s01e01", facts)
  expect_true(grepl("review_required: true", result))
})

test_that("assemble_session_note with no NPCs shows dash placeholder", {
  facts <- list(
    events = list(list(description = "Something", characters_involved = c(), location = NA)),
    npcs = list(),
    locations = list(),
    threads = list()
  )
  result <- assemble_session_note("s01e01", facts)
  lines <- strsplit(result, "\n")[[1]]
  npc_idx <- which(lines == "## NPCs Present")
  expect_equal(lines[npc_idx + 1], "-")
})

test_that("assemble_session_note with no locations shows dash placeholder", {
  facts <- list(
    events = list(list(description = "Something", characters_involved = c(), location = NA)),
    npcs = list(),
    locations = list(),
    threads = list()
  )
  result <- assemble_session_note("s01e01", facts)
  lines <- strsplit(result, "\n")[[1]]
  loc_idx <- which(lines == "## Locations")
  expect_equal(lines[loc_idx + 1], "-")
})

test_that("assemble_session_note episode field matches input", {
  facts <- list(events = list(), npcs = list(), locations = list(), threads = list())
  result <- assemble_session_note("s03e12", facts)
  expect_true(grepl("episode: s03e12", result))
})

test_that("assemble_session_note output is valid markdown with frontmatter", {
  facts <- list(events = list(), npcs = list(), locations = list(), threads = list())
  result <- assemble_session_note("s01e01", facts)
  expect_true(startsWith(result, "---\n"))
  dashes <- gregexpr("---", result)[[1]]
  expect_true(length(dashes) >= 2)
})

test_that("assemble_session_note wikifies NPC names", {
  facts <- list(
    events = list(),
    npcs = list(list(name = "War Saint", actions = c("Fought"), quotes = c())),
    locations = list(),
    threads = list()
  )
  result <- assemble_session_note("s01e01", facts)
  expect_true(grepl("\\[\\[War Saint\\]\\]", result))
})

test_that("assemble_session_note wikifies characters in events", {
  facts <- list(
    events = list(list(description = "Battle", characters_involved = c("Room"), location = NA)),
    npcs = list(),
    locations = list(),
    threads = list()
  )
  result <- assemble_session_note("s01e01", facts)
  expect_true(grepl("\\[\\[Room\\]\\]", result))
})

test_that("assemble_session_note wikifies thread related characters", {
  facts <- list(
    events = list(),
    npcs = list(),
    locations = list(),
    threads = list(list(description = "Mystery", related_characters = c("Lumi")))
  )
  result <- assemble_session_note("s01e01", facts)
  expect_true(grepl("\\[\\[Lumi\\]\\]", result))
})

# --- assemble_entity_note() for NPC ------------------------------------------

test_that("assemble_entity_note for NPC has correct frontmatter", {
  facts <- list(name = "War Saint", actions = c("Cast Wish"), quotes = c("This will hurt."))
  result <- assemble_entity_note("War Saint", "npc", facts, source_episode_ids = c("s02e34"))

  expect_true(grepl("tags: \\[npc\\]", result))
  expect_true(grepl("name: War Saint", result))
  expect_true(grepl("aliases: \\[\\]", result))
  expect_true(grepl("status: unknown", result))
})

test_that("assemble_entity_note for NPC includes quotes as blockquotes", {
  facts <- list(
    name = "War Saint",
    actions = c("Cast Wish"),
    quotes = c("This will hurt.", "Brace yourself.")
  )
  result <- assemble_entity_note("War Saint", "npc", facts, source_episode_ids = c("s02e34"))

  expect_true(grepl("> This will hurt\\.", result))
  expect_true(grepl("> Brace yourself\\.", result))
})

test_that("assemble_entity_note for NPC includes session appearances", {
  facts <- list(name = "War Saint", actions = c("Fought"), quotes = c())
  result <- assemble_entity_note("War Saint", "npc", facts,
                                 source_episode_ids = c("s02e34", "s02e35"))
  expect_true(grepl("\\[\\[s02e34\\]\\]", result))
  expect_true(grepl("\\[\\[s02e35\\]\\]", result))
})

test_that("assemble_entity_note for NPC with no actions shows dash", {
  facts <- list(name = "Quiet NPC", actions = character(0), quotes = character(0))
  result <- assemble_entity_note("Quiet NPC", "npc", facts)
  lines <- strsplit(result, "\n")[[1]]
  overview_idx <- which(lines == "## Overview")
  expect_equal(lines[overview_idx + 1], "-")
})

test_that("assemble_entity_note for NPC with no quotes shows dash", {
  facts <- list(name = "Silent NPC", actions = c("Stood guard"), quotes = character(0))
  result <- assemble_entity_note("Silent NPC", "npc", facts)
  lines <- strsplit(result, "\n")[[1]]
  quotes_idx <- which(lines == "## Quotes")
  expect_equal(lines[quotes_idx + 1], "-")
})

# --- assemble_entity_note() for location -------------------------------------

test_that("assemble_entity_note for location has correct frontmatter", {
  facts <- list(name = "Giff Flotilla", description = "An astral fortress city")
  result <- assemble_entity_note("Giff Flotilla", "location", facts,
                                 source_episode_ids = c("s02e34"))

  expect_true(grepl("tags: \\[location\\]", result))
  expect_true(grepl("name: Giff Flotilla", result))
  expect_true(grepl("type: unknown", result))
  expect_true(grepl("region: unknown", result))
})

test_that("assemble_entity_note for location includes description", {
  facts <- list(name = "Giff Flotilla", description = "An astral fortress city")
  result <- assemble_entity_note("Giff Flotilla", "location", facts)
  expect_true(grepl("An astral fortress city", result))
})

test_that("assemble_entity_note for location includes session appearances", {
  facts <- list(name = "Giff Flotilla", description = "A city")
  result <- assemble_entity_note("Giff Flotilla", "location", facts,
                                 source_episode_ids = c("s02e34"))
  expect_true(grepl("\\[\\[s02e34\\]\\]", result))
})

# --- assemble_entity_note() for faction --------------------------------------

test_that("assemble_entity_note for faction has correct frontmatter", {
  facts <- list(name = "The Giff")
  result <- assemble_entity_note("The Giff", "faction", facts,
                                 source_episode_ids = c("s02e34"))

  expect_true(grepl("tags: \\[faction\\]", result))
  expect_true(grepl("name: The Giff", result))
  expect_true(grepl("disposition_to_party: unknown", result))
})

test_that("assemble_entity_note for faction has correct sections", {
  facts <- list(name = "The Giff")
  result <- assemble_entity_note("The Giff", "faction", facts)

  expect_true(grepl("## Overview", result))
  expect_true(grepl("## Key Members", result))
  expect_true(grepl("## Goals", result))
  expect_true(grepl("## Session Appearances", result))
})

# --- assemble_entity_note() with no source_episode_ids -----------------------

test_that("assemble_entity_note with NULL episodes shows dash for appearances", {
  facts <- list(name = "Nobody", actions = c("Lurked"), quotes = c())
  result <- assemble_entity_note("Nobody", "npc", facts, source_episode_ids = NULL)
  lines <- strsplit(result, "\n")[[1]]
  app_idx <- which(lines == "## Session Appearances")
  expect_equal(lines[app_idx + 1], "-")
})

# --- Unknown entity_type errors ----------------------------------------------

test_that("assemble_entity_note errors on unknown entity_type", {
  expect_error(
    assemble_entity_note("X", "spell", list()),
    regexp = "Unknown entity_type"
  )
})

# --- Frontmatter validity ----------------------------------------------------

test_that("session note starts with --- and has matching closing ---", {
  facts <- list(
    events = list(list(description = "Battle", characters_involved = c(), location = NA)),
    npcs = list(), locations = list(), threads = list()
  )
  result <- assemble_session_note("s01e01", facts)
  lines <- strsplit(result, "\n")[[1]]
  expect_equal(lines[1], "---")
  closing <- which(lines == "---")
  expect_true(length(closing) >= 2)
})

test_that("entity note starts with --- and has matching closing ---", {
  facts <- list(name = "Test", actions = c(), quotes = c())
  result <- assemble_entity_note("Test", "npc", facts)
  lines <- strsplit(result, "\n")[[1]]
  expect_equal(lines[1], "---")
  closing <- which(lines == "---")
  expect_true(length(closing) >= 2)
})
