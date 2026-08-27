#!/bin/bash
# testes.sh — model probe suite for llama.cpp server on localhost:8080
# Categories: ARITH / SPELL / REASON / CONTROL
# Companion guide: testes.md in this same folder.
# NOTE: max_tokens=512 — reasoning models (LFM2.5 etc.) burn 100+ tokens of
# CoT in `reasoning_content` BEFORE writing anything into `content`.

API="http://localhost:8080/v1/chat/completions"
TOK="http://localhost:8080/tokenize"
DETOK="http://localhost:8080/detokenize"
RUNS="${1:-3}"   # how many times to repeat each probe (default 3)
SLEEP=2

ask() {
	# $1 = label, $2 = question
	echo "=== $1 ==="
	for i in $(seq 1 "$RUNS"); do
		echo "--- run $i ---"
		curl -s --max-time 120 "$API" \
			-H "Content-Type: application/json" \
			-d "{\"messages\":[{\"role\":\"user\",\"content\":\"$2\"}],\"max_tokens\":512}" \
			| python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    m=d['choices'][0]['message']
    rc=(m.get('reasoning_content') or '').strip()
    if rc:
        head=rc[:160].replace(chr(10),' ')
        print('[think  ]', head + ('...' if len(rc)>160 else ''))
    c=(m.get('content') or '').strip()
    print('[answer ]', c if c else '(EMPTY - budget died inside thinking)')
except Exception as e:
    print('ERROR:', e)"
		sleep $SLEEP
	done
}

echo "########################################"
echo "# 1. ARITHMETIC — tests reasoning + attention"
echo "#    (this is the probe that broke with q4_0 KV cache)"
echo "########################################"
ask "ARITH: what is 2+2" "What is 2+2? Answer in one short sentence."

ask "ARITH: multiply 7*8" "What is 7 times 8? Answer in one short sentence."

echo
echo "########################################"
echo "# 2. SPELLING — tests the TOKENIZER (why 'r in strawberry' fails)"
echo "########################################"
ask "SPELL: count r in strawberry" "How many letter r's are in the word strawberry? Answer with just a number and one short sentence."

echo
echo "########################################"
echo "# 3. CONTROL — hyphenated spelling forces single-letter tokens"
echo "#    If this PASSES but the plain spelling FAILS, the problem is"
echo "#    tokenization, NOT model quality."
echo "########################################"
ask "CONTROL: count r in s-t-r-a-w-b-e-r-r-y" "How many letter r's are in s-t-r-a-w-b-e-r-r-y? Answer with just a number and one short sentence."

ask "CONTROL: reverse strawberry" "Write the word strawberry backwards, one letter at a time."

echo
echo "########################################"
echo "# 4. REASONING — higher-level, tests chain-of-thought"
echo "########################################"
ask "REASON: apple is fruit" "An apple is a fruit. A carrot is a vegetable. What is a tomato? Answer in one short sentence."

ask "REASON: three switches" "There are 3 light switches and 3 rooms. You may enter each room once. How do you determine which switch controls which light?"

echo
echo "########################################"
echo "# 5. TOKENIZER INSPECTION — raw token IDs for 'strawberry'"
echo "#    Shows WHY spelling probes fail: no single-letter tokens."
echo "########################################"
for word in "strawberry" " strawberry"; do
	echo "--- tokenize '$word' ---"
	curl -s --max-time 10 "$TOK" -H "Content-Type: application/json" -d "{\"content\":\"$word\"}" \
		| python3 -c "import sys,json; print('token IDs:', json.load(sys.stdin).get('tokens'))"
	echo "--- decode each token back to text ---"
	TOKENS=$(curl -s --max-time 10 "$TOK" -H "Content-Type: application/json" -d "{\"content\":\"$word\"}" \
		| python3 -c "import sys,json; print(' '.join(map(str, json.load(sys.stdin).get('tokens',[]))))")
	for t in $TOKENS; do
		curl -s --max-time 5 "$DETOK" -H "Content-Type: application/json" -d "{\"tokens\":[$t]}" \
			| python3 -c "import sys,json; print('  token $t ->', repr(json.load(sys.stdin)['content']))"
	done
	sleep $SLEEP
done

echo
echo "DONE. Compare SPELL vs CONTROL results to isolate tokenizer vs model."
