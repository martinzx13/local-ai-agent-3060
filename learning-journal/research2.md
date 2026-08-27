# Research Notes 2 — KV Cache Reality Check (The 64K That Wasn't)

> **Purpose:** document the investigation into the running server's actual KV cache / context size.
> Follows up `research.md`. This is the story of how "64K is configured" became "64K is a lie" — and how to verify it yourself.

---

## 1. The Trigger

Claim to verify: *"the model now has the full cache to work with Hermes."*

The server was launched with:

```bash
./llama.cpp/build/bin/llama-server -hf bartowski/Qwen2.5-7B-Instruct-GGUF:Q3_K_M \
  -ngl 99 -c 65536 -fa on --jinja \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --rope-scaling yarn --rope-scale 2 --yarn-orig-ctx 32768 \
  --host 0.0.0.0 --port 8080
```

Looks like 64K context. The question: **does the server actually serve 64K?** Answer: **no. It serves 32K.**

---

## 2. How to Check the KV Cache / Context Size (5 methods)

| # | Method | Command | What it reveals |
|---|--------|---------|-----------------|
| 1 | `/props` | `curl localhost:8080/props` | `default_generation_settings.params.n_ctx` = total context the server reports |
| 2 | `/slots` | `curl localhost:8080/slots` | per-slot `n_ctx` + live `n_prompt_tokens`/`n_prompt_tokens_processed` while a request runs |
| 3 | `/metrics` | needs `--metrics` at launch (not enabled here) | prometheus gauges incl. KV token counts |
| 4 | **Empirical probe** | send a prompt larger than expected limit | hard error message states the real limit — **the definitive test** |
| 5 | Startup log | the terminal that launched the server | `KV self size`, `KV cache size` lines in MiB |

The empirical probe (this is the one that exposed the truth):

```bash
# send a ~40,040-token prompt
curl -s localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"<40000 words>"}],"max_tokens":5}'
```

Response:

```json
{
  "error": {
    "code": 400,
    "message": "request (40040 tokens) exceeds the available context size (32768 tokens), try increasing it",
    "type": "exceed_context_size_error",
    "n_prompt_tokens": 40040,
    "n_ctx": 32768
  }
}
```

**The server reports `n_ctx: 32768` regardless of the `-c 65536` flag.**

Corroborating evidence from `/props` + `/slots`:
- `total_slots: 4` (auto parallel)
- each slot `n_ctx: 32768`
- `default_generation_settings.params.n_ctx: 32768`

---

## 3. Root Cause — The Server-Side Cap

Found in `tools/server/server-context.cpp:1252-1256` (build 10085, `b4aa7dd47`):

```cpp
const int n_ctx_train = llama_model_n_ctx_train(model_tgt);

int n_ctx_slot = llama_n_ctx_seq(ctx_tgt);
if (n_ctx_slot > n_ctx_train) {
    SRV_WRN("the slot context (%d) exceeds the training context of the model (%d) - capping\n", n_ctx_slot, n_ctx_train);
    n_ctx_slot = n_ctx_train;
}
```

**Mechanics:**
1. `-c 65536` allocates the KV cache for 64K (this is why VRAM is ~5.5GB).
2. The server then **caps each slot's usable context** to `llama_model_n_ctx_train(model_tgt)`.
3. For Qwen2.5-7B, `n_ctx_train` = **32768**.
4. Result: per-request usable context = 32K, no matter what `-c` or YARN says.

**Verified against current upstream master** (fetched `tools/server/server-context.cpp`): the identical capping logic is still present. Not a bug in a stale build — it is current llama.cpp behavior.

---

## 4. Why YARN Does NOT Fix It

- YARN (`--rope-scaling yarn --rope-scale 2 --yarn-orig-ctx 32768`) changes **rope position factors** so the model can *attend across* 64K positions without retraining.
- It does **NOT** change `n_ctx_train` — that value comes from GGUF metadata (32K for Qwen2.5-7B-Instruct).
- The cap reads `n_ctx_train`, so **the cap fires regardless of YARN**.
- Confirmed in source: `llama-model.cpp:1152` only sets `n_ctx_orig_yarn` from metadata; nothing in `common/arg.cpp` or the model loader ever raises `n_ctx_train` for YARN.

> Takeaway: YARN extends the *rope* but the *server slot cap* is a separate, harder limit. In server mode the two are decoupled — and the cap wins.

---

## 5. Impact on Hermes

| Requirement | Needed | Current server | Status |
|-------------|--------|----------------|--------|
| Min context | 64K (rejected at startup if smaller) | 32768 | ❌ BLOCKED |

The Hermes 64K requirement is **not met** by the current config. The YARN+64K launch gives Hermes 32K. This is the exact kind of "silently configured wrong" state the whole testing discipline exists to catch.

---

## 6. What This Means for the Options

1. **A model whose native `n_ctx_train >= 64K`** passes the cap naturally — no workaround needed. Qwen2.5-7B-Instruct is 32K → fails. Candidates with native ≥64K context are the clean path.
2. **`--parallel 1`?** Does not help — the cap is on `n_ctx_slot` after seq-splitting; per-slot is what gets capped, and the total allocation is already 64K. Fewer slots only changes the split, not the cap.
3. **Patching the cap** (removing/raising the capping in `server-context.cpp`) is possible but keeps you on a fork of llama.cpp — maintenance cost, and against the project's "learn the standard path" goal.
4. **Accepting 32K** is not viable for Hermes (hard minimum 64K).

---

## 7. Follow-up Process (what to do next)

- [ ] Verify candidate model's `n_ctx_train` **before** launching: check the GGUF metadata or the `/props` output after load.
- [ ] Always run the **empirical probe** after any context change — never trust the launch flags.
- [ ] Decide: (a) find a ≥64K-native model for the Hermes backend, or (b) explore patching the cap in a throwaway fork.
- [ ] Log the outcome in `progress/week_03_summary.md`.

---

## 8. Sources

- Current llama.cpp server cap: `tools/server/server-context.cpp` (local build 10085 + upstream master)
- `n_ctx_train` / YARN orig-ctx handling: `src/llama-model.cpp:1152`, `src/llama-context.cpp:133-134`
- Context split / seq logic: `src/llama-context.cpp:287-297`, `llama_n_ctx_seq` at `src/llama-context.cpp:3606`
- Prior art on the 64K requirement: `research.md` section 7 (Hermes Integration Blockers)

---

# Part 2 — MoE Plan Reality Check (feasibility audit, 2026-08-11)

> Context: decision was made to move to the MoE plan (research.md sections 2-5).
> Before launching anything, the environment was audited. Two discoveries change the plan.

## 9. CRITICAL: WSL2 RAM Is 8GB, Not 16GB

`research.md` section 1 assumed "RAM 16GB, ~12-14GB usable." Reality check:

| Measurement | Value |
|-------------|-------|
| Host physical RAM (via PowerShell) | **15.7 GB** |
| WSL2 total RAM (`free -h`) | **7.6 GiB** |
| WSL2 available now (server running) | ~4.5 GiB |
| `.wslconfig` present | **NO** |
| Swap | 2 GiB |

**Why:** WSL2 default memory = 50% of host RAM (8GB) when no `.wslconfig` exists. The 16GB host is real, but the Linux VM only sees 8GB.

**Why it kills the MoE plan as-is:** `--cpu-moe` offloads routed-expert weights to **system RAM**. GPT-OSS-20B Q4_K_M is an **11.6GB file** — the expert portion alone exceeds 8GB of total WSL RAM. Qwen3.6-35B-A3B is even bigger.

**Fix (user decision required):** create `C:\Users\martinxz13\.wslconfig`:

```ini
[wsl2]
memory=14GB
swap=2GB
```

Then `wsl --shutdown` from Windows PowerShell and reopen WSL. **This kills the current session and the running llama-server.**

## 10. MoE Model GGUF Sources — Verified (no more guessing)

| Model | Repo | File | Size | Status |
|-------|------|------|------|--------|
| **GPT-OSS-20B Q4_K_M** | `unsloth/gpt-oss-20b-GGUF` | `gpt-oss-20b-Q4_K_M.gguf` | **11.6 GB** | ✅ 302→CDN, downloadable (not gated) |
| GPT-OSS-20B MXFP4 | `ggml-org/gpt-oss-20b-GGUF` | `gpt-oss-20b-MXFP4.gguf` | **12.1 GB** | ✅ native quant, alt path |
| Qwen3.6-35B-A3B Q4_K_M | `Infatoshi/Qwen3.6-35B-A3B-GGUF` | `Qwen3.6-35B-A3B-Q4_K_M.gguf` | **21.2 GB** | ❌ too big for 8GB RAM |

**Correction to research.md:** the Infatoshi repo does **NOT** contain IQ2_M (claimed 11.1-12.96GB). Available quants are BF16 / Q4_K_M / Q5_K_M / Q8_0 only. Q4_K_M = 21.2GB → **infeasible** on this RAM/VRAM budget. If Qwen3.6 is to be used, an IQ2_M source must be found elsewhere.

## 11. The Cap Problem Solves Itself (good news)

Both MoE candidates have native `n_ctx_train >= 64K`:

| Model | Native context | Server cap binds at 64K? |
|-------|---------------|--------------------------|
| GPT-OSS-20B | 128K (sliding window) | ❌ no |
| Qwen3.6-35B-A3B | 262K | ❌ no |

Because the cap in `server-context.cpp:1252-1256` reads `n_ctx_train`, and both models exceed 64K natively, **the YARN workaround becomes unnecessary** for the MoE path. Plain `-c 65536` gives real 64K.

## 12. Revised MoE Execution Plan

```bash
# 0. (BLOCKER) fix WSL2 RAM: .wslconfig memory=14GB + wsl --shutdown
# 1. launch GPT-OSS-20B Q4_K_M with experts offloaded to RAM
./llama.cpp/build/bin/llama-server -hf unsloth/gpt-oss-20b-GGUF:Q4_K_M \
  -ngl 99 -c 65536 -fa on --jinja --cpu-moe \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --host 0.0.0.0 --port 8080
# 2. verify (never trust flags):
#    /props  -> n_ctx_train + n_ctx
#    empirical 40K-token probe -> must NOT reject
#    ./testes.sh -> quality floor
#    nvidia-smi -> VRAM headroom (~3.5GB expected)
# 3. Hermes: point config at http://127.0.0.1:8080/v1, cp SOUL_CPA.md ~/.hermes/SOUL.md
```

## 13. Open Decisions

- [ ] WSL2 RAM bump (user must run `wsl --shutdown`; kills session + server)
- [ ] GPT-OSS-20B Q4_K_M (proceed) vs hunt for Qwen3.6 IQ2_M (needs new source repo)
- [ ] If Qwen3.6 chosen: find/verify an IQ2_M quant that fits RAM

---

# Part 3 — Liquid AI / LFM2.5-8B-A1B: A Candidate That Fits Everything (2026-08-11)

> Context: researching 2026 small models to expand Hermes backend candidates. Liquid AI came up; the flagship **LFM2.5-8B-A1B** turned out to be the rare model that satisfies every hard constraint *without* the WSL2 RAM fix. This is the reasoning trail + verified facts.

## 14. The Candidate (verified spec sheet)

| Property | Value | Why it matters |
|----------|-------|----------------|
| **Context** | **131,072 (128K)** native | Passes the 64K Hermes floor AND bypasses the `server-context.cpp:1252-1256` cap (cap reads `n_ctx_train` = 128K here) — no YARN needed |
| Architecture | MoE, **8.3B total / ~1B active** | Fast inference; only ~1B active params compute per token |
| Q4_K_M (official) | **5.16 GB** | **Entire model fits in 6 GB VRAM** → no `--cpu-moe`, no RAM bump |
| Q4_0 (official) | 4.84 GB | Even safer headroom on 6143 MiB GPU |
| UD-IQ4_XS (unsloth) | 4.26 GB | Smallest quality option |
| Vocab | 128,000 | |
| Training budget | 38T tokens | |
| Template | ChatML-like (`<\|im_start\|>`), `<\|startoftext\|>` prefix | Close to what Hermes expects |
| Tool use | Native, designed for agentic workflows / on-device personal assistant | Exactly the Hermes use case |

**Repos (both downloadable, not gated):**
- `LiquidAI/LFM2.5-8B-A1B-GGUF` — official: BF16/F16/Q4_0/Q4_K_M/Q5_K_M/Q6_K/Q8_0
- `unsloth/LFM2.5-8B-A1B-GGUF` — UD dynamic quants: MXFP4, IQ1_M→Q8_K_XL (IQ4_XS 4.26GB, UD-Q4_K_S 5.01GB, UD-Q4_K_M 5.32GB)

## 15. How the Research Was Done (the method)

1. **HF API exists-check** — probed 5 plausible GGUF repo names in one loop; only `LiquidAI/*` and `unsloth/*` returned 200. `bartowski`/`mradermacher`/`ggml-org` have no LFM2.5-8B GGUF yet.
2. **File inventory + sizes** via `.../api/models/<repo>/tree/main` — grabbed real byte sizes for every quant, no guessing.
3. **Read the READMEs** (official + unsloth) — pulled context length (131,072), training budget, tool-use format, chat template, and the "not best for heavy programming / knowledge QA without retrieval" caveat.
4. **Checked local llama.cpp support** — the compiled binary is a thin ELF shim; the real code lives in the shared libs. `strings libllama.so.0.0.10085 | grep lfm2moe` → **23 symbols** including `load_arch_hparams`, `load_arch_tensors`, `build_arch_graph`. The `lfm2moe.cpp` model loader is already in the local build 10085. No recompile needed.
5. **Read `lfm2moe.cpp` loader** — confirmed expert tensor naming (`ffn_gate_inp`, `ffn_gate_exps`, `ffn_up_exps`, `ffn_down_exps`, `ffn_exp_probs_b`) → `--cpu-moe` compatible if ever needed, and gating func is read from GGUF metadata (`LLM_KV_EXPERT_GATING_FUNC`), so nothing special to pass on the command line.

**Method takeaways:** check the *files actually on disk* (tree API), not the model card claims; the HF model API returns 404 for nonexistent repos — a cheap existence probe; llama.cpp binary is a shim, so verify arch support via `strings` on the `.so`.

## 16. Two Risks Flagged (NOT yet tested — the decision gate)

1. **Tool-call format mismatch.** LFM2.5 emits *Pythonic* calls by default:
   ```
   <|tool_call_start|>[get_candidate_status(candidate_id="12345")]<|tool_call_end|>
   ```
   Hermes expects strict OpenAI-style JSON `<action>` blocks (`tool` + `tool_input`). The card says JSON can be forced via the system prompt — **must be live-tested**.
2. **Reasoning model (explicit CoT).** Assistant turns contain chain-of-thought before the final answer. CoT can break strict action parsing → also needs a live probe (or a system-prompt override to suppress reasoning).

## 17. Why This Model Beats the Earlier MoE Candidates

| Candidate | Size | RAM blocker? | Context | VRAM-only? |
|-----------|------|--------------|---------|------------|
| GPT-OSS-20B Q4_K_M | 11.6 GB | ✅ needs RAM bump (8GB WSL) | 128K | ❌ `--cpu-moe` |
| Gemma 4 26B A4B Q4_K_M | 16.8 GB | ✅ needs RAM bump | 256K | ❌ `--cpu-moe` |
| **LFM2.5-8B-A1B Q4_K_M** | **5.16 GB** | ❌ **none** | **128K** | ✅ **full GPU** |

Only LFM2.5-8B-A1B satisfies **all** of: 64K+ native context, fits 6 GB VRAM entirely, no `.wslconfig`/`wsl --shutdown` required. It is the zero-environment-change path to the MoE plan.

## 18. Revised Zero-Risk Execution Plan (Phase 0-2)

```bash
# PHASE 0 — launch (no RAM fix needed)
./llama.cpp/build/bin/llama-server -hf LiquidAI/LFM2.5-8B-A1B-GGUF:Q4_0 \
  -ngl 99 -c 65536 -fa on --jinja \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --host 0.0.0.0 --port 8080
# Q4_0 (4.84GB) chosen over Q4_K_M (5.16GB) for VRAM headroom; upgrade later if tight.

# PHASE 1 — verify (never trust flags)
#   /props          -> n_ctx should now equal requested 65536 (n_ctx_train = 131072)
#   empirical 40K probe -> must NOT reject (proves cap bypassed)
#   ./testes.sh     -> quality floor

# PHASE 2 — Hermes compatibility gate
#   probe 1: system prompt forcing JSON tool calls -> does it emit <action> JSON?
#   probe 2: suppress CoT -> does action parsing stay strict?
#   PASS -> make it the Hermes backend (CPA activation + first conversation)
#   FAIL -> fallbacks: Gemma 4 E4B (5.3GB dense, 128K) or GPT-OSS-20B (needs RAM bump)
```

## 19. Open Decisions / Follow-ups

- [ ] Download Q4_0 (4.84GB) or Q4_K_M (5.16GB) — official vs unsloth UD variant
- [ ] Live-test tool-call JSON override + CoT suppression (the decision gate)
- [ ] If it passes: adopt as Hermes backend; note caveat "not for heavy programming/knowledge QA without retrieval"
- [ ] Keep GPT-OSS-20B path in reserve (still requires `.wslconfig` RAM bump)
