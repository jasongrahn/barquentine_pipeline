library(testthat)
library(withr)

source(test_path("../../config.R"))
source(test_path("../../R/wikilinks.R"))

# --- Helpers -----------------------------------------------------------------

write_md_note <- function(dir, filename, frontmatter_lines) {
  path <- file.path(dir, filename)
  body <- paste0(
    "---\n",
    paste(frontmatter_lines, collapse = "\n"), "\n",
    "---\n\n## Overview\n"
  )
  writeLines(body, path)
  path
}

# --- make_wikilink() ---------------------------------------------------------

test_that("make_wikilink returns [[slug]] when display is NULL", {
  expect_equal(make_wikilink("Attorrnash"), "[[Attorrnash]]")
})

test_that("make_wikilink returns [[slug|display]] when display is provided", {
  expect_equal(make_wikilink("Basil", display = "the Captain"), "[[Basil|the Captain]]")
})

test_that("make_wikilink handles slugs with underscores", {
  expect_equal(make_wikilink("Brassam_Volund"), "[[Brassam_Volund]]")
})

# --- resolve_alias() ---------------------------------------------------------

test_that("resolve_alias returns the registry entry for a known name", {
  registry <- list(
    "Attorrnash" = list(slug = "Attorrnash", display = NULL),
    "Attornash"  = list(slug = "Attorrnash", display = NULL)
  )
  result <- resolve_alias("Attornash", registry)
  expect_equal(result$slug, "Attorrnash")
  expect_null(result$display)
})

test_that("resolve_alias returns NULL for an unknown name", {
  registry <- list("Attorrnash" = list(slug = "Attorrnash", display = NULL))
  expect_null(resolve_alias("Unknown Entity", registry))
})

test_that("resolve_alias returns display value when present", {
  registry <- list("the Captain" = list(slug = "Basil", display = "the Captain"))
  result <- resolve_alias("the Captain", registry)
  expect_equal(result$slug, "Basil")
  expect_equal(result$display, "the Captain")
})

# --- resolve_wikilink() -------------------------------------------------------

test_that("resolve_wikilink returns correct wikilink for a known name", {
  registry <- list("Attorrnash" = list(slug = "Attorrnash", display = NULL))
  expect_equal(resolve_wikilink("Attorrnash", registry), "[[Attorrnash]]")
})

test_that("resolve_wikilink uses display text when present", {
  registry <- list("the Captain" = list(slug = "Basil", display = "the Captain"))
  expect_equal(resolve_wikilink("the Captain", registry), "[[Basil|the Captain]]")
})

test_that("resolve_wikilink returns NULL for an unknown name", {
  registry <- list("Attorrnash" = list(slug = "Attorrnash", display = NULL))
  expect_null(resolve_wikilink("Unknown Entity", registry))
})

# --- build_alias_registry() --------------------------------------------------

test_that("build_alias_registry returns empty list when vault has no pcs/ or npcs/", {
  tmp      <- local_tempdir()
  registry <- build_alias_registry(vault_path = tmp)
  expect_equal(length(registry), 0)
  expect_type(registry, "list")
})

test_that("build_alias_registry registers canonical name from a PC note", {
  tmp <- local_tempdir()
  dir.create(file.path(tmp, "pcs"))
  write_md_note(file.path(tmp, "pcs"), "Basil.md", c(
    "tags: [pc]",
    "name: Basil",
    "aliases: [Basil, the Captain, Nameless Captain]",
    "display_as: the Captain"
  ))
  registry <- build_alias_registry(vault_path = tmp)
  expect_true("Basil" %in% names(registry))
  expect_equal(registry[["Basil"]]$slug, "Basil")
})

test_that("build_alias_registry registers alias variants from a PC note", {
  tmp <- local_tempdir()
  dir.create(file.path(tmp, "pcs"))
  write_md_note(file.path(tmp, "pcs"), "Basil.md", c(
    "tags: [pc]",
    "name: Basil",
    "aliases: [Basil, the Captain, Nameless Captain]",
    "display_as: the Captain"
  ))
  registry <- build_alias_registry(vault_path = tmp)
  expect_true("the Captain"      %in% names(registry))
  expect_true("Nameless Captain" %in% names(registry))
  expect_equal(registry[["the Captain"]]$slug, "Basil")
})

test_that("build_alias_registry captures display_as from PC note", {
  tmp <- local_tempdir()
  dir.create(file.path(tmp, "pcs"))
  write_md_note(file.path(tmp, "pcs"), "Basil.md", c(
    "tags: [pc]",
    "name: Basil",
    "aliases: [Basil, the Captain]",
    "display_as: the Captain"
  ))
  registry <- build_alias_registry(vault_path = tmp)
  expect_equal(registry[["Basil"]]$display, "the Captain")
})

test_that("build_alias_registry registers NPC notes without display_as", {
  tmp <- local_tempdir()
  dir.create(file.path(tmp, "npcs"))
  write_md_note(file.path(tmp, "npcs"), "Attorrnash.md", c(
    "tags: [npc]",
    "name: Attorrnash",
    "aliases: [Attorrnash, Attornash]"
  ))
  registry <- build_alias_registry(vault_path = tmp)
  expect_true("Attorrnash" %in% names(registry))
  expect_true("Attornash"  %in% names(registry))
  expect_null(registry[["Attorrnash"]]$display)
})

test_that("build_alias_registry handles both pcs/ and npcs/ in one call", {
  tmp <- local_tempdir()
  dir.create(file.path(tmp, "pcs"))
  dir.create(file.path(tmp, "npcs"))
  write_md_note(file.path(tmp, "pcs"), "Basil.md", c(
    "name: Basil", "aliases: [Basil]", "display_as: the Captain"
  ))
  write_md_note(file.path(tmp, "npcs"), "Attorrnash.md", c(
    "name: Attorrnash", "aliases: [Attorrnash, Attornash]"
  ))
  registry <- build_alias_registry(vault_path = tmp)
  expect_true("Basil"      %in% names(registry))
  expect_true("Attorrnash" %in% names(registry))
  expect_true("Attornash"  %in% names(registry))
})

test_that("build_alias_registry skips files with no name field", {
  tmp <- local_tempdir()
  dir.create(file.path(tmp, "npcs"))
  write_md_note(file.path(tmp, "npcs"), "broken.md", c("tags: [npc]"))
  registry <- build_alias_registry(vault_path = tmp)
  expect_equal(length(registry), 0)
})

test_that("resolve_wikilink round-trips correctly through a built registry", {
  tmp <- local_tempdir()
  dir.create(file.path(tmp, "pcs"))
  write_md_note(file.path(tmp, "pcs"), "Basil.md", c(
    "name: Basil",
    "aliases: [Basil, the Captain, Nameless Captain]",
    "display_as: the Captain"
  ))
  registry <- build_alias_registry(vault_path = tmp)

  expect_equal(resolve_wikilink("Basil",           registry), "[[Basil|the Captain]]")
  expect_equal(resolve_wikilink("the Captain",     registry), "[[Basil|the Captain]]")
  expect_equal(resolve_wikilink("Nameless Captain", registry), "[[Basil|the Captain]]")
  expect_null(resolve_wikilink("Unknown",          registry))
})

# --- replace_entity_mentions() -----------------------------------------------

# Shared registry for these tests
replace_registry <- list(
  "Basil"          = list(slug = "Basil",      display = "the Captain"),
  "the Captain"    = list(slug = "Basil",      display = "the Captain"),
  "Nameless Captain" = list(slug = "Basil",    display = "the Captain"),
  "Attorrnash"     = list(slug = "Attorrnash", display = NULL)
)

test_that("replace_entity_mentions replaces a bare name with a wikilink", {
  result <- replace_entity_mentions("We met Attorrnash today.", replace_registry)
  expect_equal(result, "We met [[Attorrnash]] today.")
})

test_that("replace_entity_mentions uses display_as when present", {
  result <- replace_entity_mentions("Basil spoke first.", replace_registry)
  expect_equal(result, "[[Basil|the Captain]] spoke first.")
})

test_that("replace_entity_mentions matches the longest name first", {
  # "the Captain" must be matched as a unit, not replaced as "the " + "Captain"
  result <- replace_entity_mentions("the Captain gave orders.", replace_registry)
  expect_equal(result, "[[Basil|the Captain]] gave orders.")
  # Should not produce [[Basil|the Captain]]ful or double-link
  expect_equal(str_count(result, "\\[\\["), 1L)
})

test_that("replace_entity_mentions does not replace text inside existing wikilinks", {
  input  <- "Spoke with [[Attorrnash]] and Attorrnash's crew."
  result <- replace_entity_mentions(input, replace_registry)
  # The first [[Attorrnash]] should remain untouched (already a wikilink)
  expect_equal(str_count(result, "\\[\\[Attorrnash\\]\\]"), 2L)
})

test_that("replace_entity_mentions leaves unregistered names unchanged", {
  result <- replace_entity_mentions("Saw Buhrghur on the docks.", replace_registry)
  expect_equal(result, "Saw Buhrghur on the docks.")
})

test_that("replace_entity_mentions returns text unchanged when registry is empty", {
  result <- replace_entity_mentions("Attorrnash appeared.", list())
  expect_equal(result, "Attorrnash appeared.")
})

test_that("replace_entity_mentions handles text with no entity mentions", {
  result <- replace_entity_mentions("Nothing happened today.", replace_registry)
  expect_equal(result, "Nothing happened today.")
})

test_that("replace_entity_mentions handles multiple distinct entities in one string", {
  result <- replace_entity_mentions("Attorrnash spoke to Basil.", replace_registry)
  expect_true(grepl("[[Attorrnash]]",          result, fixed = TRUE))
  expect_true(grepl("[[Basil|the Captain]]",   result, fixed = TRUE))
})
