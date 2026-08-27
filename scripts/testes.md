# testes.md — How the Probe Suite Works & How Tokens Were Traced

> Companion guide to `testes.sh` in this folder.
> Read this before running the script. It teaches you *why* each probe exists and *how* the tokenizer was dissected.

## What the suite is for

`testes.sh` is a set of **diagnostic probes** against the llama.cpp server on `localhost:8080`.
It answers one question at a time: **which layer of the stack is failing?**

```
Question → tokenizer → embedding → attention → reasoning → answer
                 ↑                    ↑            ↑
        SPELL probes          ARITH probes   REASON probes
```

If a probe fails, the failure lives somewhere between the tokenizer and that stage.

## The four probe categories

### 1. ARITH — tests attention + reasoning
`2+2`, `7*8`. These are single-step computations. They fail badly when the **KV cache is
quantized to q4_0** (the "222" bug from Week 2). A model that passes ARITH but fails SPELL is
healthy — see section "Why strawberry fails".

### 2. SPELL — tests the tokenizer, not the model
"Count the r's in *strawberry*." This is a **character-level** question. The model has no direct
access to characters (see the token trace below). Its answer is a guess reconstructed from
training memory — so it flails.

### 3. CONTROL — the isolation test
Same question, but with **hyphenated spelling** `s-t-r-a-w-b-e-r-r-y`. Hyphens force the
tokenizer to emit single-letter tokens. If CONTROL passes and SPELL fails, you have **proven**
the problem is tokenization, not model quality.

### 4. REASON — higher-level reasoning
Word-sense and classic puzzle questions. These exercise long-range attention and world knowledge.

## The token trace (how "strawberry" was dissected)

Every word the model reads is first split into **token IDs** — numbers — by the tokenizer.
The model never processes raw text, only these numbers.

I used two native llama.cpp endpoints to see the split:

### Step 1 — tokenize the word

```bash
curl -s http://localhost:8080/tokenize \
  -H "Content-Type: application/json" \
  -d '{"content":"strawberry"}'
```

Response:

```json
{"tokens":[495, 672, 15357]}
```

So `strawberry` = **3 token IDs**, not 10 letters.

### Step 2 — decode each token back to text

```bash
curl -s http://localhost:8080/detokenize \
  -H "Content-Type: application/json" \
  -d '{"tokens":[495]}'
```

Result of decoding all three:

| token ID | text piece |
|----------|-----------|
| 495      | `str`     |
| 672      | `aw`      |
| 15357    | `berry`   |

### Step 3 — the crucial variant: leading space

```bash
curl -s http://localhost:8080/tokenize \
  -H "Content-Type: application/json" \
  -d '{"content":" strawberry"}'
```

```json
{"tokens":[72600]}
```

With a space in front (as it appears inside real sentences), **`strawberry` is ONE single token: 72600.**

## The representation — what tokens actually are

- Each token ID is an index into the model's **vocabulary table** (~152,000 entries for Qwen2.5).
- Vocabulary entries were learned by **byte-pair encoding (BPE)**: the most common character
  chunks got their own ID. `str`, `aw`, `berry` are all frequent chunks, so they became tokens.
- The letters `s-t-r-a-w-b-e-r-r-y` are **not individually addressable** — several never appear
  as standalone tokens in normal text, and even when they do, the word arrives as one opaque ID.

## Why counting r's fails — the chain

1. Model receives `strawberry` → token ID `72600` (or `495 672 15357`).
2. It has **no mechanism to split a token back into letters.** Tokens are atomic input units.
3. To answer "how many r's", it must *imagine* the spelling from memory. For `berry` (one chunk),
   the double-r is hidden inside the chunk. The model guesses — often 3 r's instead of 3 r's,
   or a confident wrong number.
4. Contrast: `s-t-r-a-w-b-e-r-r-y` → the tokenizer emits one token per letter → the model can
   literally count 10 tokens and see two r's. It nails it.

## How to reproduce the whole trace yourself

```bash
# server must be running:  configs/QUICK_START.md launch command
cd scripts
./testes.sh          # run the full probe suite (default: 3 runs per probe)
./testes.sh 5        # or: 5 runs per probe for more signal

# ad-hoc tokenizer inspection
curl -s http://localhost:8080/tokenize   -H "Content-Type: application/json" -d '{"content":"strawberry"}'
curl -s http://localhost:8080/detokenize -H "Content-Type: application/json" -d '{"tokens":[495,672,15357]}'
```

## Reading the results

| observation | verdict |
|---|---|
| ARITH wrong ("222") | KV cache quantized too low → switch to f16/q8_0 (Week 2 bug) |
| SPELL wrong, CONTROL right | **tokenizer expected behavior — model is healthy** |
| SPELL right, CONTROL right | model has learned letter decomposition well |
| SPELL wrong, CONTROL wrong | model quality / context window issue → deeper debugging |
| REASON wrong at long context | possible YARN stretch artifact or cache degradation |

## Extra tests you can add (homework)

Try these in `testes.sh` and trace their tokens the same way:

- `rhythm`, `assess`, `Mississippi` (letter counting with repeated letters)
- `11*12`, `99+1` (multi-digit arithmetic — tests positional attention)
- A paragraph with a single fact planted at the start, then asked at the end (tests long-context recall)
