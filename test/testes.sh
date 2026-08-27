#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

health_result="FAIL"
models_result="FAIL"
props_result="FAIL"
probe_result="FAIL"

if [[ "$(curl -fsS "${BASE_URL}/health")" == "ok" ]]; then
  health_result="PASS"
fi

models_json="$(curl -fsS "${BASE_URL}/v1/models")"
if python3 -c 'import json,sys;data=json.load(sys.stdin);print("true" if any("LFM2.5-8B-A1B" in i.get("id","") for i in data.get("data",[])) else "false")' <<<"${models_json}" | grep -q '^true$'; then
  models_result="PASS"
fi

props_json="$(curl -fsS "${BASE_URL}/props")"
if python3 -c 'import json,sys;d=json.load(sys.stdin);print("true" if int(d.get("n_ctx_train",0) or 0)>0 else "false")' <<<"${props_json}" | grep -q '^true$'; then
  props_result="PASS"
fi

if python3 "${ROOT_DIR}/test/probe_ctx.py" >/tmp/probe_ctx.out; then
  probe_result="PASS"
fi

printf "%-30s %s\n" "CHECK" "RESULT"
printf "%-30s %s\n" "health endpoint" "${health_result}"
printf "%-30s %s\n" "openai models endpoint" "${models_result}"
printf "%-30s %s\n" "props endpoint" "${props_result}"
printf "%-30s %s\n" "context probe" "${probe_result}"

if [[ "${health_result}${models_result}${props_result}${probe_result}" == "PASSPASSPASSPASS" ]]; then
  printf "%-30s %s\n" "overall" "PASS"
else
  printf "%-30s %s\n" "overall" "FAIL"
  cat /tmp/probe_ctx.out || true
  exit 1
fi
