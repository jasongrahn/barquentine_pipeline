library(testthat)
source(test_path("../../config.R"))
source(test_path("../../R/agentic_extract.R"))
source(test_path("../../R/agentic_entity_writer.R"))

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

make_entity_record <- function(note_type = "npc", entity_id = "attorrnash") {
  list(
    entity_id          = entity_id,
    entity_name        = "Attorrnash",
    note_type          = note_type,
    source_passages    = c("Attorrnash is a seasoned sailor.", "He works with the crew."),
    source_episode_ids = c("s02e34")
  )
}

make_pc_extraction <- function() {
  list(
    aliases = list("The Captain"),
    bio = list(value = "A seasoned sailor.", line = 1L),
    description = list(value = "Tall and weathered.", line = 1L),
    exhibited_personality = list(value = "Stoic but caring.", line = 2L),
    role_in_story = list(value = "Ship captain of the crew.", line = 1L),
    relatives = list(),
    affiliations = list(list(name = "The Crew", line = 1L)),
    alignment = list(value = "Neutral Good", line = 1L)
  )
}

make_npc_extraction <- function() {
  list(
    aliases = list(),
    description = list(value = "A mysterious merchant.", line = 1L),
    role_in_story = list(value = "Provides quest hooks.", line = 2L),
    exhibited_personality = list(value = "Friendly but evasive.", line = 1L),
    affiliations = list(list(name = "Merchant Guild", line = 2L))
  )
}

make_location_extraction <- function() {
  list(
    description = list(value = "A bustling port city.", line = 1L),
    region = list(value = "The Southern Coast", line = 1L),
    notable_features = list(list(feature = "Grand lighthouse", line = 2L)),
    events_witnessed = list(),
    connections = list("Nearby town of Redbrook")
  )
}

make_faction_extraction <- function() {
  list(
    description = list(value = "A secretive order.", line = 1L),
    goals = list(list(value = "Protect ancient relics", line = 2L)),
    known_members = list(list(name = "High Priest Valdus", line = 1L)),
    allies = list("The Mages Council"),
    enemies = list("The Shadow Brotherhood")
  )
}

# ---------------------------------------------------------------------------
# NULL extraction
# ---------------------------------------------------------------------------

test_that("NULL extraction returns fallback stub with slug and failure notice", {
  rec <- make_entity_record("npc")
  md  <- assemble_entity_markdown(NULL, rec)
  expect_true(grepl(rec$entity_id, md))
  expect_true(grepl("extraction failed", md))
})

test_that("NULL extraction stub contains review_required frontmatter", {
  md <- assemble_entity_markdown(NULL, make_entity_record("npc"))
  expect_true(grepl("review_required: true", md))
})

# ---------------------------------------------------------------------------
# NPC note type
# ---------------------------------------------------------------------------

test_that("npc note_type returns non-empty markdown", {
  md <- assemble_entity_markdown(make_npc_extraction(), make_entity_record("npc"))
  expect_true(nzchar(md))
  expect_true(grepl("---", md))
  expect_true(grepl("slug: attorrnash", md))
  expect_true(grepl("tags: \\[npc\\]", md))
  expect_true(grepl("review_required: true", md))
})

test_that("npc markdown contains Overview section", {
  md <- assemble_entity_markdown(make_npc_extraction(), make_entity_record("npc"))
  expect_true(grepl("## Overview", md))
})

test_that("npc markdown contains Affiliations section when affiliations present", {
  md <- assemble_entity_markdown(make_npc_extraction(), make_entity_record("npc"))
  expect_true(grepl("## Affiliations", md))
  expect_true(grepl("Merchant Guild", md))
})

# ---------------------------------------------------------------------------
# PC note type
# ---------------------------------------------------------------------------

test_that("pc note_type returns markdown with pc tag", {
  md <- assemble_entity_markdown(make_pc_extraction(), make_entity_record("pc"))
  expect_true(nzchar(md))
  expect_true(grepl("tags: \\[pc\\]", md))
  expect_true(grepl("review_required: true", md))
})

test_that("pc markdown contains Overview section", {
  md <- assemble_entity_markdown(make_pc_extraction(), make_entity_record("pc"))
  expect_true(grepl("## Overview", md))
})

test_that("pc markdown contains Personality section", {
  md <- assemble_entity_markdown(make_pc_extraction(), make_entity_record("pc"))
  expect_true(grepl("## Personality", md))
})

test_that("pc markdown lists aliases in frontmatter", {
  md <- assemble_entity_markdown(make_pc_extraction(), make_entity_record("pc"))
  expect_true(grepl("The Captain", md))
})

# ---------------------------------------------------------------------------
# Location note type
# ---------------------------------------------------------------------------

test_that("location note_type returns markdown with location tag", {
  md <- assemble_entity_markdown(make_location_extraction(), make_entity_record("location"))
  expect_true(nzchar(md))
  expect_true(grepl("tags: \\[location\\]", md))
  expect_true(grepl("review_required: true", md))
})

test_that("location markdown contains Description section", {
  md <- assemble_entity_markdown(make_location_extraction(), make_entity_record("location"))
  expect_true(grepl("## Description", md))
})

test_that("location markdown contains Notable Features section", {
  md <- assemble_entity_markdown(make_location_extraction(), make_entity_record("location"))
  expect_true(grepl("## Notable Features", md))
  expect_true(grepl("Grand lighthouse", md))
})

test_that("location markdown omits Events section when events_witnessed is empty", {
  md <- assemble_entity_markdown(make_location_extraction(), make_entity_record("location"))
  expect_false(grepl("## Events", md))
})

# ---------------------------------------------------------------------------
# Faction note type
# ---------------------------------------------------------------------------

test_that("faction note_type returns markdown with faction tag", {
  md <- assemble_entity_markdown(make_faction_extraction(), make_entity_record("faction"))
  expect_true(nzchar(md))
  expect_true(grepl("tags: \\[faction\\]", md))
  expect_true(grepl("review_required: true", md))
})

test_that("faction markdown contains Goals section", {
  md <- assemble_entity_markdown(make_faction_extraction(), make_entity_record("faction"))
  expect_true(grepl("## Goals", md))
  expect_true(grepl("Protect ancient relics", md))
})

test_that("faction markdown contains Known Members section", {
  md <- assemble_entity_markdown(make_faction_extraction(), make_entity_record("faction"))
  expect_true(grepl("## Known Members", md))
  expect_true(grepl("High Priest Valdus", md))
})

test_that("faction markdown contains Allies and Enemies sections", {
  md <- assemble_entity_markdown(make_faction_extraction(), make_entity_record("faction"))
  expect_true(grepl("## Allies", md))
  expect_true(grepl("## Enemies", md))
  expect_true(grepl("The Mages Council", md))
  expect_true(grepl("The Shadow Brotherhood", md))
})

# ---------------------------------------------------------------------------
# Unknown note_type
# ---------------------------------------------------------------------------

test_that("unknown note_type throws an error", {
  rec <- make_entity_record("monster")
  expect_error(assemble_entity_markdown(make_npc_extraction(), rec))
})

# ---------------------------------------------------------------------------
# Empty arrays omit sections
# ---------------------------------------------------------------------------

test_that("empty affiliations omits Affiliations section in npc", {
  ext <- make_npc_extraction()
  ext$affiliations <- list()
  md  <- assemble_entity_markdown(ext, make_entity_record("npc"))
  expect_false(grepl("## Affiliations", md))
})

test_that("empty goals omits Goals section in faction", {
  ext <- make_faction_extraction()
  ext$goals <- list()
  md  <- assemble_entity_markdown(ext, make_entity_record("faction"))
  expect_false(grepl("## Goals", md))
})

test_that("empty notable_features omits Notable Features section in location", {
  ext <- make_location_extraction()
  ext$notable_features <- list()
  md  <- assemble_entity_markdown(ext, make_entity_record("location"))
  expect_false(grepl("## Notable Features", md))
})

# ---------------------------------------------------------------------------
# YAML frontmatter fields
# ---------------------------------------------------------------------------

test_that("frontmatter contains source episode ids", {
  md <- assemble_entity_markdown(make_npc_extraction(), make_entity_record("npc"))
  expect_true(grepl("s02e34", md))
})

test_that("frontmatter has empty aliases list when no aliases provided", {
  ext <- make_npc_extraction()
  md  <- assemble_entity_markdown(ext, make_entity_record("npc"))
  expect_true(grepl("aliases: \\[\\]", md))
})

# ---------------------------------------------------------------------------
# PC played_by lookup
# ---------------------------------------------------------------------------

test_that("pc with missing protected_entities.csv has no played_by frontmatter line", {
  rec <- make_entity_record("pc")
  old <- PROTECTED_ENTITIES_PATH
  assign("PROTECTED_ENTITIES_PATH", "/nonexistent/path.csv", envir = globalenv())
  on.exit(assign("PROTECTED_ENTITIES_PATH", old, envir = globalenv()), add = TRUE)
  md <- assemble_entity_markdown(make_pc_extraction(), rec)
  expect_false(grepl("played_by:", md))
})
