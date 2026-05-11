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

# Drop NPC rows that are clearly DM-voice noise: descriptions like "The Admiral",
# "DM, appears to be directing the scene", "A name", or "A person". These are
# placeholders the extractor returns when the chunk only mentioned a label.
filter_low_signal_npcs <- function(npcs) {
  if (is.null(npcs) || nrow(npcs) == 0) return(npcs)
  noise_patterns <- c(
    "^The Admiral$",
    "^DM\\b",
    "^A name$",
    "^A person$",
    "^An? [a-z]+$"  # "An admiral", "A guide" — single-word generic role
  )
  bad <- Reduce(`|`, lapply(noise_patterns, function(p)
    grepl(p, npcs$description %||% "", ignore.case = FALSE)))
  if (is.null(bad)) return(npcs)
  npcs[!bad, , drop = FALSE]
}

# Heuristic location dedup: collapse "the X" vs "X" vs "X-1" near-matches by
# normalizing the slug (drop "the_", trailing digit suffixes) and keeping the
# longest description.
collapse_near_match_locations <- function(locs) {
  if (is.null(locs) || nrow(locs) == 0) return(locs)
  locs |>
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
}

# Convenience: full postprocessing pipeline. Takes the merged extraction
# (the `extracted.rds` payload) and returns a new list with the same
# shape but filtered, deduped, and pruned.
postprocess_extracted <- function(extracted,
                                  protected_path = "config/protected_entities.csv",
                                  event_keep_n   = 18) {
  npcs <- extracted$npcs |>
    filter_pc_and_player_npcs(protected_path = protected_path) |>
    dedup_by_slug("name") |>
    filter_low_signal_npcs()

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
