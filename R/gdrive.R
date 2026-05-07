library(googledrive)
library(readr)

fetch_gdoc <- function(doc_id) {
  tmp <- tempfile(fileext = ".html")
  drive_download(
    as_id(doc_id),
    path      = tmp,
    type      = "text/html",
    overwrite = TRUE
  )
  read_file(tmp)
}

list_folder_docs <- function(folder_id) {
  files <- drive_ls(as_id(folder_id), type = "document")
  if (nrow(files) == 0)
    return(data.frame(id = character(), name = character(),
                      episode_id = character(), doc_type = character(),
                      stringsAsFactors = FALSE))

  ep_pattern <- "[Ss](\\d+)\\s*[eE](\\d+)"
  matches    <- regmatches(files$name, regexec(ep_pattern, files$name, perl = TRUE))

  episode_ids <- vapply(matches, function(m) {
    if (length(m) < 3L || !nzchar(m[[1L]])) return(NA_character_)
    paste0("S", m[[2L]], "e", m[[3L]])
  }, character(1L))

  data.frame(
    id         = files$id,
    name       = files$name,
    episode_id = episode_ids,
    doc_type   = ifelse(is.na(episode_ids), "multi_tab", "single"),
    stringsAsFactors = FALSE
  )
}
