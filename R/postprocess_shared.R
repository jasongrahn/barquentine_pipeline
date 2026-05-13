# Shared post-processing primitives used by both the agentic chain
# (R/agentic_postprocess.R) and the entity chain (R/source_c.R). One source
# of truth so cross-pipeline parity is mechanical rather than aspirational.

# Near-typo slug collapse via union-find on edit distance. Takes a character
# vector of slugs and returns a same-length vector where each element is the
# representative slug for that input's cluster ("longer slug wins" per
# cluster). Two slugs collapse iff
#   - min(nchar(a), nchar(b)) >= min_len, AND
#   - adist(a, b) / min(nchar(a), nchar(b)) <= ratio
# Short slugs (e.g. "ship" vs "shop") are rejected by the length floor so
# we don't aggressively merge them. A 9-char vs 10-char near-typo
# (astro_sea / astral_sea, dist 2 / 9 ~= 0.22) clusters cleanly.
collapse_near_match_slugs <- function(slugs,
                                      ratio   = 0.25,
                                      min_len = 6L) {
  n <- length(slugs)
  if (n < 2L) return(slugs)

  d <- utils::adist(slugs)
  diag(d) <- NA_integer_

  parent <- seq_len(n)
  find <- function(i) {
    while (parent[i] != i) i <- parent[i]
    i
  }
  union_ <- function(i, j) {
    ri <- find(i); rj <- find(j)
    if (ri != rj) parent[ri] <<- rj
  }

  for (i in seq_len(n - 1L)) {
    for (j in (i + 1L):n) {
      shorter <- min(nchar(slugs[i]), nchar(slugs[j]))
      if (shorter < min_len) next
      if (d[i, j] / shorter <= ratio) union_(i, j)
    }
  }

  cluster_id <- vapply(seq_len(n), find, integer(1))

  reps <- character(n)
  for (cid in unique(cluster_id)) {
    members      <- which(cluster_id == cid)
    member_slugs <- slugs[members]
    reps[members] <- member_slugs[order(-nchar(member_slugs))][1]
  }
  reps
}
