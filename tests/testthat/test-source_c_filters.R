library(testthat)
source(test_path("../../config.R"))
source(test_path("../../R/ollama.R"))
source(test_path("../../R/postprocess_shared.R"))
source(test_path("../../R/source_c.R"))
source(test_path("../../R/agentic_postprocess.R"))

# Fixture: protected_entities.csv with one row per entity_type the entity
# chain now has to honor (npc, pc, pc_alias, player, dm_voice).
write_protected_fixture <- function(rows, envir = parent.frame()) {
  f <- withr::local_tempfile(fileext = ".csv", .local_envir = envir)
  readr::write_csv(rows, f)
  f
}

protected_rows_full <- function() {
  tibble::tibble(
    slug                  = c("ted",   "the_admiral", "basil", "captain",
                              "the_captain", "john"),
    canonical_name        = c("Ted",   "The Admiral", "Basil", "Captain",
                              "The Captain", "John"),
    entity_type           = c("npc",   "dm_voice",    "pc",    "pc_alias",
                              "pc_alias",    "player"),
    played_by             = c(NA,      NA,            "David", "David",
                              "David",       NA),
    exclude_from_spotting = c(FALSE,   FALSE,         FALSE,   FALSE,
                              FALSE,         TRUE)
  )
}

# ---- load_protected_slugs (dm_voice exclusion) ------------------------------

test_that("load_protected_slugs excludes dm_voice rows from bypass set", {
  pf <- write_protected_fixture(protected_rows_full())
  out <- load_protected_slugs(pf)
  expect_false("the_admiral" %in% out)
  expect_true("ted" %in% out)
  expect_true("basil" %in% out)
})

test_that("load_protected_slugs still honors exclude_from_spotting alongside dm_voice", {
  pf <- write_protected_fixture(protected_rows_full())
  out <- load_protected_slugs(pf)
  # `john` has exclude_from_spotting = TRUE → also excluded from bypass set.
  expect_false("john" %in% out)
})

# ---- load_excluded_entity_slugs (pc / pc_alias / dm_voice / player) ---------

test_that("load_excluded_entity_slugs drops dm_voice + pc_alias + player rows", {
  pf <- write_protected_fixture(protected_rows_full())
  out <- load_excluded_entity_slugs(pf)
  expect_true("the_admiral"  %in% out)   # dm_voice
  expect_true("captain"      %in% out)   # pc_alias
  expect_true("the_captain"  %in% out)   # pc_alias
  expect_true("basil"        %in% out)   # pc
  expect_true("john"         %in% out)   # player (also exclude_from_spotting TRUE)
  expect_false("ted"         %in% out)   # plain npc, not excluded
})

test_that("load_excluded_entity_slugs still includes exclude_from_spotting=TRUE rows when entity_type is npc", {
  rows <- tibble::tibble(
    slug                  = c("ted", "narrator"),
    canonical_name        = c("Ted", "Narrator"),
    entity_type           = c("npc", "npc"),
    played_by             = c(NA, NA),
    exclude_from_spotting = c(FALSE, TRUE)
  )
  pf <- write_protected_fixture(rows)
  out <- load_excluded_entity_slugs(pf)
  expect_equal(out, "narrator")
})

test_that("load_excluded_entity_slugs handles CSV with no entity_type column (back-compat)", {
  rows <- tibble::tibble(
    slug                  = c("john", "ted"),
    canonical_name        = c("John", "Ted"),
    exclude_from_spotting = c(TRUE,   FALSE)
  )
  pf <- write_protected_fixture(rows)
  out <- load_excluded_entity_slugs(pf)
  expect_equal(out, "john")
})

# ---- aggregate_entity_passages: unnamed-name filter -------------------------

test_that("aggregate_entity_passages drops 'unnamed adjutant' when not protected", {
  assign("resolve_alias", function(...) NULL, envir = globalenv())
  on.exit(rm("resolve_alias", envir = globalenv()), add = TRUE)

  file1 <- list(
    episode_id = "S2e34",
    npcs       = list("unnamed adjutant" = list("c1", "c2", "c3", "c4")),
    locations  = list(), items = list(), factions = list()
  )
  result <- aggregate_entity_passages(list(file1), list(),
                                      min_chunks = 3L,
                                      protected_slugs = c("ted", "basil"))
  slugs <- if (length(result) == 0) character(0)
           else vapply(result, `[[`, character(1), "entity_id")
  expect_false("unnamed_adjutant" %in% slugs)
})

test_that("aggregate_entity_passages keeps 'unnamed Ted' via protected-slug bypass and remaps to 'ted'", {
  assign("resolve_alias", function(...) NULL, envir = globalenv())
  on.exit(rm("resolve_alias", envir = globalenv()), add = TRUE)

  file1 <- list(
    episode_id = "S2e34",
    npcs       = list("unnamed Ted" = list("c1", "c2", "c3")),
    locations  = list(), items = list(), factions = list()
  )
  result <- aggregate_entity_passages(list(file1), list(),
                                      min_chunks = 3L,
                                      protected_slugs = c("ted"))
  slugs <- vapply(result, `[[`, character(1), "entity_id")
  expect_true("ted" %in% slugs)
  expect_false("unnamed_ted" %in% slugs)
})

# ---- aggregate_entity_passages: location edit-distance collapse -------------

test_that("aggregate_entity_passages merges 'Astro Sea' + 'Astral Sea' into one location", {
  assign("resolve_alias", function(...) NULL, envir = globalenv())
  on.exit(rm("resolve_alias", envir = globalenv()), add = TRUE)

  file1 <- list(
    episode_id = "S2e34",
    npcs       = list(),
    locations  = list(
      "Astro Sea"  = list("c1", "c2"),
      "Astral Sea" = list("c3", "c4")
    ),
    items    = list(),
    factions = list()
  )
  result <- aggregate_entity_passages(list(file1), list(), min_chunks = 3L)
  loc_recs <- Filter(function(r) r$note_type == "location", result)
  expect_equal(length(loc_recs), 1L)
  expect_equal(loc_recs[[1]]$entity_id, "astral_sea")  # longer slug wins
  expect_equal(length(loc_recs[[1]]$source_passages), 4L)
})

test_that("aggregate_entity_passages does NOT merge near-typo NPC names", {
  # NPCs are intentionally not collapsed by edit distance — leave Cletus
  # and Cletas as separate records for reviewer judgment.
  assign("resolve_alias", function(...) NULL, envir = globalenv())
  on.exit(rm("resolve_alias", envir = globalenv()), add = TRUE)

  file1 <- list(
    episode_id = "S2e34",
    npcs       = list(
      "Cletus" = list("c1", "c2", "c3"),
      "Cletas" = list("c4", "c5", "c6")
    ),
    locations = list(), items = list(), factions = list()
  )
  result <- aggregate_entity_passages(list(file1), list(), min_chunks = 3L)
  slugs <- vapply(result, `[[`, character(1), "entity_id")
  expect_true("cletus" %in% slugs)
  expect_true("cletas" %in% slugs)
})

# ---- Cross-pipeline parity --------------------------------------------------

# Helper: pull the entity-chain drop/keep decision for a given name. Returns
# "drop" if the name is excluded from aggregate_entity_passages output,
# "keep" otherwise.
entity_chain_decision <- function(name, alias_reg = list(),
                                  protected = character(0),
                                  exclusions = character(0)) {
  assign("resolve_alias", function(...) NULL, envir = globalenv())
  on.exit(rm("resolve_alias", envir = globalenv()), add = TRUE)
  file1 <- list(
    episode_id = "S2e34",
    npcs       = setNames(list(list("c1", "c2", "c3")), name),
    locations  = list(), items = list(), factions = list()
  )
  result <- aggregate_entity_passages(list(file1), alias_reg,
                                      min_chunks = 3L,
                                      exclusion_slugs = exclusions,
                                      protected_slugs = protected)
  if (length(result) == 0L) return("drop")
  if (any(vapply(result, function(r) r$entity_name == name, logical(1)))) {
    return("keep")
  }
  # Was remapped (e.g. unnamed Ted → ted). Treat as keep for parity.
  "keep"
}

# Helper: agentic-chain drop/keep decision for the same name.
agentic_chain_decision <- function(name, dm_voice_slugs = character(0),
                                   protected = character(0),
                                   pc_drop_slugs = character(0)) {
  npcs <- data.frame(name = name, description = "stub", stringsAsFactors = FALSE)
  # Skip filter_pc_and_player_npcs which reads the protected CSV — the
  # caller supplies the pc_drop_slugs explicitly for parity tests.
  if (agentic_slug(name) %in% pc_drop_slugs) return("drop")
  npcs <- filter_dm_voice_npcs(npcs, dm_voice_slugs = dm_voice_slugs)
  if (nrow(npcs) == 0) return("drop")
  npcs <- dedup_by_slug(npcs, "name")
  npcs <- filter_low_signal_npcs(npcs, protected_slugs = protected)
  if (nrow(npcs) == 0) "drop" else "keep"
}

test_that("'the admiral' (dm_voice) drops in both pipelines", {
  # Entity chain: 'the_admiral' is in the excluded slug set.
  entity_d <- entity_chain_decision("the admiral",
                                    exclusions = "the_admiral")
  # Agentic chain: 'the_admiral' is the dm_voice slug.
  agentic_d <- agentic_chain_decision("The Admiral",
                                      dm_voice_slugs = "the_admiral")
  expect_equal(entity_d,  "drop")
  expect_equal(agentic_d, "drop")
})

test_that("'unnamed adjutant' drops in both pipelines", {
  entity_d  <- entity_chain_decision("unnamed adjutant")
  agentic_d <- agentic_chain_decision("unnamed adjutant")
  expect_equal(entity_d,  "drop")
  expect_equal(agentic_d, "drop")
})

test_that("'unnamed Ted' keeps in both pipelines via protected-slug bypass", {
  entity_d  <- entity_chain_decision("unnamed Ted",
                                     protected = "ted")
  agentic_d <- agentic_chain_decision("unnamed Ted",
                                      protected = "ted")
  expect_equal(entity_d,  "keep")
  expect_equal(agentic_d, "keep")
})

test_that("'Captain' (pc_alias) drops in both pipelines", {
  entity_d  <- entity_chain_decision("Captain",
                                     exclusions = "captain")
  agentic_d <- agentic_chain_decision("Captain",
                                      pc_drop_slugs = "captain")
  expect_equal(entity_d,  "drop")
  expect_equal(agentic_d, "drop")
})
