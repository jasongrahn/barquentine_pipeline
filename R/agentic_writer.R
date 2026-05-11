# Vault routing for the agentic-flow session notes and the doc-prep
# sidecar redirect (Q1 in docs/phase_agentic_extraction_integration.md).
#
# Two flows can produce a session-note queue row for the same episode:
#
#   1. doc-prep (R/source_b.R → dispatch_extracted_note) — section_id = "<sid>"
#   2. agentic VTT extraction (this phase)             — section_id = "<sid>__agentic"
#
# Both rows live in the queue simultaneously. The writer below decides the
# vault path per row at accept time:
#
#   <sid>__agentic                       → vault/sessions/<sid>.md   (canonical)
#   <sid>, sid %in% opt_in_ids           → vault/dm_prep/<sid>.md    (sidecar)
#   <sid>, sid %!in% opt_in_ids          → vault/sessions/<sid>.md   (legacy)
#
# The opt-in is read from AGENTIC_VTT_SESSION_IDS in config.R. Episodes
# that opt in surface DM prep at dm_prep/<id>.md and the VTT recap at
# sessions/<id>.md without collision.

# Suffix used to distinguish the agentic queue row from the doc-prep row.
# Kept private to this file so the suffix can be changed in one place.
.AGENTIC_SUFFIX <- "__agentic"

# Construct the queue section_id for an agentic session note.
agentic_section_id <- function(session_id) {
  paste0(session_id, .AGENTIC_SUFFIX)
}

# True when a queue row's section_id was minted by the agentic dispatcher.
is_agentic_section_id <- function(section_id) {
  grepl(paste0(.AGENTIC_SUFFIX, "$"), section_id)
}

# Strip the suffix to recover the canonical episode id.
strip_agentic_suffix <- function(section_id) {
  sub(paste0(.AGENTIC_SUFFIX, "$"), "", section_id)
}

# Resolve the vault-relative path for a session-note queue row. Returns a
# path like "sessions/s02e34.md" or "dm_prep/s02e34.md" — caller passes it
# to write_note() / get_output_path() which prepends VAULT_PATH (or the
# dry-run path) and creates the parent dir.
session_note_relative_path <- function(section_id,
                                       opt_in_ids = AGENTIC_VTT_SESSION_IDS) {
  if (is_agentic_section_id(section_id)) {
    base <- strip_agentic_suffix(section_id)
    return(file.path("sessions", paste0(base, ".md")))
  }
  if (length(opt_in_ids) > 0L && section_id %in% opt_in_ids) {
    return(file.path("dm_prep", paste0(section_id, ".md")))
  }
  file.path("sessions", paste0(section_id, ".md"))
}

# Convenience writer used by the smoke-test wrapper. Production accept path
# goes through Shiny → write_note() with the relative_path computed above.
write_agentic_session_note <- function(markdown, session_id,
                                       overwrite     = FALSE,
                                       dry_run       = DRY_RUN,
                                       opt_in_ids    = AGENTIC_VTT_SESSION_IDS,
                                       .vault_path   = VAULT_PATH,
                                       .dry_run_path = DRY_RUN_PATH) {
  rel <- session_note_relative_path(agentic_section_id(session_id),
                                    opt_in_ids = opt_in_ids)
  write_note(content       = markdown,
             relative_path = rel,
             dry_run       = dry_run,
             overwrite     = overwrite,
             .vault_path   = .vault_path,
             .dry_run_path = .dry_run_path)
}
