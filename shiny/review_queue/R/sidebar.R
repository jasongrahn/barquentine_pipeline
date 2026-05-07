.similar_ids <- function(section_id, all_ids) {
  candidates <- setdiff(all_ids, section_id)
  if (!length(candidates) || nchar(section_id) < 3L) return(character(0))
  candidates <- candidates[nchar(candidates) >= 3L]
  if (!length(candidates)) return(character(0))
  section_id_lc <- tolower(section_id)
  candidates_lc <- tolower(candidates)
  # prefix/suffix OR substring containment — catches "captain" / "the_captain"
  prefix_match    <- startsWith(section_id_lc, candidates_lc) | startsWith(candidates_lc, section_id_lc)
  substring_match <- grepl(section_id_lc, candidates_lc, fixed = TRUE) |
                     vapply(candidates_lc, grepl, logical(1), x = section_id_lc, fixed = TRUE)
  candidates[prefix_match | substring_match]
}

render_sidebar <- function(queue_df, selected_id, total_count = NULL) {
  if (is.null(queue_df) || nrow(queue_df) == 0)
    return(p("No entity notes pending.", style = "color: #888; font-size: 0.9em;"))

  sections <- list(
    list(key = "__failed__", label = "Failed Generation", icon = "\U1F534",
         filter = function(df) df[!is.na(df$status) & df$status == "generation_failed", ]),
    list(key = "session",   label = "Sessions",  icon = "\U1F4CB",
         filter = function(df) df[!is.na(df$note_type) & df$note_type == "session" &
                                    !df$status %in% c("generation_failed"), ]),
    list(key = "npc",       label = "NPCs",      icon = "\U1F465",
         filter = function(df) df[!is.na(df$note_type) & df$note_type == "npc" &
                                    !df$status %in% c("generation_failed"), ]),
    list(key = "location",  label = "Locations", icon = "\U1F4CD",
         filter = function(df) df[!is.na(df$note_type) & df$note_type == "location" &
                                    !df$status %in% c("generation_failed"), ]),
    list(key = "faction",   label = "Factions",  icon = "\U2691",
         filter = function(df) df[!is.na(df$note_type) & df$note_type == "faction" &
                                    !df$status %in% c("generation_failed"), ])
  )

  section_tags <- lapply(sections, function(sec) {
    rows <- sec$filter(queue_df)
    if (nrow(rows) == 0) return(NULL)

    entries <- lapply(seq_len(nrow(rows)), function(i) {
      row       <- rows[i, ]
      is_active <- !is.null(selected_id) && !is.na(selected_id) &&
                   row$section_id == selected_id

      display_name <- if (!is.na(row$entity_name) && nzchar(row$entity_name))
        row$entity_name else row$section_id

      badge <- if (!is.na(row$chunk_count) && !is.null(row$chunk_count))
        tags$span(style = "color:#999;font-size:0.78em;margin-left:3px;",
                  paste0("\u00d7", row$chunk_count))
      else NULL

      flag <- if (!is.na(row$status) && row$status == "critic_rejected")
        tags$span(style = "color:#dc3545;margin-left:3px;", "\u274C",
                  tags$span(style = "font-size:0.75em;", " Critic rejected"))
      else if (!is.na(row$verdict) && row$verdict == "flagged")
        tags$span(style = "color:#fd7e14;margin-left:3px;", "\u26A0")
      else if (!is.na(row$status) && row$status == "generation_failed")
        tags$span(style = "color:#dc3545;margin-left:3px;", "\u274C")
      else NULL

      sims <- .similar_ids(row$section_id, queue_df$section_id)
      sim_hint <- if (length(sims) > 0)
        tags$div(style = "font-size:0.75em;color:#fd7e14;padding-left:4px;",
                 paste0("\u26A0 Similar: ", paste(sims, collapse = ", ")))
      else NULL

      tags$div(
        style = paste0(
          "padding: 3px 4px; border-radius: 3px; cursor: pointer; ",
          if (is_active) "background:#dbeafe;font-weight:600;" else "hover:background:#f3f4f6;"
        ),
        actionLink(
          inputId = paste0("sel_", row$section_id),
          label   = tagList(display_name, flag, badge)
        ),
        sim_hint
      )
    })

    tags$details(
      open = NA,
      style = "margin-bottom: 6px;",
      tags$summary(
        style = "cursor:pointer;font-weight:bold;padding:4px 0;user-select:none;",
        paste0(sec$icon, " ", sec$label, " (", nrow(rows), ")")
      ),
      tagList(entries)
    )
  })

  tagList(Filter(Negate(is.null), section_tags))
}
