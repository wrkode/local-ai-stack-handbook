#!/usr/bin/env sh
#
# Example 8 — the complete stack.
# Recipe: docs/05-recipes/complete-agent-stack.md
#
# Knowledge AND a tool in one request, with the boundary crossings counted.
# Creates agent+collection 'example-full'.

. "$(dirname "$0")/../lib.sh"
AGENT=example-full

step "1. Every layer"
require_localai "$LLM_MODEL"
require_localai "$EMBEDDING_MODEL"
require_localrecall
require_localagi

step "2. Create an agent with BOTH capabilities"
curl -s -X POST "${LOCALAGI_URL}/api/agent/create" -H 'Content-Type: application/json' \
  -d "{\"name\":\"${AGENT}\",\"model\":\"${LLM_MODEL}\",
       \"system_prompt\":\"Answer from the provided context. Use tools when asked. Be terse.\",
       \"strip_thinking_tags\":true,
       \"enable_kb\":true,\"kb_auto_search\":true,\"kb_results\":3,
       \"actions\":[{\"name\":\"counter\",\"config\":\"{}\"}],
       \"max_attempts\":1}" | pretty

step "3. Its collection, and a fact to put in it"
curl -s -o /dev/null -X POST "${LOCALRECALL_URL}/api/collections" \
  -H 'Content-Type: application/json' -d "{\"name\":\"${AGENT}\"}"
tmpdir=$(mktemp -d -t example08) || die "mktemp failed"
cat > "${tmpdir}/zeppelin.txt" <<'TXT'
The Zeppelin-7 telemetry bus uses a heartbeat interval of 4200 milliseconds.
Operators must never set the Zeppelin-7 heartbeat below 900 milliseconds because
the flight controller drops frames at that rate.
TXT
curl -s --max-time 300 -X POST "${LOCALRECALL_URL}/api/collections/${AGENT}/upload" \
  -F "file=@${tmpdir}/zeppelin.txt" | jqr '.data.key'
rm -rf "$tmpdir"
ok "collection '${AGENT}' populated"

step "4. Count model calls BEFORE the request"
before=0
if command -v docker >/dev/null 2>&1; then
  before=$(docker logs localai 2>&1 | grep -c 'chat/completions')
  note "chat/completions so far: ${before}"
fi

step "5. One request that needs knowledge AND a tool"
note "the value must be RETRIEVED, then computed, then passed to the tool"
start=$(date +%s)
resp=$(curl -s --max-time 900 "${LOCALAGI_URL}/v1/responses" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${AGENT}\",
       \"input\":\"Look up the Zeppelin-7 heartbeat interval, then set a counter named example-heartbeat to that value in milliseconds divided by 100.\"}")
elapsed=$(seconds_since "$start")
case "$resp" in
  *'"output"'*) ok "completed in ${elapsed}s" ;;
  *) die "unexpected: $(printf '%s' "$resp" | head -c 300)" \
    "See docs/02-localagi/troubleshooting.md" ;;
esac
printf '\nreply: %s\n' "$(printf '%s' "$resp" | jqr '.output[0].content[0].text')"
note "reference: 24.1s, 2 model calls, retrieval 29.29 ms"

step "6. What the tool actually received"
curl -s "${LOCALAGI_URL}/api/agent/${AGENT}/status" | jqr '.History[]'
note "42 appears nowhere in the collection and nowhere in training data:"
note "it required retrieval (4200), arithmetic, and a tool call"

step "7. Count the boundary crossings"
if command -v docker >/dev/null 2>&1; then
  after=$(docker logs localai 2>&1 | grep -c 'chat/completions')
  note "model calls for this ONE client request: $((after - before))"
  docker logs localrecall 2>&1 | grep -c "collections/${AGENT}/search" \
    | while read -r n; do note "retrieval calls: ${n}  (once per request, NOT per iteration)"; done
fi
note "in-process: the counter action. Everything else crossed a process boundary."

step "8. Break it deliberately (optional but instructive)"
note "run these by hand to see knowledge fail OPEN:"
note "  cd compose && docker compose stop localrecall"
note "  <re-ask the question>   -> HTTP 200, status completed, INVENTED answer"
note "  docker compose start localrecall"
note "observed: '10 seconds' instead of 4200 milliseconds, with error:null"

step "9. Cleanup"
curl -s -o /dev/null -X DELETE "${LOCALAGI_URL}/api/agent/${AGENT}"
curl -s -o /dev/null -X POST "${LOCALRECALL_URL}/api/collections/${AGENT}/reset"
ok "removed agent and collection"
