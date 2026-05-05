# Entity Pipeline — Performance Analysis and Options

## Problem Statement

The Phase 3 entity pipeline (VTT → entity notes) produces no usable output. The generator runs but returns empty strings for all entities, and runtime will be too slow even once that is fixed.

**Observed runtime (S2e34 only, DRY_RUN=TRUE, `num_predict=800`):**

| Stage | Observed time | Output |
|---|---|---|
| `vtt_entities` — entity spotting (1 VTT, llama3.1:8b) | ~2.5 min | 62 entities spotted |
| `entity_draft` — note generation (62 × ~1.2 min each) | **17m 42s** | `""` (empty string) for all 62 |
| `entity_verdict` — critic (62 × ~8.5s avg) | **8m 48s** | ran on empty drafts; all enqueued or skipped |
| `entity_dispatched` | ~131ms | nothing written to vault or queue |
| **Total for S2e34** | **~28 min** | **zero useful notes produced** |

**Why the empty output matters:** the entity_draft branches call Ollama successfully (~1.2 min each) but receive an empty string back. 53 bytes serialized = `""`, not NULL. Because `review_note()` only guards against `is.null(draft)`, the critic still runs against the empty draft — wasting another ~8.5 seconds per entity — before everything is quietly enqueued or skipped with no vault output.

**Projected runtime if empty-output is fixed with higher `num_predict`:** at `num_predict=2000` each entity_draft call is expected to take 2–3 min (not validated — run was killed before completion). That gives ~155 min for drafts + ~9 min for critic = **~2.75 hours for one episode, ~20 hours for all 7**. This is not viable for a weekly post-session run.

---

## Root Causes

### 1. Over-extraction at the entity-spotting stage

62 entities were spotted from S2e34 (a single VTT session, ~40 chunks of 1500 words each). Entity spotting runs per-chunk via llama3.1:8b; the same NPC mentioned across 20 chunks is deduplicated to 1 record, but any name appearing in even a single chunk becomes a draft candidate. Many of the 62 are:
- Minor one-off NPCs mentioned in passing (e.g., a guard name never used again)
- Duplicate surface forms not caught by alias resolution
- Entities that appear in only 1 of ~40 chunks — statistically noise

The entity spotter has no minimum-frequency filter. Every name from any chunk becomes a candidate for a full note generation pass.

### 2. Source passages are too long for the generator

Each entity accumulates up to 5+ source passages, each being the full 1500-word chunk window it was spotted in. Combined context sent to qwen3.5:9b can be 7,500–43,000 chars per entity.

qwen3.5:9b uses thinking mode. With `num_predict = 800`, the model exhausts its token budget on `<think>...</think>` output before producing any actual content. Ollama returns an empty string in `message.content`. The pipeline stores this as `""` (53 bytes), which `review_note()` does not guard against (it only checks `is.null(draft)`), so the critic runs anyway before the note is quietly discarded.

A stopgap guard was added to `generate_entity_note()` to convert `""` → NULL (so the critic skips it cleanly), and `ENTITY_NUM_PREDICT` was raised to 2000L. Neither fixes the root cause: 90%+ of each passage is context the model doesn't cite; the final note typically references only a few sentences. Passing shorter, targeted excerpts is the correct fix.

### 3. One LLM call per entity, fully sequential

targets runs branches sequentially by default (`callr_function = NULL`). 62 entities × 1 Ollama call each = 62 sequential round-trips. There is no batching.

`tar_make(workers = N)` enables parallel branch execution via callr. Whether Ollama can serve concurrent requests without degrading throughput is untested — this is an open question for expert review.

---

## Options

### Option A — Minimum chunk frequency filter (quick win)

**What:** Only generate a note for entities that appear in ≥ N distinct chunks (e.g., ≥ 3).

**Where:** One filter in `aggregate_entity_passages()` before returning records.

**Expected impact:** Reduces entity count from ~62 to ~10–15 per episode. Cuts total runtime by ~75%.

**R does this cheaply:** `length(chunks) >= MIN_ENTITY_CHUNK_COUNT` — pure R, sub-millisecond.

**Tradeoff:** Misses genuinely important NPCs introduced in a single memorable scene. Threshold needs tuning.

---

### Option B — R-side passage extraction (best architectural fit)

**What:** Instead of passing entire 1500-word chunk windows to the generator, use R to extract only the sentences that directly mention the entity name (or its known aliases).

**Where:** New helper in `source_c.R`, called during `aggregate_entity_passages()`.

**Expected impact:** Reduces per-entity context from 7,500–43,000 chars to 200–1,000 chars. With shorter context, qwen3.5:9b thinking overhead drops dramatically — likely under 30 seconds per entity.

**Why R is well-suited here:** `stringr::str_extract_all()` and `str_split()` on sentence boundaries is very fast in R. This is exactly the cheap CPU text processing R excels at — no model call needed.

```r
extract_relevant_sentences <- function(passage, entity_name, window = 2L) {
  sentences <- str_split(passage, "(?<=[.!?])\\s+")[[1]]
  hits      <- which(str_detect(sentences, regex(entity_name, ignore_case = TRUE)))
  idx       <- unique(sort(c(outer(hits, seq(-window, window), "+")))  )
  idx       <- idx[idx >= 1 & idx <= length(sentences)]
  paste(sentences[idx], collapse = " ")
}
```

**Tradeoff:** Entities with non-obvious mentions (pronouns, titles) may get sparse extracts. Alias registry helps but isn't exhaustive.

---

### Option C — Combine A + B (recommended)

Apply the frequency filter first (cheap, reduces entity count), then apply sentence-window extraction to the survivors (reduces context length). Together these address both causes.

**Estimated combined runtime:** ~10–15 entities × ~30 sec each ≈ **5–8 min per episode**.

---

### Option D — Swap generator to llama3.1:8b (no thinking mode)

**What:** Use llama3.1:8b (the critic model) for entity note generation instead of qwen3.5:9b. llama3.1:8b does not have thinking mode and is reliably faster per token.

**Expected impact:** 3–4× faster per call. Known risk: note quality may be lower (llama3.1:8b is the smaller model). Already confirmed llama3.1:8b works with JSON Schema (critic role) but untested for free-text note quality.

**Tradeoff:** Violates current model role assignment (qwen3.5 = generator, llama3.1 = critic). Requires note quality validation before committing.

---

### Option E — Batch entity stubs (largest gain, most work)

**What:** Generate 5–10 entity stubs in a single Ollama call using a structured JSON output schema. One call produces multiple notes.

**Expected impact:** Reduces Ollama round-trips from N to N/5 or N/10.

**Tradeoff:** Significant prompt redesign and response parser needed. Harder to maintain per-entity routing (skip/approve/enqueue). Increases prompt complexity.

---

### Option F — targets parallel workers (low effort, unknown gain)

**What:** Run `tar_make(workers = N)` to execute pattern branches concurrently via callr.

**Where:** No code changes — one argument to `tar_make()`.

**Expected impact:** Unknown. Depends entirely on whether Ollama queues or parallelises concurrent requests. If Ollama serialises them internally, wall-clock time is unchanged. If it can serve N concurrent streams, wall-clock time scales with N.

**Tradeoff:** Untested. Risk of Ollama resource exhaustion (RAM/VRAM) under concurrent load. Should be tried before implementing batching (Option E).

---

## Recommendation

Implement **Option C (A + B)** as the first change:

1. Add `MIN_ENTITY_CHUNK_COUNT <- 3L` to `config.R`
2. Filter in `aggregate_entity_passages()`: drop entities with fewer than 3 chunk appearances
3. Add `extract_relevant_sentences()` in `source_c.R`: replace raw chunk text with sentence-window excerpts around entity mentions
4. Update `process_vtt_file()` to store sentences rather than full chunks as the passage value

This keeps the architecture intact (one note per entity, same routing logic) while making it fast enough to run weekly. Revisit Option D or E if runtime is still too long after C.

---

## Open Questions for Expert Review

1. Is the sentence-window extraction approach (Option B) the right granularity, or is there a better R-native text segmentation strategy?
2. Would a TF-IDF or keyword scoring approach work better than proximity-to-name for passage extraction?
3. Is there a batching pattern that keeps per-entity routing tractable (Option E)?
4. Can Ollama serve concurrent requests without degrading per-request throughput? If so, Option F (parallel workers) may be the cheapest fix.
