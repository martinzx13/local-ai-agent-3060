# Week 2 Progress Summary — "First Light" on the Local Stack

## Status Dashboard
| Component | Status | Note |
|-----------|--------|------|
| `llama.cpp` CUDA build (`llama-server`) | ✅ Verified | Real ELF in `build/bin/` (Jul 22) |
| Model `Qwen2.5-7B-Instruct-Q4_K_M` | ✅ Loaded | ~4.4GB, bartowski repo |
| GPU offload (`-ngl 99`) | ✅ Working | `nvidia-smi` = 4981/6144 MiB used |
| llama-server API | ✅ Verified | `/health`=ok, `/v1/models` lists model |
| **Model reasoning accuracy** | ✅ **Fixed** | 4/4 correct on 2+2 probe |
| Hermes v0.14.0 | ✅ Installed | `~/.local/bin/hermes` |

**Phase 0 = COMPLETE.** Next: first Hermes conversation + CPA `SOUL.md` activation (Phase 1).

---

## The Debugging Story (this week's real learning)

### 1. Broken model file (silent failure)
A `models/Qwen2.5-7B-Instruct-Q4_K_M.gguf` existed but was only **188K** and `file` reported **"HTML document"** — it was a failed HuggingFace download stub (~4.4GB expected). 
*Comando:* `file <model>` + `ls -lh <model>` (188K ≠ 4.4G).
*Fix:* use `-hf` to let llama-server auto-download + cache from a working repo.

### 2. Wrong model source
`configs/QUICK_START.md` pointed at `unsloth/Qwen2.5-7B-Instruct-GGUF` → now **HTTP 401 (gated)**.
*Fix:* verified `bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M` (multi-part, 4.68GB, HTTP 302→200).

### 3. The accuracy bug — q4_0 KV cache **broke reasoning**
#### Symptom
Answers were garbage on a trivial question even though the API worked:
```
"content": "222 is an even-digit numbernumber. in in222."   ← asked "What is 2+2?"
```
#### Original launch (BROKEN)
```bash
llama.cpp/build/bin/llama-server \
  -hf bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M \
  -ngl 99 -c 32768 -fa on \
  --cache-type-k q4_0 --cache-type-v q4_0 \
  --host 0.0.0.0 --port 8080
```
#### Diagnostic method (the skill to keep)
- Did **NOT** trust the llama-server terminal logs (they only report token throughput — no "accuracy" field).
- Probed the **API** instead: `curl /v1/models` (what's loaded), `/health` (alive), `/v1/chat/completions` (the actual answer in `choices[0].message.content`).
- Repeated a trivial probe 4× to rule out a one-off sampling fluke — all 4 were bad → confirmed real degradation.
- Ran the KV-cache formula to prove *why*:
```
KV cache = 28 × 4 × 128 × 2 × n_ctx × bytes
32K q4_0 ≈ 0.47GiB (fits, but 4-bit blur)
16K  f16 ≈ 0.94GiB (fits in 6GB)
Total(16K f16) = 4.36 + 0.94 + 0.40 ≈ 5.70GiB ✓  vs 6.0GiB
Total(32K f16) = 4.36 + 1.75 + 0.40 ≈ 6.51GiB ✗ OOM
```
Conclusion: **on 6GB, 32K context + full precision can't fit; q4_0 was the compromise that, on this card, costs reasoning.**

#### Fix (VERIFIED — current config)
```
./build/bin/llama-server \
  -hf bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M \
  -ngl 99 -c 16384 -fa on \
  --host 0.0.0.0 --port 8080
```
(Cache omitted = default f16; context halved to 16K to fit.)
Test loop `scripts/testes.sh` → **4/4 correct**:
```
______TEST 1 ______  → 2 + 2 is 4.
______TEST 2 ______  → 2 + 2 equals 4.
______TEST 3 ______  → 2 + 2 equals 4.
______TEST 4 ______  → 2 + 2 equals 4.
```

---

## Key Commands Used (this week)
```bash
nvidia-smi                                              # GPU + VRAM validation / VRAM watch
./build/bin/llama-server --help                         # read real flag semantics
curl -s http://localhost:8080/v1/models                 # model catalog (contract)
curl -s http://localhost:8080/health                    # liveness
curl -s http://localhost:8080/v1/chat/completions ...   # actual answer
./scripts/testes.sh                                      # 4× repeated reasoning probe
cp SOUL_CPA.md ~/.hermes/SOUL.md                         # activate CPA persona
```

## Diagnostic Tools (learned)
| Tool | Answers |
|------|---------|
| `nvidia-smi` | Is the model actually on the GPU? (4981/6144 MiB = yes) |
| `curl /v1/models` | What model/config is loaded? |
| `curl /health` | Is the process alive? |
| `curl /v1/chat/completions` | The REAL answer — read `choices[0].message.content` |
| `scripts/testes.sh` | Repeated probe to separate fluke from real degradation |
| KV-cache formula | Why a config can't fit / why it's slow or inaccurate |

## Conceptual Learnings
1. **`-ngl` = GPU layer offload** — more layers to VRAM = faster, but 6GB is a hard ceiling.
2. **KV cache** stores the K/V tensors of every token in context → lets generation attend to history without recomputation.
3. **Quantizing the KV cache trades memory for attention precision** — on a 6GB card the q4_0 cache was the root cause of garbage answers.
4. **Context (`-c`) vs precision (cache dtype) are mutually exclusive on small VRAM.** One VRAM pot, two consumers.
5. **Diagnose at the layer where the data you care about lives** — the API JSON, not the log terminal.

## Next Week Focus
- First Hermes conversation through the local llama-server.
- Activate CPA `SOUL.md`; verify Socratic, scaffolding tone.
- Write `notes/first_light.md` teach-back (data path + surprise + change you'd make).