# Gemma4 Phase A+B — What Happened
Branch: `feature/gemma4-optimization` @ 65d661c

## Why
Wet run #2 (2026-05-13): gemma4 produces wrong/empty citation indices under Ollama `format=` constrained decoding. Plan: `docs/phase_gemma4_optimization.md`. Phase C is next.

---

## Phase A findings

**Thinking mode:**
- `think=TRUE` via `/api/chat` → silently ignored
- `<|think|>` in system prompt → no effect
- `/api/generate` raw + `<start_of_turn>model\n<think>\n` → works on short clean text
- 3000w VTT → 90s timeout; 6873w VTT → infinite loop
- **Not used for entity extraction.** `ollama_generate_thinking()` exists in `R/ollama.R` for future use.

**Prompts:** already lean. Claude-isms removed in Phase B (see below).

---

## Phase B changes

| What | Before | After |
|---|---|---|
| `AGENTIC_ENTITY_PASSAGE_WORD_LIMIT` | 4000L | 8000L |
| `agents/wiki_skills/05-08/system.md` | `##` headers, Claude phrasing | direct field listings, explicit array vs object types |
| `agents/wiki_skills/05-08/user_template.md` | duplicate citation rule | removed duplication |
| `R/ollama.R` | — | added `ollama_generate_thinking()` (unused in pipeline) |
| `R/source_c.R` | `extract_relevant_sentences()` canonical-name only; `entity_aliases` not populated | aliases param added; alias-aware windowing; `rec$entity_aliases` set from `pc_alias` rows in protected_entities.csv |
| `tests/testthat/test-agentic_entity_extract.R` | stubs `.call_ollama_skill` | stubs `ollama_generate` |

**Why `format=` still on:** without it, gemma4 outputs markdown prose, ignores JSON instructions entirely. Constrained decoding stays until Phase C.

**Basil test (the hard case):**
- Alias-aware windowing: 6873w → 2974w fed to model
- No timeout, extraction returns content
- Still: wrong gender, "Librarian" hallucinated alias, `line: {}` instead of integer
- These are Phase C's problem (APS will flag ungrounded claims)

---

## Known remaining issues going into Phase C

| Issue | Cause |
|---|---|
| `line: {}` in every field | Gemma4 constrained decoding outputs empty object for null |
| `aliases` sometimes string not array | Same constrained decoding bug |
| Identity confusion (wrong character, wrong gender) | Dense VTT; model conflates entities |
| Hallucinated aliases ("Librarian", "High Sorcerer") | Context pollution from other characters in passages |

All four are addressed by APS grounding: propositions extracted from source → ungrounded claims flagged by string match.

---

## File inventory

- `R/ollama.R` — `ollama_generate_thinking()` added
- `R/agentic_entity_extract.R` — whitespace only (generation call unchanged)
- `R/source_c.R` — alias-aware windowing + `entity_aliases` population
- `config.R` — word limit 4000 → 8000
- `agents/wiki_skills/05-08/system.md` — rewritten
- `agents/wiki_skills/05-08/user_template.md` — simplified
- `tests/testthat/test-agentic_entity_extract.R` — stubs updated
