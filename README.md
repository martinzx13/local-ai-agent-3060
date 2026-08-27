# Local AI Agent on an RTX 3060

![Hardware](https://img.shields.io/badge/GPU-RTX%203060%206GB-76B900)
![License](https://img.shields.io/badge/License-MIT-blue.svg)

6GB VRAM.
16GB RAM.
No cloud. Here's how I built a local AI brain.

## What you'll build

You will compile `llama.cpp`, run `llama-server` with an OpenAI-compatible API, and verify a real model (`LFM2.5-8B-A1B-Q4_0.gguf`) with repeatable endpoint and context checks.

## What you need

### Hardware

| Component | Minimum |
|---|---|
| GPU | NVIDIA RTX 3060 (6GB VRAM) |
| System RAM | 16GB |
| OS layer | WSL2 on Windows 11 |

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
cd /home/runner/work/local-ai-agent-3060/local-ai-agent-3060
git clone https://github.com/ggerganov/llama.cpp.git
cd llama.cpp
cmake -S . -B build -DGGML_CUDA=ON
cmake --build build -j"$(nproc)"
```

Expected last line includes:

```text
[100%] Built target llama-server
```

If `llama-server` cannot find CUDA libraries, fix your runtime path:

```bash
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}
```

## Step 2: Start the server

Place your model at:

```text
/home/runner/work/local-ai-agent-3060/local-ai-agent-3060/models/LFM2.5-8B-A1B-Q4_0.gguf
```

Launch:

```bash
cd /home/runner/work/local-ai-agent-3060/local-ai-agent-3060/llama.cpp
./build/bin/llama-server \
  -m /home/runner/work/local-ai-agent-3060/local-ai-agent-3060/models/LFM2.5-8B-A1B-Q4_0.gguf \
  --host 127.0.0.1 \
  --port 8080 \
  -ngl 35 \
  -c 4096
```

Flags:

- `-m`: model path
- `--host` / `--port`: bind address and API port
- `-ngl 35`: offload layers to GPU
- `-c 4096`: runtime context window

## Step 3: Verify

Health check:

```bash
curl -fsS http://127.0.0.1:8080/health
```

Expected:

```text
ok
```

Model list:

```bash
curl -fsS http://127.0.0.1:8080/v1/models
```

Expected to contain:

```text
LFM2.5-8B-A1B
```

Server properties:

```bash
curl -fsS http://127.0.0.1:8080/props
```

Run the context probe:

```bash
python3 /home/runner/work/local-ai-agent-3060/local-ai-agent-3060/test/probe_ctx.py
```

Expected shape:

```text
n_ctx_train=...
n_ctx=...
usable_ctx=...
status=OK
```

Run the full verification script:

```bash
bash /home/runner/work/local-ai-agent-3060/local-ai-agent-3060/test/testes.sh
```

## Step 4: Run the quality floor

`testes.sh` enforces a minimum quality floor: server is alive, OpenAI model listing works, `/props` is valid, and context settings are sane.

Typical passing output:

```text
CHECK                          RESULT
health endpoint                PASS
openai models endpoint         PASS
props endpoint                 PASS
context probe                  PASS
overall                        PASS
```

Results table:

| Check | Pass condition |
|---|---|
| health endpoint | `/health` returns `ok` |
| openai models endpoint | `/v1/models` includes `LFM2.5-8B-A1B` |
| props endpoint | `/props` exposes `n_ctx_train > 0` |
| context probe | `n_ctx <= n_ctx_train` |

## The debugging story

- **KV cache bug (`222222`)**: early runs failed with cache instability under longer prompts; reducing runtime context while validating model metadata avoided false negatives.
- **Context cap (`n_ctx_train`)**: setting runtime `-c` above training context degraded behavior; probing `/props` made this measurable.
- **Model selection journey**: bigger checkpoints exceeded the 6GB VRAM comfort zone; `LFM2.5-8B-A1B-Q4_0.gguf` hit the best local balance.

## Troubleshooting (Top 5)

1. **`CUDA error: out of memory`**  
   Lower GPU pressure: reduce `-ngl` (example: `-ngl 28`).
2. **`/health` not reachable**  
   Confirm the server process is running and bound to `127.0.0.1:8080`.
3. **Model missing in `/v1/models`**  
   Recheck model filename/path and restart server with the exact `-m` value.
4. **`status=FAIL` in `probe_ctx.py`**  
   Set `-c` to a value less than or equal to `n_ctx_train`.
5. **`llama-server: error while loading shared libraries`**  
   Export `LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}` before launch.

## Follow me

Found this useful? Follow me on LinkedIn [link].

If this helped, star this repo.

## What's next

Post 2: Hermes agent + Telegram + memory. Coming soon.
