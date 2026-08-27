# Test: Hermes + llama.cpp — Foundations Through Deployment

> **Purpose:** Verify understanding before advancing to Phase 2.
> **Format:** 40 questions — open-ended, scenario-based, command-focused.
> **No answers provided.** Answer from memory. I will grade each response.
> **Passing grade:** 80% (32/40)
> **Time limit:** 45 minutes

---

## Section 1: Foundations (10 questions)

### 1.1
What is GGUF format and why does llama.cpp use it instead of other model formats?

### 1.2
Explain the difference between quantizing model weights (Q4_0) and quantizing the KV cache (q4_0). What happens to reasoning accuracy when you quantize the KV cache to 4-bit?

### 1.3
LFM2.5-8B-A1B has 8.3B total parameters but only ~1B active per token. What is this architecture called, and why does it run fast on a 6GB GPU despite being "8B"?

### 1.4
Write the KV cache formula. Using your hardware (RTX 3060, 6GB VRAM), calculate the KV cache size for 16K context with f16 cache type.

### 1.5
What is the difference between:
- **Working context** (the 64K context window)
- **Persistent memory** (FTS5 search across sessions)

Which one does Hermes require as a minimum, and why?

### 1.6
Explain what `-ngl 99` does. What happens if you set `-ngl 0`?

### 1.7
What is flash attention (`-fa on`), and why is it important for large context windows?

### 1.8
A model file on disk is 4.84GB. When loaded with `-ngl 99`, `nvidia-smi` shows 5679 MiB VRAM used. Why isn't VRAM usage exactly 4.84GB?

### 1.9
What is the difference between `--jinja` and `--chat-template` flags in llama-server?

### 1.10
Explain what `--cache-type-k q8_0 --cache-type-v q8_0` does. Why did removing these flags (defaulting to f16) fix the reasoning accuracy problem in week 2?

---

## Section 2: Architecture (10 questions)

### 2.1
Draw the Hermes agent loop. What are the 6 phases from user input to response?

### 2.2
What is the difference between SOUL.md and AGENTS.md? Which one controls the agent's personality, and which one controls project-specific instructions?

### 2.3
In `config.yaml`, you have:
```yaml
model:
    provider: llama-server
    base_url: http://127.0.0.1:8080/v1
providers:
    llama-server:
        api: http://127.0.0.1:8080/v1
```
If you remove the `providers:` section but keep `model.base_url`, will Hermes connect to llama-server? Why or why not?

### 2.4
You edit `config.yaml` while Hermes is running. Does the change take effect immediately? What must you do?

### 2.5
What does `hermes --provider llama-server` do that `hermes` alone does not?

### 2.6
Explain the difference between:
- `hermes gateway run` (foreground)
- `hermes gateway install` + `hermes gateway start` (background service)

When would you use each?

### 2.7
What tool does Hermes use to execute shell commands? What tool does it use to search files? What tool does it use to read file contents?

### 2.8
When Hermes receives a tool call result, what does it do with it before generating the next response?

### 2.9
What is the `reasoning_content` field in the API response, and which models produce it?

### 2.10
How does Hermes decide whether to use native OpenAI tool_calls vs text-based `<action>` JSON blocks?

---

## Section 3: Testing Methodology (10 questions)

### 3.1
Name the 4 layers of the testing framework. For each, give the question it answers and one tool that tests it.

### 3.2
Why do we run quality probes 3-4 times instead of once? Give an example of a fluke vs a systematic failure.

### 3.3
What is the difference between a **capacity** test and a **retrieval** test? Can a model pass capacity but fail retrieval?

### 3.4
Explain the purpose of the SPELL vs CONTROL probes (strawberry vs s-t-r-a-w-b-e-r-r-y). What does each tell you?

### 3.5
What happened when we ran `max_tokens=80` on LFM2.5-8B-A1B? What was the root cause, and how did we fix it?

### 3.6
Write the command to run the quality floor test with 4 repetitions per probe.

### 3.7
What is the verdict table format? Give an example row with a PASS result.

### 3.8
Why is "never trust flags, trust observations" a core principle? Give an example from our session where a flag was wrong.

### 3.9
Write the command to build a 40K-token prompt and send it to the server. What does PASS mean in this context?

### 3.10
What is the difference between a **transport pass** and a **quality pass** in the context probe?

---

## Section 4: Debugging Scenarios (5 questions)

### 4.1
Your model returns garbage answers (e.g., "222 is an even-digit numbernumber"). The API shows HTTP 200. The server logs show no errors. What do you check first, and why?

### 4.2
Hermes starts but shows "Provider: custom" and connects to port 11434 instead of 8080. You've verified `config.yaml` has `model.provider: llama-server` and `base_url: http://127.0.0.1:8080/v1`. What is the most likely cause?

### 4.3
You run `hermes gateway run` and see:
```
[Telegram] Connecting to Telegram (attempt 1/8)…
```
Then nothing for 20 minutes. The bot token works (verified via curl). What do you investigate?

### 4.4
You move your project from `/mnt/c/Users/...` to `~/Hermes_Learning/`. When you try to run `./llama.cpp/build/bin/llama-server`, you get:
```
error while loading shared libraries: libllama-server-impl.so: cannot open shared object file
```
What is the root cause, and how do you fix it?

### 4.5
Your test script shows empty answers for the "r in strawberry" probe. The ARITH probes work fine. What is the likely cause?

---

## Section 5: Practical Commands (5 questions)

### 5.1
Write the complete command to start llama-server with your configuration (LFM2.5-8B-A1B Q4_0, 64K context, flash attention, jinja, q8_0 KV cache). Include the LD_LIBRARY_PATH fix.

### 5.2
Write the command to check:
- Server health
- Model loaded
- Context size
- VRAM usage

### 5.3
Write the commands to:
1. Stop the gateway
2. Install as systemd service
3. Start the service
4. Check if it's running

### 5.4
Write the command to monitor live gateway interactions, filtered for inbound messages and responses only.

### 5.5
Write the command to verify your Telegram bot token is valid, using the Telegram API directly (not through Hermes).

---

## Grading Criteria

| Grade | Score | Meaning |
|---|---|---|
| A | 90-100% | Ready for Phase 2 |
| B | 80-89% | Pass — review missed questions |
| C | 70-79% | Conditional — explain 3 missed concepts |
| F | <70% | Fail — re-study, retake |

## Instructions

1. Answer all 40 questions
2. Write your answers in `test/answers.md`
3. I will grade each answer and provide feedback
4. You must pass before moving to Phase 2

**Time starts now. Good luck.**
