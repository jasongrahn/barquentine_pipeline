library(testthat)
source(test_path("../../R/postprocess_shared.R"))
source(test_path("../../R/agentic_postprocess.R"))

# Fixture: minimal protected_entities.csv with a dm_voice row, a pc row, and a
# plain npc row. Written per-test via withr::local_tempfile so tests don't
# depend on the real config.
write_protected_fixture <- function(rows) {
  f <- withr::local_tempfile(fileext = ".csv", .local_envir = parent.frame())
  readr::write_csv(rows, f)
  f
}

# --- filter_dm_voice_npcs -----------------------------------------------------

test_that("filter_dm_voice_npcs drops rows matching a dm_voice slug by name", {
  npcs <- data.frame(
    name = c("The Admiral", "Ted", "the admiral"),
    description = c("DM persona", "ship's cook", "DM persona again"),
    stringsAsFactors = FALSE
  )
  out <- filter_dm_voice_npcs(npcs, dm_voice_slugs = "the_admiral")
  expect_equal(nrow(out), 1L)
  expect_equal(out$name, "Ted")
})

test_that("filter_dm_voice_npcs is a no-op when dm_voice_slugs is empty", {
  npcs <- data.frame(name = "The Admiral", description = "x",
                     stringsAsFactors = FALSE)
  expect_equal(nrow(filter_dm_voice_npcs(npcs, character(0))), 1L)
})

# --- load_agentic_protected_slugs (dm_voice exclusion) ------------------------

test_that("load_agentic_protected_slugs excludes dm_voice rows from bypass set", {
  rows <- tibble::tibble(
    slug          = c("ted", "the_admiral", "basil"),
    canonical_name = c("Ted", "The Admiral", "Basil"),
    entity_type   = c("npc", "dm_voice", "pc"),
    played_by     = c(NA, NA, "David"),
    exclude_from_spotting = c(FALSE, FALSE, FALSE)
  )
  pf <- write_protected_fixture(rows)
  af <- withr::local_tempfile(fileext = ".csv")
  readr::write_csv(
    tibble::tibble(alias = character(0),
                   canonical_slug = character(0),
                   display_as = character(0)),
    af)

  out <- load_agentic_protected_slugs(pf, af)
  expect_true("ted" %in% out)
  expect_true("basil" %in% out)
  expect_false("the_admiral" %in% out)
})

test_that("load_dm_voice_slugs returns only dm_voice rows", {
  rows <- tibble::tibble(
    slug          = c("ted", "the_admiral"),
    canonical_name = c("Ted", "The Admiral"),
    entity_type   = c("npc", "dm_voice"),
    played_by     = c(NA, NA),
    exclude_from_spotting = c(FALSE, FALSE)
  )
  pf <- write_protected_fixture(rows)
  expect_equal(load_dm_voice_slugs(pf), "the_admiral")
})

# --- filter_low_signal_npcs (name patterns) -----------------------------------

test_that("filter_low_signal_npcs drops 'unnamed X' rows by name", {
  npcs <- data.frame(
    name = c("unnamed adjutant", "unnamed Astra Elf", "Ted", "Cletus"),
    description = c("a soldier", "a tall elf", "ship's cook", "the bosun"),
    stringsAsFactors = FALSE
  )
  out <- filter_low_signal_npcs(npcs, protected_slugs = character(0))
  expect_equal(sort(out$name), c("Cletus", "Ted"))
})

test_that("filter_low_signal_npcs honors protected_slugs even on 'unnamed' name", {
  # The skill prompt strips "unnamed " when building a slug — "unnamed Ted"
  # should be kept if "ted" is in the protected set.
  npcs <- data.frame(
    name = c("unnamed Ted", "unnamed adjutant"),
    description = c("ship's cook", "a soldier"),
    stringsAsFactors = FALSE
  )
  out <- filter_low_signal_npcs(npcs, protected_slugs = "ted")
  expect_equal(out$name, "unnamed Ted")
})

test_that("filter_low_signal_npcs still drops description-only DM-voice noise", {
  npcs <- data.frame(
    name = c("Sergeant Maple", "Cletus"),
    description = c("DM, narrates the scene", "the bosun"),
    stringsAsFactors = FALSE
  )
  out <- filter_low_signal_npcs(npcs, protected_slugs = character(0))
  expect_equal(out$name, "Cletus")
})

# --- collapse_near_match_locations (edit distance) ----------------------------

test_that("collapse_near_match_locations merges astro_sea + astral_sea", {
  locs <- data.frame(
    name = c("Astro Sea", "Astral Sea"),
    description = c("a vast cosmic ocean",
                    "a vast cosmic ocean of stars and silver mist"),
    line = c(10L, 50L),
    stringsAsFactors = FALSE
  )
  out <- collapse_near_match_locations(locs)
  expect_equal(nrow(out), 1L)
  expect_equal(out$name, "Astral Sea")  # longer name wins
  expect_true(grepl("stars and silver mist", out$description))
})

test_that("collapse_near_match_locations does NOT merge short near-typos (ship/shop)", {
  locs <- data.frame(
    name = c("Ship", "Shop"),
    description = c("a ship", "a shop"),
    line = c(1L, 2L),
    stringsAsFactors = FALSE
  )
  out <- collapse_near_match_locations(locs)
  expect_equal(nrow(out), 2L)
})

test_that("collapse_near_match_locations still collapses 'the X' vs 'X'", {
  locs <- data.frame(
    name = c("The Brig", "Brig"),
    description = c("a cell", "a small cell"),
    line = c(10L, 20L),
    stringsAsFactors = FALSE
  )
  out <- collapse_near_match_locations(locs)
  expect_equal(nrow(out), 1L)
})

test_that("collapse_near_match_locations keeps unrelated locations separate", {
  locs <- data.frame(
    name = c("Astral Sea", "Briarwood", "Goblin Camp"),
    description = c("ocean", "forest village", "encampment"),
    line = c(1L, 2L, 3L),
    stringsAsFactors = FALSE
  )
  out <- collapse_near_match_locations(locs)
  expect_equal(nrow(out), 3L)
})
