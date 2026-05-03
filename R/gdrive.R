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
