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
  df$slug[keep]
}

load_excluded_entity_slugs <- function(path = PROTECTED_ENTITIES_PATH) {
  if (!file.exists(path)) return(character(0))
  df <- read_csv(path, show_col_types = FALSE)
  needed <- c("slug", "exclude_from_spotting")
  if (!all(needed %in% names(df))) return(character(0))
  flag <- df$exclude_from_spotting
  if (is.character(flag)) flag <- tolower(flag) == "true"
  df$slug[!is.na(df$slug) & nzchar(df$slug) & !is.na(flag) & flag]
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

        if (slug %in% exclusion_slugs) {
          message(sprintf("  [protected] dropped: '%s'", name))
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
