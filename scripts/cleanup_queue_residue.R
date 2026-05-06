# One-shot script: remove residual garbage and orphan rows from review_queue/queue.csv.
# Run once from the project root after Phase 4.5 ships.
# Future runs are protected by the ingestion-stage .is_garbage_name() filter.
#
# Usage: Rscript scripts/cleanup_queue_residue.R

library(readr)
library(stringr)

source("R/source_c.R")  # for .is_garbage_name(), make_slug()
source("R/queue.R")     # for .nc(), .fill_missing_columns()

csv_path <- "review_queue/queue.csv"

if (!file.exists(csv_path)) {
  cat("No queue file found at", csv_path, "— nothing to clean.\n")
  quit(status = 0)
}

df      <- read_csv(csv_path, show_col_types = FALSE)
df      <- .fill_missing_columns(df)
n_before <- nrow(df)

is_unresolved <- df$status %in% c("pending", "generation_failed", "critic_rejected")
entity_names  <- ifelse(is.na(df$entity_name), df$section_id, df$entity_name)
is_garbage    <- vapply(entity_names, .is_garbage_name, logical(1))
is_orphan     <- is_unresolved &
  (is.na(df$draft) | !nzchar(trimws(ifelse(is.na(df$draft), "", df$draft))))

to_drop   <- (is_unresolved & is_garbage) | is_orphan
df_clean  <- df[!to_drop, ]

write_csv(df_clean, csv_path)

n_garbage <- sum(is_unresolved & is_garbage)
n_orphan  <- sum(is_orphan & !(is_unresolved & is_garbage))
cat(sprintf(
  "Before: %d rows | Dropped: %d garbage + %d orphan = %d | After: %d rows\n",
  n_before, n_garbage, n_orphan, n_garbage + n_orphan, nrow(df_clean)
))
