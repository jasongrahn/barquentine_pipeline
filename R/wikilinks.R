library(fs)
library(yaml)
library(stringr)
library(purrr)

build_alias_registry <- function(vault_path = VAULT_PATH) {
  registry <- list()

  for (subdir in c("pcs", "npcs")) {
    dir_path <- path(vault_path, subdir)
    if (!dir_exists(dir_path)) next

    md_files <- dir_ls(dir_path, glob = "*.md")
    for (f in md_files) {
      fm <- .read_frontmatter(f)
      if (is.null(fm) || is.null(fm$name)) next

      slug    <- fm$name
      display <- fm$display_as %||% NULL
      entry   <- list(slug = slug, display = display)

      # Register the canonical name itself
      registry[[slug]] <- entry

      # Register every alias variant
      for (alias in fm$aliases) {
        registry[[alias]] <- entry
      }
    }
  }

  registry
}

resolve_alias <- function(name, registry) {
  registry[[name]]
}

make_wikilink <- function(slug, display = NULL) {
  if (is.null(display)) {
    paste0("[[", slug, "]]")
  } else {
    paste0("[[", slug, "|", display, "]]")
  }
}

resolve_wikilink <- function(name, registry) {
  entry <- resolve_alias(name, registry)
  if (is.null(entry)) return(NULL)
  make_wikilink(entry$slug, entry$display)
}

replace_entity_mentions <- function(text, registry) {
  if (length(registry) == 0) return(text)

  # Longest names first — so "the Captain" wins over "Captain" in the alternation
  names_sorted <- names(registry)[order(nchar(names(registry)), decreasing = TRUE)]

  # Combined alternation: all names found in a single scan so a freshly created
  # [[wikilink]] cannot be matched by a shorter name that comes later.
  pattern <- paste(str_escape(names_sorted), collapse = "|")

  # Only replace in unprotected segments (outside existing [[...]] wikilinks).
  # Replace right-to-left so earlier positions remain valid after each substitution.
  parts <- .split_on_wikilinks(text)

  parts <- map(parts, function(part) {
    if (part$protected) return(part)
    content <- part$text
    locs    <- str_locate_all(content, pattern)[[1]]
    for (i in rev(seq_len(nrow(locs)))) {
      m    <- str_sub(content, locs[i, "start"], locs[i, "end"])
      link <- resolve_wikilink(m, registry)
      if (!is.null(link)) str_sub(content, locs[i, "start"], locs[i, "end"]) <- link
    }
    part$text <- content
    part
  })

  paste(map_chr(parts, "text"), collapse = "")
}

# Internal: read YAML frontmatter from a .md file into a list
.read_frontmatter <- function(path) {
  text <- tryCatch(read_file(path), error = function(e) NULL)
  if (is.null(text)) return(NULL)
  m <- str_match(text, "(?s)^---\n(.*?)\n---")
  if (is.na(m[1, 1])) return(NULL)
  tryCatch(read_yaml(text = m[1, 2]), error = function(e) NULL)
}

# Internal: split text into segments, marking [[wikilinks]] as protected
.split_on_wikilinks <- function(text) {
  matches <- str_locate_all(text, "\\[\\[[^\\]]+\\]\\]")[[1]]
  if (nrow(matches) == 0) return(list(list(text = text, protected = FALSE)))

  parts  <- list()
  cursor <- 1L

  for (i in seq_len(nrow(matches))) {
    start <- matches[i, "start"]
    end   <- matches[i, "end"]
    if (cursor < start) {
      parts <- c(parts, list(list(text = substr(text, cursor, start - 1L), protected = FALSE)))
    }
    parts  <- c(parts, list(list(text = substr(text, start, end), protected = TRUE)))
    cursor <- end + 1L
  }

  if (cursor <= nchar(text)) {
    parts <- c(parts, list(list(text = substr(text, cursor, nchar(text)), protected = FALSE)))
  }

  parts
}

# Internal null-coalescing operator (base R does not have one)
`%||%` <- function(x, y) if (!is.null(x)) x else y
