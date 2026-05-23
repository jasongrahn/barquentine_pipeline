# =============================================================================
# config.R — Barquentine Wiki Pipeline Configuration
# =============================================================================
# All environment-specific values live here.
# ANTHROPIC_API_KEY must be set in ~/.Renviron — never hardcode it here.
# This file is safe to commit; it contains no secrets.
# =============================================================================

# -----------------------------------------------------------------------------
# Vault (barquentine_wiki repo — separate from this pipeline repo)
# -----------------------------------------------------------------------------
VAULT_PATH <- "/Users/jasongrahn/R-projects/barquentine_wiki/BarquentineWiki"

# -----------------------------------------------------------------------------
# NAS — VTT transcript files
# -----------------------------------------------------------------------------
# Mount via Finder → Go → Connect to Server → smb://LS220D43E.local/share
# Files live directly in /Volumes/share/videos/ with no subdirectory
NAS_MOUNT     <- "/Volumes/share/videos"
VTT_EXTENSION <- "\\.vtt$"          # regex pattern for listing VTT files
VTT_CUTOVER   <- "s02e34"           # first episode with a VTT file (zero-padded format)

# -----------------------------------------------------------------------------
# Google Drive
# -----------------------------------------------------------------------------
# Auth handled by googledrive package — run drive_auth() once interactively
# Token is cached in OS keychain; subsequent runs are non-interactive
EPISODE_NOTES_FOLDER_ID <- "1MMsNXsUvjaTHra48DuPiuVnApi5s9mjD"
DOC_REGISTRY_PATH       <- "config/doc_registry.csv"

# -----------------------------------------------------------------------------
# Claude API
# -----------------------------------------------------------------------------
# Key lives in ~/.Renviron:  ANTHROPIC_API_KEY=sk-ant-...
# Add with: usethis::edit_r_environ()
CLAUDE_MODEL       <- "claude-sonnet-4-6"
CLAUDE_MAX_TOKENS  <- 2000
CLAUDE_API_VERSION <- "2023-06-01"

# -----------------------------------------------------------------------------
# Ollama (local — no auth required)
# -----------------------------------------------------------------------------
OLLAMA_BASE_URL <- "http://localhost:11434"
OLLAMA_MODEL    <- "gemma4:latest"    # generator — largest/newest local model
OLLAMA_TIMEOUT  <- 90                 # seconds before giving up on a chunk; run_pipeline() retries at pipeline level

# Entity note generation needs more tokens than session notes: longer source
# passages mean more thinking budget consumed before producing actual output.
ENTITY_NUM_PREDICT     <- 800L    # think=FALSE removes thinking overhead; 800 is sufficient
MIN_ENTITY_CHUNK_COUNT <- 4L      # drop entities appearing in fewer distinct chunks
ENTITY_EXCLUSIONS_PATH <- "config/entity_exclusions.csv"
PROTECTED_ENTITIES_PATH <- "config/protected_entities.csv"
ENTITY_ALIASES_PATH    <- "config/entity_aliases.csv"

# -----------------------------------------------------------------------------
# VTT chunking (for Ollama entity-spotting pass)
# -----------------------------------------------------------------------------
CHUNK_SIZE_WORDS    <- 1500           # target words per chunk
CHUNK_OVERLAP_WORDS <- 150            # overlap between chunks to catch boundary entities

# -----------------------------------------------------------------------------
# Phase 2 — Critic / routing / training
# -----------------------------------------------------------------------------
OLLAMA_CRITIC_MODEL <- "llama3.1:8b"  # critic — structured JSON output, reliable under load

GENERATOR_SYSTEM_PROMPT <- paste(
  "You are a precise structured data extractor for a D&D campaign wiki.",
  "Follow all instructions exactly.",
  "Do not infer or fabricate any information not present in the source text."
)

CRITIC_AUTO_APPROVE_THRESHOLD <- Inf    # Inf = auto-approve disabled; all notes go to review queue
CRITIC_ESCALATE_THRESHOLD     <- 0.60   # flagged + < this → Claude tiebreak
CRITIC_REJECT_THRESHOLD       <- 0.95   # rejected + >= this → hide Approve buttons in UI
CRITIC_FLAG_THRESHOLD         <- 0.50   # confidence < this → escalate to Claude
CRITIC_CONTEXT_WORD_LIMIT     <- 800    # sections above this → Claude critic

REVIEW_QUEUE_PATH  <- "review_queue"
TRAINING_DATA_PATH <- "training_data"

# -----------------------------------------------------------------------------
# Pipeline state
# -----------------------------------------------------------------------------
# Update CURRENT_SESSION before each run
CURRENT_SESSION <- "s02e36"          # ← update this each session (s01e01 zero-padded format)

# Set TRUE to write to /tmp/barquentine-preview/ instead of vault
# Always do a dry run first when testing new extraction prompts
DRY_RUN         <- TRUE              # ← flip to FALSE when ready for live run
DRY_RUN_PATH    <- "/tmp/barquentine-preview"

# -----------------------------------------------------------------------------
# Recursive critic loop
# -----------------------------------------------------------------------------
DRAFT_MAX_ITERATIONS          <- 6L   # generator→critic loops before Claude escalation
DRAFT_PARSE_RETRY_BUDGET      <- 2L   # parse_error retries that do NOT count toward the cap
PROCESS_ONE_SESSION           <- FALSE # TEMP for s02e09 validation pass; restore to TRUE after
OLLAMA_TIMEOUT_BACKOFF_SECONDS <- 30L  # sleep after a section that had an Ollama timeout

# -----------------------------------------------------------------------------
# Regeneration queue
# -----------------------------------------------------------------------------
REGEN_MAX_COUNT <- 3L                          # hard stop after this many regens per item
REGEN_LOCK_FILE <- "review_queue/.regen.lock"  # sentinel touched by bg job; relative to project root

# VTT episodes to process in Phase 3. NULL = all confirmed episodes.
# Set to a character vector to limit the run, e.g. c("S2e34") for one episode.
ACTIVE_EPISODES <- NULL

# -----------------------------------------------------------------------------
# Agentic VTT extraction (Phase 0 — session-notes-only)
# -----------------------------------------------------------------------------
# Per-session opt-in. Episodes in this vector run the new agentic extraction
# flow: per-chunk schema-enforced extraction + R-assembled markdown + a single
# LLM Synopsis call. For these episodes the Google-Doc prep flow (source_b)
# redirects its output to vault/dm_prep/<id>.md so the VTT recap remains
# canonical at vault/sessions/<id>.md.
# Episodes NOT in this vector run the existing critic-loop path unchanged.
AGENTIC_VTT_SESSION_IDS  <- c("s02e34", "s02e35", "s02e36", "s02e37")

# --- Phase 4.2: agentic entity-note chain opt-in --------------------------
# Add episode IDs here to run entity notes through schema-enforced extraction
# instead of the legacy critic-loop path. Start empty; Phase 4.1 adds first ID.
AGENTIC_ENTITY_SESSION_IDS        <- c("s02e36", "s02e37")
AGENTIC_ENTITY_SCHEMA_VERSION     <- "v2"
AGENTIC_ENTITY_PASSAGE_WORD_LIMIT <- 8000L
AGENTIC_ENTITY_MODEL              <- OLLAMA_MODEL

AGENTIC_CHUNK_SIZE_LINES <- 50L                                # dialogue lines per chunk (~800-1000 words)
AGENTIC_EVENT_KEEP_N     <- 18L                                # events kept after prune_events scoring
AGENTIC_DIALOGUE_KEEP_N  <- 8L                                 # significant-dialogue cap
AGENTIC_OUTPUT_DIR       <- "review_queue/agentic_intermediates"
