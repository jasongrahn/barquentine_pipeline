# Post-processing for the agentic extraction pipeline.
# Sits between the per-chunk extraction merge and the synthesis call.
# All functions take and return data.frames; the synthesis skill receives a
# trimmed, deduped, filtered view rather than the raw 200+ row union.

suppressPackageStartupMessages({
  library(dplyr); library(stringr); library(readr)
})

# Slug a name the same way for matching against protected_entities.csv.
# Strips a leading "unnamed " or "unnamed_" qualifier so that
# "unnamed Lumi" / "Lumi" / "lumi" all map to the same slug.
agentic_slug <- function(name) {
  s <- tolower(as.character(name) %||% "")
  s <- str_replace(s, "^unnamed[ _]+", "")
  s <- str_replace_all(s, "[^a-z0-9]+", "_")
  s <- str_replace_all(s, "^_+|_+$", "")
  s
}

# Drop NPC rows that match a PC or real-player slug. Reads
# config/protected_entities.csv as the source of truth: any row whose
# entity_type starts with "pc" (pc, pc_alias) OR is "player" gets dropped
# from NPC lists — those are not NPCs, they're players or characters
# played by a person at the table.
filter_pc_and_player_npcs <- function(
  npcs,
  protected_path = "config/protected_entities.csv"
) {
  if (is.null(npcs) || nrow(npcs) == 0) return(npcs)

  prot <- read_csv(protected_path, show_col_types = FALSE)
  drop_slugs <- prot$slug[grepl("^pc", prot$entity_type) |
                          prot$entity_type == "player"]

  npcs |>
    mutate(.slug = agentic_slug(name)) |>
    filter(!.slug %in% drop_slugs) |>
    select(-.slug)
}

# Dedup entities by canonical slug. When the model emits "Astral Sea" and
# "Astro Sea" or "The Admiral" three times with different qualifiers, fold
# them into one row keyed by the slug and keep the longest description.
dedup_by_slug <- function(df, key_col = "name") {
  if (is.null(df) || nrow(df) == 0) return(df)
  if (!key_col %in% names(df)) return(df)

  df |>
    mutate(.slug = agentic_slug(.data[[key_col]])) |>
    group_by(.slug) |>
    summarize(
      across(any_of(key_col),       ~ first(.x[order(-nchar(.x))])),
      across(any_of("description"), ~ first(.x[order(-nchar(as.character(.x))) ])),
      across(any_of("appeared"),    ~ any(as.logical(.x), na.rm = TRUE)),
      across(any_of("line"),        ~ suppressWarnings(min(as.integer(.x), na.rm = TRUE))),
      .groups = "drop"
    ) |>
    select(-.slug)
}

# Significance heuristic for event pruning. An event scores higher if:
#   + it names a known NPC or location (proper-noun mention)
#   + its type is "revelation" or "consequence" (plot-pivot tags)
#   + its description is information-dense (>10 words)
# A negative bias is applied to short generic descriptions ("party moves",
# "DM narrates"). Returns the top-N events in chronological order.
prune_events <- function(events, npcs, locations, n = 18) {
  if (is.null(events) || nrow(events) == 0) return(events)

  named_terms <- c(
    if (!is.null(npcs)      && nrow(npcs)      > 0) npcs$name,
    if (!is.null(locations) && nrow(locations) > 0) locations$name
  )
  named_terms <- named_terms[nchar(named_terms) > 2]
  pattern <- if (length(named_terms) > 0) {
    paste0("\\b(", paste(unique(named_terms), collapse = "|"), ")\\b")
  } else NA_character_

  scored <- events |>
    mutate(
      .name_hits = if (!is.na(pattern))
        str_count(event, regex(pattern, ignore_case = TRUE))
      else 0L,
      .tag_bonus = case_when(
        type %in% c("revelation", "consequence") ~ 2L,
        type == "scene_change"                   ~ 1L,
        TRUE                                     ~ 0L
      ),
      .word_count = str_count(event, "\\S+"),
      .density_bonus = pmin(.word_count %/% 10L, 2L),
      .generic_penalty = if_else(
        str_detect(event, regex("^(the party|the players|the dm|the admiral) (moves|narrates|describes)\\b",
                                ignore_case = TRUE)),
        -2L, 0L
      ),
      .score = .name_hits + .tag_bonus + .density_bonus + .generic_penalty
    )

  top <- scored |>
    arrange(desc(.score), line) |>
    slice_head(n = n) |>
    arrange(line) |>
    select(-starts_with("."))

  top
}

# Drop NPC rows whose name matches a DM-voice slug (e.g. "The Admiral" — the
# DM-the-person's persona, not an in-fiction NPC). The skill prompt declares
# "The Admiral" is the DM's voice, but the extractor still occasionally emits
# it as an NPC; this filter is the data-side enforcement.
#
# Matching is by canonical slug, so "The Admiral", "the admiral", and any
# stray casing collapse onto the same row.
filter_dm_voice_npcs <- function(npcs, dm_voice_slugs = character(0)) {
  if (is.null(npcs) || nrow(npcs) == 0) return(npcs)
  if (length(dm_voice_slugs) == 0L) return(npcs)
  npcs[!(agentic_slug(npcs$name) %in% dm_voice_slugs), , drop = FALSE]
}

# Drop NPC rows that are clearly DM-voice noise or generic placeholders.
# Matches against BOTH `name` and `description`:
#   - description matches "The Admiral", "DM, ...", "A name", "A person",
#     or a single-word generic role like "An admiral" / "A guide"
#   - name matches "unnamed *" (e.g. "unnamed adjutant", "unnamed Astra Elf").
#     The skill prompt says to use "unknown NPC" for un-attributable DM
#     voice, but the extractor invents descriptive labels instead.
#
# Rows whose slug is in `protected_slugs` bypass the filter, so a known NPC
# (e.g. Ted, Cletus) with a thin description is not silently dropped. Note
# that agentic_slug() strips a leading "unnamed " qualifier, so
# "unnamed Ted" still maps onto the protected "ted" slug.
filter_low_signal_npcs <- function(npcs, protected_slugs = character(0)) {
  if (is.null(npcs) || nrow(npcs) == 0) return(npcs)

  desc_patterns <- c(
    "^The Admiral$",
    "^DM\\b",
    "^A name$",
    "^A person$",
    "^An? [a-z]+$"  # "An admiral", "A guide" — single-word generic role
  )
  name_patterns <- c(
    "^unnamed\\b"   # "unnamed adjutant", "unnamed Astra Elf" — extractor noise
  )

  bad_desc <- Reduce(`|`, lapply(desc_patterns, function(p)
    grepl(p, npcs$description %||% "", ignore.case = FALSE)))
  bad_name <- Reduce(`|`, lapply(name_patterns, function(p)
    grepl(p, npcs$name %||% "", ignore.case = TRUE)))
  bad <- (bad_desc %||% FALSE) | (bad_name %||% FALSE)

  if (length(protected_slugs) > 0L) {
    protected_hit <- agentic_slug(npcs$name) %in% protected_slugs
    bad <- bad & !protected_hit
  }

  npcs[!bad, , drop = FALSE]
}

# Read protected_entities.csv + entity_aliases.csv and produce the union of
# slugs that should bypass the low-signal filter. PC and player entities are
# included even though they are dropped earlier by filter_pc_and_player_npcs;
# the union is a superset, not a routing decision.
#
# Rows with entity_type == "dm_voice" are EXCLUDED from the bypass set —
# they are persona labels the DM speaks as ("The Admiral"), not in-fiction
# NPCs to preserve. They get dropped by filter_dm_voice_npcs() instead.
load_agentic_protected_slugs <- function(
  protected_path = "config/protected_entities.csv",
  aliases_path   = "config/entity_aliases.csv"
) {
  base <- character(0)
  if (file.exists(protected_path)) {
    prot <- read_csv(protected_path, show_col_types = FALSE)
    if ("slug" %in% names(prot)) {
      keep <- !is.na(prot$slug) & nzchar(prot$slug)
      if ("entity_type" %in% names(prot)) {
        keep <- keep & (is.na(prot$entity_type) | prot$entity_type != "dm_voice")
      }
      base <- prot$slug[keep]
    }
  }
  if (file.exists(aliases_path)) {
    aliases <- read_csv(aliases_path, show_col_types = FALSE)
    if (all(c("alias", "canonical_slug") %in% names(aliases))) {
      hits <- !is.na(aliases$canonical_slug) & aliases$canonical_slug %in% base &
              !is.na(aliases$alias) & nzchar(aliases$alias)
      base <- unique(c(base, agentic_slug(aliases$alias[hits])))
    }
  }
  unique(base)
}

# Slugs whose canonical_name is the DM's persona, not an in-fiction NPC.
# Filtered out of NPC lists at the start of postprocess_extracted().
load_dm_voice_slugs <- function(
  protected_path = "config/protected_entities.csv"
) {
  if (!file.exists(protected_path)) return(character(0))
  prot <- read_csv(protected_path, show_col_types = FALSE)
  if (!all(c("slug", "entity_type") %in% names(prot))) return(character(0))
  keep <- !is.na(prot$slug) & nzchar(prot$slug) &
          !is.na(prot$entity_type) & prot$entity_type == "dm_voice"
  unique(prot$slug[keep])
}

# Heuristic location dedup. Two passes:
#   1. Slug normalization — drop "the_" prefix and trailing digit suffixes so
#      "The Brig", "Brig", "Brig-1" collapse onto the same row.
#   2. Edit-distance pass — collapse near-typo pairs the model emitted with
#      slight name variation, e.g. "Astro Sea" vs "Astral Sea". Conservative
#      threshold: edit distance / min(nchar) <= 0.25 AND min slug length >= 6.
#      A 4-char "ship" vs "shop" (ratio 0.25, length 4) is rejected by the
#      length floor; a 9-char "astro_sea" vs 10-char "astral_sea" (dist 2,
#      ratio 0.22) collapses. The longer description is retained.
collapse_near_match_locations <- function(locs,
                                          edit_ratio = 0.25,
                                          min_length = 6L) {
  if (is.null(locs) || nrow(locs) == 0) return(locs)

  locs <- locs |>
    mutate(.norm = str_replace_all(agentic_slug(name),
                                    c("^the_" = "", "_\\d+$" = ""))) |>
    group_by(.norm) |>
    summarize(
      name        = first(name[order(-nchar(name))]),
      description = first(description[order(-nchar(as.character(description)))]),
      line        = suppressWarnings(min(as.integer(line), na.rm = TRUE)),
      .groups = "drop"
    ) |>
    select(-.norm)

  if (nrow(locs) < 2L) return(locs)

  slugs <- agentic_slug(locs$name)
  d <- utils::adist(slugs)
  diag(d) <- NA_integer_

  parent <- seq_len(nrow(locs))
  find <- function(i) {
    while (parent[i] != i) i <- parent[i]
    i
  }
  union_ <- function(i, j) {
    ri <- find(i); rj <- find(j)
    if (ri != rj) parent[ri] <<- rj
  }

  for (i in seq_len(nrow(locs) - 1L)) {
    for (j in (i + 1L):nrow(locs)) {
      shorter <- min(nchar(slugs[i]), nchar(slugs[j]))
      if (shorter < min_length) next
      if (d[i, j] / shorter <= edit_ratio) union_(i, j)
    }
  }

  cluster <- vapply(seq_len(nrow(locs)), find, integer(1))

  locs |>
    mutate(.cluster = cluster) |>
    group_by(.cluster) |>
    summarize(
      name        = first(name[order(-nchar(name))]),
      description = first(description[order(-nchar(as.character(description)))]),
      line        = suppressWarnings(min(as.integer(line), na.rm = TRUE)),
      .groups = "drop"
    ) |>
    select(-.cluster)
}

# Convenience: full postprocessing pipeline. Takes the merged extraction
# (the `extracted.rds` payload) and returns a new list with the same
# shape but filtered, deduped, and pruned.
postprocess_extracted <- function(extracted,
                                  protected_path = "config/protected_entities.csv",
                                  aliases_path   = "config/entity_aliases.csv",
                                  event_keep_n   = 18) {
  protected_slugs <- load_agentic_protected_slugs(protected_path, aliases_path)
  dm_voice_slugs  <- load_dm_voice_slugs(protected_path)

  npcs <- extracted$npcs |>
    filter_dm_voice_npcs(dm_voice_slugs = dm_voice_slugs) |>
    filter_pc_and_player_npcs(protected_path = protected_path) |>
    dedup_by_slug("name") |>
    filter_low_signal_npcs(protected_slugs = protected_slugs)

  locations <- extracted$locations |>
    dedup_by_slug("name") |>
    collapse_near_match_locations()

  events <- prune_events(extracted$events, npcs, locations, n = event_keep_n)

  list(
    events    = events,
    npcs      = npcs,
    locations = locations,
    dialogue  = extracted$dialogue  # leave dialogue as-is; already capped at 8
  )
}

`%||%` <- function(x, y) if (is.null(x)) y else x
