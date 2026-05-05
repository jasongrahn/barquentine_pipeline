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

aggregate_entity_passages <- function(vtt_file_results, alias_registry) {
  type_to_note <- c(npcs = "npc", locations = "location", factions = "faction")
  acc <- list()

  for (file_result in vtt_file_results) {
    ep_id <- file_result$episode_id

    for (type in c("npcs", "locations", "factions")) {
      note_type <- type_to_note[[type]]

      for (name in names(file_result[[type]])) {
        chunks <- file_result[[type]][[name]]
        slug   <- resolve_alias(name, alias_registry)
        if (is.null(slug)) slug <- make_slug(name)
        if (is.list(slug)) slug <- slug$slug

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

  lapply(names(acc), function(s) {
    acc[[s]]$source_passages    <- unique(acc[[s]]$source_passages)
    acc[[s]]$source_episode_ids <- unique(acc[[s]]$source_episode_ids)
    acc[[s]]
  })
}
