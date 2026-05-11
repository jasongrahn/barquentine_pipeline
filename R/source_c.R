library(stringr)
library(jsonlite)
library(purrr)
library(readr)

ENTITY_SPOT_SCHEMA <- list(
  type     = "object",
  required = c("npcs", "locations", "items", "factions"),
  properties = list(
    npcs      = list(type = "array", items = list(type = "string")),
    locations = list(type = "array", items = list(type = "string")),
    items     = list(type = "array", items = list(type = "string")),
    factions  = list(type = "array", items = list(type = "string"))
  )
)

ENTITY_SPOT_SYSTEM_PROMPT <- paste(
  "You are an entity extractor for a D&D 5e Spelljammer campaign called Barquentine.",
  "",
  "Extract named NPCs, locations, items, and factions from the transcript text.",
  "",
  "Rules:",
  "- Never fabricate. Only extract names that clearly appear in the text.",
  "- If a word is garbled or unclear, write [unclear] — do not guess.",
  "- Return only proper names, not pronouns or generic descriptions.",
  "- NPCs: named characters (not 'the guard', but 'Attorrnash')",
  "- Locations: named places (not 'the room', but 'The Giff Flotilla')",
  "- Items: named objects or artifacts",
  "- Factions: named groups or organizations",
  sep = "\n"
)

load_entity_exclusions <- function(path = ENTITY_EXCLUSIONS_PATH) {
  if (!file.exists(path)) return(character(0))
  df <- read_csv(path, show_col_types = FALSE)
  if (!"slug" %in% names(df)) return(character(0))
  df$slug[!is.na(df$slug) & nzchar(df$slug)]
}

load_protected_slugs <- function(path = PROTECTED_ENTITIES_PATH) {
  if (!file.exists(path)) return(character(0))
  df <- read_csv(path, show_col_types = FALSE)
  if (!"slug" %in% names(df)) return(character(0))
  keep <- !is.na(df$slug) & nzchar(df$slug)
  # If the column exists, entities marked exclude_from_spotting = TRUE are
  # dropped entirely elsewhere — they should not bypass the frequency filter here.
  if ("exclude_from_spotting" %in% names(df))
    keep <- keep & (is.na(df$exclude_from_spotting) | !df$exclude_from_spotting)
  # dm_voice rows are DM persona labels, not in-fiction NPCs; they must not
  # bypass the frequency filter. Mirrors load_agentic_protected_slugs().
  if ("entity_type" %in% names(df))
    keep <- keep & (is.na(df$entity_type) | df$entity_type != "dm_voice")
  df$slug[keep]
}

load_excluded_entity_slugs <- function(path = PROTECTED_ENTITIES_PATH) {
  if (!file.exists(path)) return(character(0))
  df <- read_csv(path, show_col_types = FALSE)
  if (!"slug" %in% names(df)) return(character(0))

  base_keep <- !is.na(df$slug) & nzchar(df$slug)
  drop      <- rep(FALSE, nrow(df))

  if ("exclude_from_spotting" %in% names(df)) {
    flag <- df$exclude_from_spotting
    if (is.character(flag)) flag <- tolower(flag) == "true"
    drop <- drop | (!is.na(flag) & flag)
  }

  # dm_voice + player rows are dropped from the entity-note pipeline
  # entirely (DM persona and real-world players never get character wikis).
  # PCs and pc_aliases are NOT dropped here — they're main characters and
  # need their own wiki pages. The agentic chain's
  # filter_pc_and_player_npcs() also drops pc/pc_alias, but only from the
  # *NPC list inside a session recap*; for the entity chain (per-character
  # wiki generation) PCs must stay. captain + the_captain produce separate
  # records that the Phase 4.5 Merge UI collapses at review time.
  if ("entity_type" %in% names(df)) {
    drop <- drop | (!is.na(df$entity_type) &
                    df$entity_type %in% c("dm_voice", "player"))
  }

  df$slug[base_keep & drop]
}

load_vtt_registry <- function(registry_path = "config/vtt_registry.csv",
                              active_episodes = ACTIVE_EPISODES) {
  df <- read_csv(registry_path, show_col_types = FALSE)
  df <- df[!is.na(df$episode_id) & nzchar(df$episode_id), ]
  if (!is.null(active_episodes))
    df <- df[df$episode_id %in% active_episodes, ]
  df
}

read_vtt <- function(path) {
  lines <- readLines(path, warn = FALSE)
  keep  <- !grepl("^WEBVTT|^\\s*$|^\\d{2}:\\d{2}:\\d{2}|^\\d+$", lines)
  paste(trimws(lines[keep]), collapse = " ")
}

chunk_vtt <- function(text, chunk_words = CHUNK_SIZE_WORDS, overlap_words = CHUNK_OVERLAP_WORDS) {
  words <- str_split(str_squish(text), "\\s+")[[1]]
  words <- words[nzchar(words)]
  if (length(words) == 0) return(character(0))

  step   <- chunk_words - overlap_words
  starts <- seq(1, length(words), by = step)

  map_chr(starts, function(s) {
    paste(words[s:min(s + chunk_words - 1, length(words))], collapse = " ")
  })
}

spot_entities <- function(chunk, model = OLLAMA_CRITIC_MODEL, base_url = OLLAMA_BASE_URL) {
  empty <- list(npcs = list(), locations = list(), items = list(), factions = list())
  tryCatch({
    raw <- ollama_generate(chunk, ENTITY_SPOT_SYSTEM_PROMPT,
                           model = model, base_url = base_url,
                           format = ENTITY_SPOT_SCHEMA)
    parsed <- if (is.character(raw)) fromJSON(raw, simplifyVector = FALSE) else raw
    for (k in c("npcs", "locations", "items", "factions")) {
      if (is.null(parsed[[k]])) parsed[[k]] <- list()
    }
    parsed
  }, error = function(e) empty)
}

make_slug <- function(name) {
  name |>
    str_to_lower() |>
    str_replace_all("[^a-z0-9]+", "_") |>
    str_replace_all("^_+|_+$", "")
}

process_vtt_file <- function(path, episode_id,
                              model    = OLLAMA_CRITIC_MODEL,
                              base_url = OLLAMA_BASE_URL) {
  text   <- read_vtt(path)
  chunks <- chunk_vtt(text)

  entity_map <- list(npcs = list(), locations = list(), items = list(), factions = list())

  for (chunk in chunks) {
    spotted <- spot_entities(chunk, model, base_url)
    for (type in c("npcs", "locations", "items", "factions")) {
      for (name in spotted[[type]]) {
        name <- as.character(name)
        if (!nzchar(name)) next
        entity_map[[type]][[name]] <- c(entity_map[[type]][[name]], chunk)
      }
    }
  }

  list(
    episode_id = episode_id,
    npcs       = entity_map$npcs,
    locations  = entity_map$locations,
    items      = entity_map$items,
    factions   = entity_map$factions
  )
}

extract_relevant_sentences <- function(passage, entity_name, window = 2L) {
  sentences <- str_split(passage, "(?<=[.!?])\\s+")[[1]]
  hits      <- which(str_detect(sentences, regex(entity_name, ignore_case = TRUE)))
  if (!length(hits)) return("")
  idx <- unique(sort(c(outer(hits, seq(-window, window, by = 1L), "+"))))
  idx <- idx[idx >= 1L & idx <= length(sentences)]
  paste(sentences[idx], collapse = " ")
}

.is_garbage_name <- function(name) {
  if (!grepl("[a-zA-Z]", name)) return(TRUE)
  if (nchar(name) > 50L)       return(TRUE)
  normalized <- tolower(gsub("[^a-z]", "_", tolower(trimws(name))))
  grepl("^(missing|not_present|not_mentioned|implied_but|unclear|error_from|unknown_name)$",
        normalized)
}

# Merge entity records whose slugs cluster as near-typo variants under
# collapse_near_match_slugs(). Only `note_type == "location"` records
# participate; NPC/faction names cluster too aggressively for an
# unsupervised merge. Cluster survivors take the longest slug as the
# canonical entity_id, the longest entity_name as the display name, and
# the union of source_passages + source_episode_ids.
.collapse_location_records <- function(records) {
  loc_idx <- which(vapply(records,
                          function(r) identical(r$note_type, "location"),
                          logical(1)))
  if (length(loc_idx) < 2L) return(records)

  loc_slugs <- vapply(records[loc_idx], `[[`, character(1), "entity_id")
  reps      <- collapse_near_match_slugs(loc_slugs)
  if (identical(reps, loc_slugs)) return(records)

  by_rep <- split(seq_along(loc_idx), reps)

  merged_locs <- lapply(by_rep, function(local_idxs) {
    idxs <- loc_idx[local_idxs]
    if (length(idxs) == 1L) return(records[[idxs]])

    survivors <- records[idxs]
    rep_slug  <- reps[local_idxs[1]]
    names_here <- vapply(survivors, `[[`, character(1), "entity_name")
    base       <- survivors[[which.max(nchar(names_here))]]

    base$entity_id          <- rep_slug
    base$source_passages    <- unique(unlist(
      lapply(survivors, `[[`, "source_passages"), use.names = FALSE))
    base$source_episode_ids <- unique(unlist(
      lapply(survivors, `[[`, "source_episode_ids"), use.names = FALSE))

    absorbed <- setdiff(names_here, base$entity_name)
    if (length(absorbed)) {
      message(sprintf("  [location collapse] '%s' absorbed: %s",
                      base$entity_name, paste(absorbed, collapse = ", ")))
    }
    base
  })

  non_loc <- records[-loc_idx]
  c(non_loc, unname(merged_locs))
}

aggregate_entity_passages <- function(vtt_file_results, alias_registry,
                                      min_chunks = MIN_ENTITY_CHUNK_COUNT,
                                      exclusion_slugs = character(0),
                                      protected_slugs = character(0)) {
  type_to_note <- c(npcs = "npc", locations = "location", factions = "faction")
  acc <- list()

  # Step 1: merge cross-episode, accumulating raw chunk text
  for (file_result in vtt_file_results) {
    ep_id <- file_result$episode_id

    for (etype in c("npcs", "locations", "factions")) {
      note_type <- type_to_note[[etype]]

      for (name in names(file_result[[etype]])) {
        chunks <- file_result[[etype]][[name]]
        if (.is_garbage_name(name)) {
          message(sprintf("  [garbage name] dropped: '%s'", name))
          next
        }
        slug   <- resolve_alias(name, alias_registry)
        if (is.null(slug)) slug <- make_slug(name)
        if (is.list(slug)) slug <- slug$slug

        # ^unnamed\b filter — post alias-resolution, protected-slug bypass.
        # The model emits "unnamed adjutant" / "unnamed Astra Elf" etc. as
        # extractor noise; drop them unless the stripped slug is protected
        # (mirrors agentic_slug() + filter_low_signal_npcs() gating, so
        # "unnamed Ted" still maps onto the protected "ted" slug).
        if (grepl("^unnamed\\b", name, ignore.case = TRUE)) {
          stripped_slug <- make_slug(sub("^unnamed[ _]+", "", name,
                                         ignore.case = TRUE))
          if (stripped_slug %in% protected_slugs) {
            slug <- stripped_slug
          } else {
            message(sprintf("  [unnamed dropped] '%s'", name))
            next
          }
        }

        if (slug %in% exclusion_slugs) {
          message(sprintf("  [excluded] dropped: '%s'", name))
          next
        }

        if (is.null(acc[[slug]])) {
          acc[[slug]] <- list(
            entity_id          = slug,
            entity_name        = name,
            note_type          = note_type,
            source_passages    = chunks,
            source_episode_ids = ep_id
          )
        } else {
          acc[[slug]]$source_passages    <- c(acc[[slug]]$source_passages, chunks)
          acc[[slug]]$source_episode_ids <- c(acc[[slug]]$source_episode_ids, ep_id)
        }
      }
    }
  }

  # Step 2: deduplicate, then frequency-filter on full chunk text before extraction
  kept    <- 0L
  dropped <- 0L
  dropped_names <- character(0)

  records <- lapply(names(acc), function(s) {
    rec <- acc[[s]]
    rec$source_passages    <- unique(rec$source_passages)
    rec$source_episode_ids <- unique(rec$source_episode_ids)
    rec
  })

  # Step 2.5: edit-distance collapse on location slugs only. NPC/faction
  # names are too typo-fragile for an unsupervised merge ("Cletus" vs
  # "Cletas" must not silently fold). Locations get the helper from
  # R/postprocess_shared.R, shared with the agentic chain.
  records <- .collapse_location_records(records)

  records <- Filter(function(rec) {
    if (length(rec$source_passages) >= min_chunks || rec$entity_id %in% protected_slugs) {
      kept <<- kept + 1L
      TRUE
    } else {
      dropped       <<- dropped + 1L
      dropped_names <<- c(dropped_names, rec$entity_name)
      FALSE
    }
  }, records)

  message(sprintf(
    "aggregate_entity_passages: kept %d, dropped %d (threshold=%d). Dropped: %s",
    kept, dropped, min_chunks,
    if (length(dropped_names)) paste(head(dropped_names, 10), collapse = ", ") else "none"
  ))

  # Step 3: sentence-window extraction on survivors only
  lapply(records, function(rec) {
    extracted <- vapply(rec$source_passages, extract_relevant_sentences,
                        character(1), entity_name = rec$entity_name)
    extracted <- extracted[nzchar(extracted)]
    rec$source_passages <- if (length(extracted)) extracted else rec$source_passages
    rec
  })
}
