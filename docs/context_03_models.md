# Context 03 — Model Roles

Always read `config.R` for current bindings. Never hardcode model names.

→ Full evaluation + swap rationale: `docs/architecture_llm_evaluation.md`

---

## Current assignments

| Variable | Model | Role |
|---|---|---|
| `OLLAMA_MODEL` | `gemma4:latest` | Generator — session/entity note drafting (legacy paths); also drives `AGENTIC_ENTITY_MODEL` for schema-enforced entity extraction (Phase 4.2) |
| `OLLAMA_CRITIC_MODEL` | `llama3.1:8b` | Critic only — JSON structured fact-check via `format` schema; never used in agentic entity chain |
| `AGENTIC_ENTITY_MODEL` | defaults to `OLLAMA_MODEL` | Entity extraction in agentic chain; set separately in config.R if you want to split |
| Claude (`claude-sonnet-4-6`) | Escalation only | Fires when source > 800 words OR flagged + confidence < 0.60. **API credits exhausted 2026-05-13 — escalation paths will not fire until replenished.** |

---

## Why gemma4 as generator

gemma4:latest at ~9.6GB is the largest local model (12B parameters at Q6). Newer training than qwen3.5:9b; better instruction following on noisy VTT transcripts; handles garbled speaker attribution better. Phase F validation (wet runs #1–7) confirmed identity confusion resolved with vault-note anchor injection.

## Why llama3.1:8b as critic

- qwen3.5:9b + `think=FALSE` + `format=` is **silently broken** (Ollama bug #14645) — drops to empty structured output
- llama3.1:8b does **not** support thinking mode — passing `think=TRUE` causes 131-byte empty responses. Always pass `think=FALSE` or leave `NULL`
- Critic only needs to route (signal) not gate (write) — `CRITIC_AUTO_APPROVE_THRESHOLD = Inf` means no local model ever auto-approves vault writes
- llama3.1:8b is adequate as a reviewer assistant (triage hints), not required to be a gatekeeper

## Why auto-approve is disabled

Local model confidence scores are **not calibrated probabilities**. Ollama constrained decoding produces a JSON-valid number, not a reliable confidence estimate. Setting `CRITIC_AUTO_APPROVE_THRESHOLD = Inf` eliminates the risk of false-approves writing bad notes to the vault. All notes pass through human review regardless of critic verdict.

---

## Known limitations

| Model | Known issue |
|---|---|
| `llama3.1:8b` | No thinking mode; passes `think=NULL` always |
| `gemma4:latest` | With thin passages, generates meta-commentary instead of null fields — mitigated by "do not explain why empty, return null" instruction in prompts |
| `gemma4:latest` | `required=character(0)` in schema lets model emit `{}` → NULL abort; always include ≥1 required field |
| Claude escalation | Credits exhausted; escalation paths compile but won't fire |

---

## Swap rules

- **Never swap generator and critic** without explicit instruction
- Before any model change: read `docs/architecture_llm_evaluation.md` for the full evaluation reasoning
- After any model change: run a full wet run (`DRY_RUN=TRUE`) before committing
- Critic model changes require verifying `format=` schema enforcement still works (test with `testthat::test_file("tests/testthat/test-critic.R")`)
