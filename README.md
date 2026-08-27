# Local AI Agent on an RTX 3060

![Hardware](https://img.shields.io/badge/GPU-RTX%203060%206GB-76B900)
![License](https://img.shields.io/badge/License-MIT-blue.svg)

6GB VRAM. 16GB RAM. No cloud. Here's how I built a local AI brain.

## What you'll build

You will compile `llama.cpp`, run `llama-server` with an OpenAI-compatible API, and verify a real model (`LFM2.5-8B-A1B-Q4_0`) with repeatable endpoint and context checks. Everything runs locally on consumer hardware.

## What you need

### Hardware

| Component | Minimum |
|---|---|
| GPU | NVIDIA RTX 3060 (6GB VRAM) |
| System RAM | 16GB |
| OS layer | WSL2 on Windows 11 (or native Linux) |

### Software

- CUDA Toolkit (matching your NVIDIA driver)
- `git`
- `cmake`
- `build-essential`
- `python3`
- `curl`

Install prerequisites:

```bash
sudo apt update
sudo apt install -y build-essential cmake git curl python3
```

## Step 1: Build llama.cpp

```bash
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
cmake -B build -DGGML_CUDA=ON
cmake --build build -j"$(nproc)"
```

Expected last line includes:

```text
[100%] Built target llama-server
```

### WSL2 RAM fix (important)

WSL2 defaults to 50% of host RAM (~8GB on a 16GB machine). Create `C:\Users\YOUR_USERNAME\.wslconfig`:

```ini
[wsl2]
memory=14GB
swap=2GB
```

Then run in PowerShell: `wsl --shutdown` and reopen WSL2.

### RUNPATH fix (if you moved the folder)

If you compiled llama.cpp in one location and moved it later, you may get:

```text
error while loading shared libraries: libllama-server-impl.so: cannot open shared object file
```

Fix — set `LD_LIBRARY_PATH` before launching:

```bash
export LD_LIBRARY_PATH=$PWD/build/bin:${LD_LIBRARY_PATH}
```

## Step 2: Start the server

The model auto-downloads from HuggingFace on first run (~4.8GB, cached for subsequent starts):

```bash
cd llama.cpp
export LD_LIBRARY_PATH=$PWD/build/bin:${LD_LIBRARY_PATH}

./build/bin/llama-server \
  -hf LiquidAI/LFM2.5-8B-A1B-GGUF:Q4_0 \
  -ngl 99 -c 65536 -fa on --jinja \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --host 0.0.0.0 --port 8080
```

### Flags explained

| Flag | Value | Why |
|------|-------|-----|
| `-hf LiquidAI/...:Q4_0` | auto-download + cache | Pulls the 4.8GB GGUF from HuggingFace into the llama.cpp cache on first run |
| `-ngl 99` | All layers to GPU | Maximizes GPU utilization |
| `-c 65536` | 64K context | Hermes minimum. LFM2.5 has 128K native — no server cap |
| `-fa on` | Flash attention | Reduces memory, faster inference |
| `--jinja` | Jinja templates | Enables tool-call parsing for agentic use |
| `--cache-type-k/v q8_0` | 8-bit KV cache | Balances memory and precision. q4_0 breaks reasoning on 6GB cards |
| `--host 0.0.0.0` | Listen all interfaces | Required for Hermes to connect |

### Model specs

| Property | Value |
|----------|-------|
| Architecture | MoE, 8.3B total / ~1B active |
| Context | 128K native |
| File size (Q4_0) | 4.84 GB |
| VRAM used | ~5679 / 6144 MiB |
| Inference speed | ~123 tok/s generated |
| Training budget | 38T tokens |

## Step 3: Verify

Health check:

```bash
curl -s http://127.0.0.1:8080/health
```

Expected:

```text
{"status":"ok"}
```

Model list:

```bash
curl -s http://127.0.0.1:8080/v1/models
```

Server properties (check context size):

```bash
curl -s http://127.0.0.1:8080/props | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"n_ctx_train: {d['default_generation_settings']['params'].get('n_ctx_train', 'N/A')}\")
print(f\"n_ctx: {d['n_ctx']}\")
print(f\"model: {d['model_alias']}\")"
```

Expected:

```text
n_ctx_train: 131072
n_ctx: 65536
model: LiquidAI/LFM2.5-8B-A1B-GGUF:Q4_0
```

## Step 4: Run the quality floor

The probe suite tests arithmetic, spelling, reasoning, and tokenizer behavior:

```bash
bash scripts/testes.sh 3
```

Expected output (3 runs per probe):

```text
########################################
# 1. ARITHMETIC
########################################
=== ARITH: what is 2+2 ===
--- run 1 ---
[think  ] The user asks: "What is 2+2? Answer in one short sentence." ...
[answer ] The sum of 2 and 2 is 4.
--- run 2 ---
[think  ] ...
[answer ] The result is four.
--- run 3 ---
[think  ] ...
[answer ] It equals four.
```

### Reading the results

| observation | verdict |
|---|---|
| ARITH wrong ("222") | KV cache quantized too low — switch to f16/q8_0 |
| SPELL wrong, CONTROL right | tokenizer expected behavior — model is healthy |
| SPELL right, CONTROL right | model has learned letter decomposition well |
| SPELL wrong, CONTROL wrong | model quality / context window issue — deeper debugging |

### Run the context probe

Tests whether the server actually serves the context size it claims:

```bash
python3 scripts/probe_ctx.py 40000
```

Expected:

```text
[probe] built prompt: 47989 tokens (target >= 40000)
[probe] sending 47989-token prompt ...
[probe] ACCEPTED in 14.7s | prompt_tokens=48011 | prefill=3320 tok/s
[probe] reply: '' | needle retrieved: False

=== VERDICT (40000-token empirical probe): PASS (served >32K without rejection) ===
```

PASS means the server accepted >32K tokens without rejection — the context cap is bypassed.

## The debugging story

### The KV cache bug

With `--cache-type-k q4_0 --cache-type-v q4_0 -c 32768`, the model answered:

```text
"222 is an even-digit numbernumber. in in222."
```

...when asked "What is 2+2?" The **weights** were fine (Q4_K_M, verified). The problem was the **KV cache** — quantizing it to 4-bit blurred attention precision. Fix: switch to `q8_0` cache, accept smaller context.

### The context cap

llama.cpp server caps usable context at `n_ctx_train` — the model's training context length. Qwen 2.5-7B has 32K training context, so `-c 65536` still served only 32K. LFM2.5-8B-A1B has 128K native — the cap never fires.

### Model selection

Qwen 2.5-7B: 32K cap, couldn't meet Hermes 64K minimum. GPT-OSS-20B: 11.6GB file, needed RAM bump. LFM2.5-8B-A1B: 4.84GB, 128K native, ~1B active params (fast), fits entirely in 6GB VRAM.

## Troubleshooting (Top 5)

1. **`CUDA error: out of memory`** — Lower `-ngl` (try `-ngl 28`) or reduce context (`-c 32768`)
2. **`/health` not reachable** — Confirm the server process is running: `ps aux | grep llama-server`
3. **Model missing in `/v1/models`** — Check the `-hf` repo name matches exactly. HuggingFace is case-sensitive
4. **`libllama-server-impl.so: cannot open shared object file`** — Set `LD_LIBRARY_PATH=$PWD/build/bin:${LD_LIBRARY_PATH}` before launching
5. **Model answers are garbage** — Check KV cache: `--cache-type-k q4_0` breaks reasoning on 6GB cards. Use `q8_0` or omit for f16 default

## Project structure

```
local-ai-agent-3060/
├── README.md              ← you are here
├── SOUL.md                ← CPA persona for Hermes (post 2)
├── LICENSE                ← MIT
├── configs/
│   └── QUICK_START.md     ← install reference + VRAM math
├── scripts/
│   ├── testes.sh          ← quality floor probe suite
│   ├── testes.md          ← token trace guide + methodology
│   └── probe_ctx.py       ← context capacity probe
├── test/
│   └── test.md            ← 40-question self-assessment
└── learning-journal/
    ├── README.md           ← what's in here
    ├── session_2026_08_26.md  ← full evaluation gate
    ├── week_02_summary.md     ← debug story
    └── research2.md           ← model selection research
```

## Follow me

Found this useful? Follow me on LinkedIn for more local AI projects.

If this helped, star this repo.

## What's next

Post 2: Hermes agent + Telegram + memory + CPA persona. Coming soon.
