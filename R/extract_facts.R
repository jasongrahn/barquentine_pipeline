library(jsonlite)
library(stringr)

# --- Schemas ------------------------------------------------------------------

EVENT_SCHEMA <- list(
  type       = "object",
  required   = "events",
  properties = list(
    events = list(
      type  = "array",
      items = list(
        type       = "object",
        required   = c("description", "characters_involved", "location"),
        properties = list(
          description         = list(type = "string"),
          characters_involved = list(type = "array", items = list(type = "string")),
          location            = list(type = "string")
        )
      )
    )
  )
)

NPC_SCHEMA <- list(
  type       = "object",
  required   = "npcs",
  properties = list(
    npcs = list(
      type  = "array",
      items = list(
        type       = "object",
        required   = c("name", "actions", "quotes"),
        properties = list(
          name    = list(type = "string"),
          actions = list(type = "array", items = list(type = "string")),
          quotes  = list(type = "array", items = list(type = "string"))
        )
      )
    )
  )
)

LOCATION_SCHEMA <- list(
  type       = "object",
  required   = "locations",
  properties = list(
    locations = list(
      type  = "array",
      items = list(
        type       = "object",
        required   = c("name", "description"),
        properties = list(
          name        = list(type = "string"),
          description = list(type = "string")
        )
      )
    )
  )
)

THREAD_SCHEMA <- list(
  type       = "object",
  required   = "threads",
  properties = list(
    threads = list(
      type  = "array",
      items = list(
        type       = "object",
        required   = c("description", "related_characters"),
        properties = list(
          description        = list(type = "string"),
          related_characters = list(type = "array", items = list(type = "string"))
        )
      )
    )
  )
)

# --- System prompts -----------------------------------------------------------

EVENT_SYSTEM_PROMPT <- paste(
  "Extract key events from D&D session notes.",
  "Only extract events present in the text. Never fabricate.",
  "Use [unclear] for garbled words."
)

NPC_SYSTEM_PROMPT <- paste(
  "Extract NPC information from D&D session notes.",
  "Only extract characters and actions present in the text. Never fabricate."
)

LOCATION_SYSTEM_PROMPT <- paste(
  "Extract named locations from D&D session notes.",
  "Only extract locations present in the text. Never fabricate."
)

THREAD_SYSTEM_PROMPT <- paste(
  "Extract unresolved plot threads and open questions from D&D session notes.",
  "Only extract threads present in the text. Never fabricate."
)

# --- Chunking -----------------------------------------------------------------

chunk_source_text <- function(text, chunk_words = 1500L, overlap_words = 150L) {
  words <- str_split(str_squish(text), "\\s+")[[1]]
  words <- words[nzchar(words)]
  if (length(words) == 0) return(character(0))

  step   <- chunk_words - overlap_words
  starts <- seq(1, length(words), by = step)

  vapply(starts, function(s) {
    paste(words[s:min(s + chunk_words - 1, length(words))], collapse = " ")
  }, character(1))
}

# --- Extraction helpers -------------------------------------------------------

.safe_parse <- function(result, key) {
  if (is.list(result) && isTRUE(result$timed_out)) return(list())
  if (!is.character(result) || !nzchar(trimws(result))) return(list())
  tryCatch({
    parsed <- fromJSON(result, simplifyVector = FALSE)
    if (is.null(parsed[[key]])) list() else parsed[[key]]
  }, error = function(e) list())
}

.extract <- function(source_chunk, system_prompt, schema, key,
                     model = OLLAMA_MODEL, base_url = OLLAMA_BASE_URL) {
  result <- ollama_generate(source_chunk, system_prompt,
                            model = model, base_url = base_url,
                            format = schema, think = FALSE)
  .safe_parse(result, key)
}

extract_events <- function(source_chunk, model = OLLAMA_MODEL,
                           base_url = OLLAMA_BASE_URL) {
  .extract(source_chunk, EVENT_SYSTEM_PROMPT, EVENT_SCHEMA, "events",
           model, base_url)
}

extract_npcs <- function(source_chunk, model = OLLAMA_MODEL,
                         base_url = OLLAMA_BASE_URL) {
  .extract(source_chunk, NPC_SYSTEM_PROMPT, NPC_SCHEMA, "npcs",
           model, base_url)
}

extract_locations <- function(source_chunk, model = OLLAMA_MODEL,
                              base_url = OLLAMA_BASE_URL) {
  .extract(source_chunk, LOCATION_SYSTEM_PROMPT, LOCATION_SCHEMA, "locations",
           model, base_url)
}

extract_threads <- function(source_chunk, model = OLLAMA_MODEL,
                            base_url = OLLAMA_BASE_URL) {
  .extract(source_chunk, THREAD_SYSTEM_PROMPT, THREAD_SCHEMA, "threads",
           model, base_url)
}

# --- Deduplication ------------------------------------------------------------

dedupe_npcs <- function(npc_lists) {
  flat <- unlist(npc_lists, recursive = FALSE)
  if (length(flat) == 0) return(list())

  merged <- list()
  for (npc in flat) {
    key <- tolower(trimws(npc$name))
    if (key %in% names(merged)) {
      merged[[key]]$actions <- unique(c(merged[[key]]$actions, npc$actions))
      merged[[key]]$quotes  <- unique(c(merged[[key]]$quotes,  npc$quotes))
    } else {
      merged[[key]] <- list(
        name    = npc$name,
        actions = if (is.null(npc$actions)) character(0) else as.character(npc$actions),
        quotes  = if (is.null(npc$quotes))  character(0) else as.character(npc$quotes)
      )
    }
  }
  unname(merged)
}

dedupe_events <- function(event_lists) {
  flat <- unlist(event_lists, recursive = FALSE)
  if (length(flat) == 0) return(list())

  seen  <- character(0)
  deduped <- list()
  for (evt in flat) {
    norm <- tolower(trimws(evt$description))
    # fuzzy match: skip if any existing description contains this one or vice versa
    is_dup <- any(vapply(seen, function(s) {
      grepl(norm, s, fixed = TRUE) || grepl(s, norm, fixed = TRUE)
    }, logical(1)))
    if (!is_dup) {
      seen <- c(seen, norm)
      deduped <- c(deduped, list(evt))
    }
  }
  deduped
}

# --- Main entry point ---------------------------------------------------------

extract_session_facts <- function(source_text, model = OLLAMA_MODEL,
                                  base_url = OLLAMA_BASE_URL) {
  chunks <- chunk_source_text(source_text)
  if (length(chunks) == 0) {
    return(list(events = list(), npcs = list(),
                locations = list(), threads = list()))
  }

  all_events    <- list()
  all_npcs      <- list()
  all_locations <- list()
  all_threads   <- list()

  for (chunk in chunks) {
    all_events    <- c(all_events,    list(extract_events(chunk, model, base_url)))
    all_npcs      <- c(all_npcs,      list(extract_npcs(chunk, model, base_url)))
    all_locations <- c(all_locations, list(extract_locations(chunk, model, base_url)))
    all_threads   <- c(all_threads,   list(extract_threads(chunk, model, base_url)))
  }

  list(
    events    = dedupe_events(all_events),
    npcs      = dedupe_npcs(all_npcs),
    locations = unlist(all_locations, recursive = FALSE),
    threads   = unlist(all_threads,  recursive = FALSE)
  )
}
