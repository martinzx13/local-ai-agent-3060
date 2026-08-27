#!/usr/bin/env python3
import json
import os
import sys
import urllib.request

base_url = os.environ.get("BASE_URL", "http://127.0.0.1:8080").rstrip("/")

try:
    with urllib.request.urlopen(f"{base_url}/props", timeout=10) as response:
        props = json.loads(response.read().decode("utf-8"))
except Exception as exc:  # pragma: no cover - runtime diagnostics
    print(f"ERROR: unable to query {base_url}/props: {exc}")
    sys.exit(1)

n_ctx_train = int(props.get("n_ctx_train", 0) or 0)
n_ctx = int(props.get("n_ctx", 0) or 0)
usable_ctx = min(n_ctx, n_ctx_train) if n_ctx_train else n_ctx

print(f"n_ctx_train={n_ctx_train}")
print(f"n_ctx={n_ctx}")
print(f"usable_ctx={usable_ctx}")

if n_ctx_train and n_ctx > n_ctx_train:
    print("status=FAIL")
    sys.exit(1)

print("status=OK")
