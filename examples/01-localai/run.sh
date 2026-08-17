#!/usr/bin/env sh
#
# Example 1 — LocalAI inference.
# Recipe: docs/05-recipes/localai-chat.md
#
# Shows: model listing, one chat completion, and the difference between a cold
# and a warm call. Two processes are involved even though you only started one
# container — see the backend note at the end.

. "$(dirname "$0")/../lib.sh"

step "1. The inference runtime is reachable"
require_localai "$LLM_MODEL"
note "/readyz means the LISTENER is up, not that a model is loaded"

step "2. What models are installed"
printf '%s$ curl -s %s/v1/models | jq -r ".data[].id"%s\n' "$C_DIM" "$LOCALAI_URL" "$C_OFF"
curl -s "${LOCALAI_URL}/v1/models" | jqr '.data[].id'

step "3. Which backend is installed"
note "LocalAI ships with zero backends; the first model install pulls one"
if command -v docker >/dev/null 2>&1; then
  docker exec localai ls /backends 2>/dev/null \
    || note "(skipped — container not named 'localai', or docker unavailable)"
else
  note "(skipped — docker not available)"
fi

step "4. A chat completion"
note "max_tokens is 600, deliberately: see the note after the answer"
start=$(date +%s)
resp=$(curl -s --max-time 600 "${LOCALAI_URL}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${LLM_MODEL}\",
       \"messages\":[{\"role\":\"user\",\"content\":\"In one sentence, what is a vector embedding?\"}],
       \"max_tokens\":600}")
elapsed=$(seconds_since "$start")

case "$resp" in
  *'"choices"'*) ok "completion returned in ${elapsed}s" ;;
  *) die "no choices in the response: $(printf '%s' "$resp" | head -c 300)" \
       "See docs/01-localai/troubleshooting.md#inference-fails-or-hangs" ;;
esac

printf '\n%s\n' "$(printf '%s' "$resp" | jqr '.choices[0].message.content')"

finish=$(printf '%s' "$resp" | jqr '.choices[0].finish_reason')
note "finish_reason: ${finish}"
if [ "$finish" = "length" ]; then
  printf '  %swarn%s  content may be EMPTY: the reply hit max_tokens\n' "$C_BAD" "$C_OFF"
  note "qwen3 is reasoning-tuned. Observed: max_tokens=128 spends all 128 tokens"
  note "reasoning and returns content:'' with finish_reason:'length'. It needed"
  note "371 completion tokens to answer this question in one sentence."
fi

step "5. Cold versus warm"
note "the first call above may have included a model load"
start=$(date +%s)
curl -s -o /dev/null --max-time 300 "${LOCALAI_URL}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${LLM_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}"
warm=$(seconds_since "$start")
ok "warm call: ${warm}s   (first call above: ${elapsed}s)"
note "a slow first call and a fast second is a model load, not a fault"

step "6. Token usage IS reported here"
printf '%s' "$resp" | jqr '.usage'
note "contrast with an agent request, where usage is hardcoded to zero"

step "Done"
note "nothing was persisted: no conversation, no state — that starts in example 04"
note "reference: observed 4s including model load, CPU-only arm64"
