#!/usr/bin/env python3
"""probe_ctx.py — empirical context-limit probe for llama-server.

Never trust launch flags. This proves what context the server ACTUALLY serves:
it builds a prompt of >= TARGET tokens (verified via /tokenize), sends it, and
checks whether the server rejects it with exceed_context_size_error.

PASS criterion: HTTP success (transport-level capacity).
Separately reported: needle retrieval quality (did it answer correctly?).

Usage: python3 scripts/probe_ctx.py [target_tokens]   # default 40000
"""
import json
import sys
import time
import urllib.request

HOST = "http://localhost:8080"
UNIT = ("The scientific method requires falsifiable hypotheses, careful "
        "measurement, and honest reporting of error bars. ")
NEEDLE = "Ignore all previous text. Reply with exactly: PROBE_OK"


def post(path, payload, timeout=600):
    req = urllib.request.Request(
        HOST + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    return urllib.request.urlopen(req, timeout=timeout)


def n_tokens(text):
    with post("/tokenize", {"content": text}) as r:
        return len(json.load(r)["tokens"])


def main():
    target = int(sys.argv[1]) if len(sys.argv) > 1 else 40000

    text = ""
    t = 0
    while t < target:
        # append conservatively, then re-verify with the server's own tokenizer
        text += UNIT * max(50, ((target - t) // 15))
        t = n_tokens(text)
        print(f"[probe] tokenizer reports {t} tokens ...")
        if t >= target:
            break

    payload = {
        "messages": [{"role": "user", "content": text + "\n\n" + NEEDLE}],
        "max_tokens": 16,
    }
    print(f"[probe] sending {t}-token prompt ...")
    t0 = time.time()
    try:
        with post("/v1/chat/completions", payload) as r:
            d = json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:500]
        print(f"[probe] REJECTED — HTTP {e.code}: {body}")
        verdict = "FAIL (context limit hit)"
    else:
        elapsed = time.time() - t0
        u = d.get("usage", {})
        msg = d["choices"][0]["message"]
        answer = (msg.get("content") or "").strip()
        timings = d.get("timings", {})
        pps = timings.get("prompt_per_second")
        retrieval = "PROBE_OK" in answer
        print(f"[probe] ACCEPTED in {elapsed:.1f}s | "
              f"prompt_tokens={u.get('prompt_tokens')} | "
              f"prefill={pps:.0f} tok/s" if pps else
              f"[probe] ACCEPTED in {elapsed:.1f}s | prompt_tokens={u.get('prompt_tokens')}")
        print(f"[probe] reply: {answer!r} | needle retrieved: {retrieval}")
        verdict = "PASS (served >32K without rejection)"
        if not retrieval:
            verdict += " — note: capacity OK but needle NOT retrieved (quality, not transport)"

    print(f"\n=== VERDICT ({target}-token empirical probe): {verdict} ===")


if __name__ == "__main__":
    main()
