.strip_html <- function(x) gsub("<[^>]+>", "", x)

.decode_entities <- function(x) {
  x <- gsub("&amp;",   "&",        x, fixed = TRUE)
  x <- gsub("&lt;",    "<",        x, fixed = TRUE)
  x <- gsub("&gt;",    ">",        x, fixed = TRUE)
  x <- gsub("&nbsp;",  " ",        x, fixed = TRUE)
  x <- gsub("&#39;",   "'",        x, fixed = TRUE)
  x <- gsub("&quot;",  '"',        x, fixed = TRUE)
  x <- gsub("&rsquo;", "\u2019",   x, fixed = TRUE)
  x <- gsub("&lsquo;", "\u2018",   x, fixed = TRUE)
  x <- gsub("&rdquo;", "\u201d",   x, fixed = TRUE)
  x <- gsub("&ldquo;", "\u201c",   x, fixed = TRUE)
  x <- gsub("&mdash;", "\u2014",   x, fixed = TRUE)
  x <- gsub("&ndash;", "\u2013",   x, fixed = TRUE)
  x <- gsub("&#(\\d+);", "\\1",    x, perl = TRUE)
  x
}

.clean_html_to_text <- function(html) {
  plain <- .strip_html(html)
  plain <- .decode_entities(plain)
  plain <- gsub("\r", "", plain)
  trimws(plain)
}

parse_source_b <- function(doc_text) {
  doc_text <- gsub("\r", "", doc_text)

  extract_episode_id <- function(section) {
    m <- regmatches(section, regexpr('<p class="title"[^>]*>.*?</p>', section, perl = TRUE))
    if (length(m) == 0) return(NA_character_)
    heading_text <- trimws(.strip_html(m))
    ep_match <- regmatches(
      heading_text,
      regexpr("[Ss](\\d+)\\s*[eE](\\d+)", heading_text, perl = TRUE)
    )
    if (length(ep_match) == 0 || identical(ep_match, character(0))) return(NA_character_)
    parts <- regmatches(ep_match, regexec("[Ss](\\d+)\\s*[eE](\\d+)", ep_match, perl = TRUE))[[1]]
    paste0("S", parts[2], "e", parts[3])
  }

  SENTINEL <- "<<<EPISODE_BOUNDARY>>>"
  doc_text <- gsub('<p class="title"', paste0(SENTINEL, '<p class="title"'), doc_text, fixed = TRUE)
  sections <- strsplit(doc_text, SENTINEL, fixed = TRUE)[[1]]

  is_title <- grepl('<p class="title"', sections, fixed = TRUE)
  sections <- sections[is_title]

  if (length(sections) == 0) return(list())

  ids <- vapply(sections, extract_episode_id, character(1), USE.NAMES = FALSE)

  valid    <- !is.na(ids)
  sections <- sections[valid]
  ids      <- ids[valid]

  if (length(sections) == 0) return(list())

  keep     <- c(TRUE, ids[-1] != ids[-length(ids)])
  sections <- sections[keep]
  ids      <- ids[keep]

  contents <- lapply(sections, function(sec) {
    sec <- sub('<p class="title"[^>]*>.*?</p>', '', sec, perl = TRUE)
    .clean_html_to_text(sec)
  })

  stats::setNames(contents, ids)
}

parse_single_episode_doc <- function(html, episode_id) {
  stats::setNames(list(.clean_html_to_text(html)), episode_id)
}

fetch_all_episode_docs <- function(folder_id,
                                   registry_path = DOC_REGISTRY_PATH,
                                   vault_path    = VAULT_PATH) {
  docs <- list_folder_docs(folder_id)
  message(sprintf("fetch_all_episode_docs: found %d doc(s) in folder", nrow(docs)))

  reg_cols <- c("episode_id", "doc_id", "filename", "doc_type", "fetched_at")
  registry <- if (file.exists(registry_path)) {
    read_csv(registry_path, col_types = cols(.default = "c"), show_col_types = FALSE)
  } else {
    as.data.frame(matrix(ncol = length(reg_cols), nrow = 0L,
                          dimnames = list(NULL, reg_cols)),
                  stringsAsFactors = FALSE)
  }

  already_fetched <- registry$episode_id

  sessions_dir   <- file.path(vault_path, "sessions")
  already_in_vault <- if (dir.exists(sessions_dir)) {
    tools::file_path_sans_ext(basename(list.files(sessions_dir, pattern = "\\.md$")))
  } else character(0)

  processed <- union(already_fetched, already_in_vault)

  all_sections <- list()
  new_reg_rows <- list()

  for (i in seq_len(nrow(docs))) {
    row <- docs[i, ]

    if (row$doc_type == "single") {
      ep_id <- row$episode_id
      if (ep_id %in% processed) {
        message(sprintf("  [skip] %s already processed", ep_id))
        next
      }
      message(sprintf("  [fetch] single doc: %s (%s)", row$name, ep_id))
      html     <- fetch_gdoc(row$id)
      sections <- parse_single_episode_doc(html, ep_id)
      new_reg_rows[[length(new_reg_rows) + 1L]] <- data.frame(
        episode_id = ep_id, doc_id = row$id, filename = row$name,
        doc_type = "single", fetched_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
        stringsAsFactors = FALSE
      )
    } else {
      message(sprintf("  [fetch] multi-tab doc: %s", row$name))
      html     <- fetch_gdoc(row$id)
      sections <- parse_source_b(html)
      keep_ids <- setdiff(names(sections), processed)
      skipped  <- setdiff(names(sections), keep_ids)
      if (length(skipped))
        message(sprintf("  [skip] already processed: %s", paste(skipped, collapse = ", ")))
      sections <- sections[keep_ids]
      ts <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
      for (ep_id in keep_ids) {
        new_reg_rows[[length(new_reg_rows) + 1L]] <- data.frame(
          episode_id = ep_id, doc_id = row$id, filename = row$name,
          doc_type = "multi_tab", fetched_at = ts,
          stringsAsFactors = FALSE
        )
      }
    }

    all_sections <- c(all_sections, sections)
  }

  if (length(new_reg_rows) > 0L) {
    new_df  <- do.call(rbind, new_reg_rows)
    updated <- rbind(as.data.frame(registry[, reg_cols, drop = FALSE],
                                   stringsAsFactors = FALSE), new_df)
    write_csv(updated, registry_path)
    message(sprintf("doc_registry: added %d new entries to %s", nrow(new_df), registry_path))
  }

  message(sprintf("fetch_all_episode_docs: returning %d episode section(s): %s",
                  length(all_sections),
                  if (length(all_sections)) paste(names(all_sections), collapse = ", ") else "none"))

  all_sections
}
