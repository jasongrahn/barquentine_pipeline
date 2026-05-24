# JSON schemas for agentic entity extraction (Phase 4.2).
#
# entity_schema(note_type) returns a nested R list matching the Ollama
# `format` parameter shape (JSON Schema draft-07 subset). Every non-trivial
# field uses {value, line} so the mechanical fact-checker can verify citations.
#
# entity_schema_version() returns the current schema version tag, written
# into training-data records for provenance.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

.valued_field <- function() {
  list(
    type       = "object",
    properties = list(
      value = list(type = c("string", "null")),
      line  = list(type = c("integer", "null"))
    ),
    required   = c("value", "line")
  )
}

.named_line_item <- function(name_field = "name") {
  props <- list(line = list(type = c("integer", "null")))
  props[[name_field]] <- list(type = "string")
  list(type = "object", properties = props, required = c(name_field, "line"))
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

entity_schema <- function(note_type) {
  switch(note_type,
    pc       = .pc_schema(),
    npc      = .npc_schema(),
    location = .location_schema(),
    faction  = .faction_schema(),
    stop("Unknown note_type: ", note_type)
  )
}

entity_schema_version <- function() AGENTIC_ENTITY_SCHEMA_VERSION  # v2

# ---------------------------------------------------------------------------
# Per-type schemas
# ---------------------------------------------------------------------------

.pc_schema <- function() {
  list(
    type       = "object",
    properties = list(
      bio                   = .valued_field(),
      description           = .valued_field(),
      aliases               = list(type = "array", items = list(type = "string")),
      exhibited_personality = .valued_field(),
      role_in_story         = .valued_field()
    ),
    required = c("bio", "description", "aliases", "exhibited_personality",
                 "role_in_story")
  )
}

.npc_schema <- function() {
  list(
    type       = "object",
    properties = list(
      description           = .valued_field(),
      aliases               = list(type = "array", items = list(type = "string")),
      exhibited_personality = .valued_field(),
      role_in_story         = .valued_field()
    ),
    required = c("description", "aliases", "exhibited_personality", "role_in_story")
  )
}

.location_schema <- function() {
  list(
    type       = "object",
    properties = list(
      description      = .valued_field(),
      region           = .valued_field(),
      notable_features = list(
        type  = "array",
        items = .named_line_item("feature")
      ),
      events_witnessed = list(
        type  = "array",
        items = list(
          type       = "object",
          properties = list(
            event = list(type = "string"),
            line  = list(type = c("integer", "null"))
          ),
          required = c("event", "line")
        )
      )
    ),
    required = character(0)
  )
}

.faction_schema <- function() {
  list(
    type       = "object",
    properties = list(
      description  = .valued_field(),
      goals        = list(
        type  = "array",
        items = list(
          type       = "object",
          properties = list(
            value = list(type = "string"),
            line  = list(type = c("integer", "null"))
          ),
          required = c("value", "line")
        )
      ),
      known_members = list(
        type  = "array",
        items = .named_line_item("name")
      ),
      allies  = list(type = "array", items = list(type = "string")),
      enemies = list(type = "array", items = list(type = "string"))
    ),
    required = c("description", "goals", "known_members", "allies", "enemies")
  )
}
