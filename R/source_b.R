parse_source_b <- function(doc_text) {
  # Remove carriage returns defensively
  doc_text <- gsub("\r", "", doc_text)

  # Strip all HTML tags
  strip_html <- function(x) gsub("<[^>]+>", "", x)

  # Decode common HTML entities
  decode_entities <- function(x) {
    x <- gsub("&amp;",  "&",  x, fixed = TRUE)
    x <- gsub("&lt;",   "<",  x, fixed = TRUE)
    x <- gsub("&gt;",   ">",  x, fixed = TRUE)
    x <- gsub("&nbsp;", " ",  x, fixed = TRUE)
    x <- gsub("&#39;",  "'",  x, fixed = TRUE)
    x <- gsub("&quot;", '"',  x, fixed = TRUE)
    x <- gsub("&rsquo;", "\u2019", x, fixed = TRUE)
    x <- gsub("&lsquo;", "\u2018", x, fixed = TRUE)
    x <- gsub("&rdquo;", "\u201d", x, fixed = TRUE)
    x <- gsub("&ldquo;", "\u201c", x, fixed = TRUE)
    x <- gsub("&mdash;", "\u2014", x, fixed = TRUE)
    x <- gsub("&ndash;", "\u2013", x, fixed = TRUE)
    # Numeric decimal entities e.g. &#160;
    x <- gsub("&#(\\d+);", "\\1", x, perl = TRUE)
    x
  }

  # Extract canonical episode ID from a section's leading <p class="title"> tag
  extract_episode_id <- function(section) {
    m <- regmatches(section, regexpr('<p class="title"[^>]*>.*?</p>', section, perl = TRUE))
    if (length(m) == 0) return(NA_character_)
    heading_text <- trimws(strip_html(m))

    # Match S<n>[optional space][eE]<n> anywhere in the heading text
    ep_match <- regmatches(
      heading_text,
      regexpr("[Ss](\\d+)\\s*[eE](\\d+)", heading_text, perl = TRUE)
    )
    if (length(ep_match) == 0 || identical(ep_match, character(0))) return(NA_character_)

    # Normalise to canonical slug: S<season>e<episode>
    parts <- regmatches(ep_match, regexec("[Ss](\\d+)\\s*[eE](\\d+)", ep_match, perl = TRUE))[[1]]
    paste0("S", parts[2], "e", parts[3])
  }

  # Split on <p class="title"> boundaries using a sentinel to avoid lookahead issues
  SENTINEL <- "<<<EPISODE_BOUNDARY>>>"
  doc_text <- gsub('<p class="title"', paste0(SENTINEL, '<p class="title"'), doc_text, fixed = TRUE)
  sections <- strsplit(doc_text, SENTINEL, fixed = TRUE)[[1]]

  # Drop any leading fragment before the first title tag
  is_title <- grepl('<p class="title"', sections, fixed = TRUE)
  sections <- sections[is_title]

  if (length(sections) == 0) return(list())

  # Extract episode IDs; NA means non-episode section (e.g. "Tab 7")
  ids <- vapply(sections, extract_episode_id, character(1), USE.NAMES = FALSE)

  # Keep only sections with a valid episode ID
  valid <- !is.na(ids)
  sections <- sections[valid]
  ids      <- ids[valid]

  if (length(sections) == 0) return(list())

  # Deduplicate: if two adjacent sections share the same episode ID, keep only the first
  keep <- c(TRUE, ids[-1] != ids[-length(ids)])
  sections <- sections[keep]
  ids      <- ids[keep]

  # Process each section: remove heading tag, strip HTML, decode entities, trim
  contents <- lapply(sections, function(sec) {
    sec   <- sub('<p class="title"[^>]*>.*?</p>', '', sec, perl = TRUE)
    plain <- strip_html(sec)
    plain <- decode_entities(plain)
    plain <- gsub("\r", "", plain)
    trimws(plain)
  })

  stats::setNames(contents, ids)
}
