# Quick Reference — Hermes + llama.cpp Setup

## Your Hardware Profile

| Component | Value | Impact |
|-----------|-------|--------|
| GPU | RTX 3060 (6GB VRAM) | Can fit 7B Q4 models fully on GPU |
| RAM | 16GB | WSL2 default allocates ~8GB — fix with `.wslconfig` (see below) |
| SSD | 1TB | Plenty of space for models (~4-5GB each) |
| Platform | Windows (WSL2) | CUDA passthrough required |

## VRAM Budget (The Hard Math)

The **full KV cache formula** (memorize this — it governs everything on 6GB):
```
KV cache (bytes) = n_layers × n_kv_heads × head_dim × 2 × n_ctx × bytes_per_element
                                                            (×2 = one K + one V)
bytes per element: f32=4, f16=2, q8_0=1, q4_0=0.5
```

**Qwen2.5-7B architecture:** `n_layers=28`, `n_kv_heads=4`, `head_dim=128`
→ `28 × 4 × 128 × 2 = 28,672 bytes/token` (f16).

```
Total = model weights (~4.36 GB) + KV cache + overhead (~0.4 GB)

 16K context, f16  :  4.36 + 0.94 + 0.40 = 5.70 GB   ✓ comfortable fit
 32K context, f16  :  4.36 + 1.75 + 0.40 = 6.51 GB   ✗ ~0.5 GB OVER 6GB
 32K context, q4_0 :  4.36 + 0.47 + 0.40 = 5.23 GB   ✓ (but degrades reasoning — see trade-off below)
```

**Bottom line:** On 6GB you cannot have 32K context *and* full-precision cache.
**Choice: `f16` cache + 16K context (accurate) vs `q4_0` cache + 32K context (dim).**

## Recommended Models (Your Hardware)

| Model | File | Size | VRAM | Context | Notes |
|-------|------|------|------|---------|-------|
| **LFM2.5-8B-A1B Q4_0** | `LFM2.5-8B-A1B-Q4_0.gguf` | ~4.8GB | ~5.7GB | 128K | **USE THIS** — MoE, 1B active, fast |
| LFM2.5-8B-A1B Q4_K_M | `LFM2.5-8B-A1B-Q4_K_M.gguf` | ~5.2GB | ~6.0GB | 128K | Tighter fit, slightly better quality |
| Qwen2.5-7B-Instruct Q4_K_M | `qwen2.5-7b-instruct-q4_k_m.gguf` | ~4.5GB | ~5.5GB | 32K | Good alternative, but 32K cap |
| Llama-3.1-8B-Instruct Q4_K_M | `llama-3.1-8b-instruct-q4_k_m.gguf` | ~4.9GB | ~5.8GB | 32K | Good alternative |

**Strategy:** Start with LFM2.5-8B-A1B Q4_0. It fits entirely in 6GB VRAM, has 128K native context (bypasses the llama.cpp server cap), and only activates ~1B parameters per token (fast inference).

## Install Commands

```bash
# 1. Install llama.cpp (WSL2 + CUDA — MUST pass CUDA flag)
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
cmake -B build -DGGML_CUDA=ON     # ⚠ WITHOUT -DGGML_CUDA=ON you get a SLOW CPU-only build
cmake --build build -j$(nproc)

# 2. Start llama-server — the VERIFIED config (LFM2.5-8B-A1B Q4_0)
#    -hf auto-downloads AND caches the model from HuggingFace on first run
#    NOTE: if you moved the llama.cpp folder, set LD_LIBRARY_PATH first:
export LD_LIBRARY_PATH=$PWD/build/bin:${LD_LIBRARY_PATH}

./build/bin/llama-server \
  -hf LiquidAI/LFM2.5-8B-A1B-GGUF:Q4_0 \
  -ngl 99 -c 65536 -fa on --jinja \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --host 0.0.0.0 --port 8080
```

> **Optional — manual model download** (if you want the file in your project instead of the llama.cpp cache):
> ```bash
> curl -L -o models/LFM2.5-8B-A1B-Q4_0.gguf \
>   "https://huggingface.co/LiquidAI/LFM2.5-8B-A1B-GGUF/resolve/main/LFM2.5-8B-A1B-Q4_0.gguf"
> ls -lh models/LFM2.5-8B-A1B-Q4_0.gguf   # verify ~4.8GB, NOT a small HTML error page
> ```

## WSL2 RAM Fix (Important)

WSL2 defaults to 50% of host RAM (~8GB on a 16GB machine). To give WSL2 more RAM:

1. Create `C:\Users\YOUR_USERNAME\.wslconfig`:
```ini
[wsl2]
memory=14GB
swap=2GB
```
2. Run in PowerShell: `wsl --shutdown`
3. Reopen WSL2

**Note:** This kills all WSL2 processes including running servers.

## The RUNPATH Issue

If you move the `llama.cpp` folder after compiling, you may get:
```
error while loading shared libraries: libllama-server-impl.so: cannot open shared object file
```

**Fix:** set `LD_LIBRARY_PATH` before launching:
```bash
export LD_LIBRARY_PATH=$PWD/llama.cpp/build/bin:${LD_LIBRARY_PATH}
```

## The Accuracy ↔ Context Trade-off (critical on 6GB)

> **Observed and VERIFIED** (see `progress/week_02_summary.md`): launching with
> `--cache-type-k q4_0 --cache-type-v q4_0 -c 32768` made the model *incapable of 2+2*
> (it answered "222 is an even-digit numbernumber"). Restoring the cache to full
> precision (`f16`, the default) and halving context to 16K fixed it — 4/4 correct.

- **The KV cache holds the K/V tensors of every token in context.** Quantizing it
  (`q4_0`) shrinks memory ~4x to fit more context, but smears attention precision.
- **On 6GB it's context *or* precision, not both.**
- Diagnostic method that caught this: send the same trivial prompt 3–4 times and read
  `choices[0].message.content` — NOT the llama-server terminal logs (those only show
  token throughput, never "accuracy").
- Use `scripts/testes.sh` to sanity-check the model after any config change.

## Key Flags Explained

| Flag | Value | Why |
|------|-------|-----|
| `-hf LiquidAI/...:Q4_0` | auto-download+cache | Pulls the 4.8GB GGUF from HF into the llama.cpp cache on first run |
| `-ngl 99` | All layers to GPU | Maximizes GPU utilization |
| `-c 65536` | 64K context | Hermes minimum. LFM2.5 has 128K native — cap is bypassed |
| `-fa on` | Flash attention | Reduces memory, faster inference |
| `--cache-type-k/v q8_0` | 8-bit KV cache | Balances memory and precision. **q4_0 breaks reasoning — verify with `scripts/testes.sh`** |
| `--host 0.0.0.0` | Listen all interfaces | Required for Hermes to connect |

## Verify It Works

```bash
# Test llama-server
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'

# Check VRAM usage
nvidia-smi

# Test Hermes
hermes
```

## SOUL.md Location

Copy `SOUL_CPA.md` to `~/.hermes/SOUL.md` to activate the Cognitive Performance Architect personality.

## Troubleshooting

- **Out of VRAM:** Reduce context (`-c 16384` or lower) or restore a quantized cache (`--cache-type-v q8_0` — keep **V** full precision, it's the sensitive one)
- **Hermes says "context too small":** Minimum is 64K for Hermes. If VRAM is tight, try `-c 65536` with `--cache-type-k q8_0 --cache-type-v f16`
- **Model answers are garbage/dumb:** Check the KV cache — `q4_0` on both K and V degrades reasoning. Restore `f16`, re-run `scripts/test_llm.sh`, expect "4" ×4 on a 2+2 probe
- **Broken model file:** after any manual download, verify `file` says "data" not "HTML document" and `ls -lh` ≈ 4.4GB (a 188K file = failed download)
- **Hermes can't connect:** `curl localhost:8080/v1/models` first — if that works, Hermes config is wrong
- **Slow responses:** Check `nvidia-smi` — if GPU utilization is low, increase `-ngl`
- **WSL2 GPU not visible:** Install NVIDIA CUDA toolkit in WSL2, not just Windows drivers
