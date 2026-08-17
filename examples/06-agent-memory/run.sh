#!/usr/bin/env sh
#
# Example 6 — an agent with knowledge.
# Recipe: docs/05-recipes/agent-with-knowledge.md
#
# All three projects at once. Proves retrieval happened by asking about a fact
# that exists only in the collection. Creates agent+collection 'example-kb'.

. "$(dirname "$0")/../lib.sh"
AGENT=example-kb

step "1. All layers below"
require_localai "$LLM_MODEL"
require_localai "$EMBEDDING_MODEL"
require_localrecall
require_localagi

step "2. Can LocalAGI reach LocalRecall?"
if command -v docker >/dev/null 2>&1; then
  docker exec localagi curl -s -o /dev/null -w 'localrecall from inside localagi: %{http_code}\n' \
    http://localrecall:8080/api/collections 2>/dev/null \
    || note "(skipped — container not named 'localagi')"
fi
note "on LocalAGI v2.8.1 there is NO in-process knowledge layer:"
note "LOCALAGI_LOCALRAG_URL is REQUIRED, not optional"

step "3. Create the agent — its NAME determines the collection name"
curl -s -X POST "${LOCALAGI_URL}/api/agent/create" -H 'Content-Type: application/json' \
  -d "{\"name\":\"${AGENT}\",\"model\":\"${LLM_MODEL}\",
       \"system_prompt\":\"Answer using only the provided context. Be terse.\",
       \"strip_thinking_tags\":true,
       \"enable_kb\":true,\"kb_auto_search\":true,\"kb_results\":3,
       \"max_attempts\":1}" | pretty
curl -s "${LOCALAGI_URL}/api/agent/${AGENT}/config" | jqr '{enable_kb, kb_auto_search, kb_results}'
note "all three of those must be true, and they log at DEBUG only when false"

step "4. Create the matching collection — lowercased agent name"
curl -s -X POST "${LOCALRECALL_URL}/api/collections" -H 'Content-Type: application/json' \
  -d "{\"name\":\"${AGENT}\"}" | pretty

step "5. Ingest a fact no model can know"
tmpdir=$(mktemp -d -t example06) || die "mktemp failed"
cat > "${tmpdir}/zeppelin.txt" <<'TXT'
The Zeppelin-7 telemetry bus uses a heartbeat interval of 4200 milliseconds.
Operators must never set the Zeppelin-7 heartbeat below 900 milliseconds because
the flight controller drops frames at that rate.
TXT
curl -s --max-time 300 -X POST "${LOCALRECALL_URL}/api/collections/${AGENT}/upload" \
  -F "file=@${tmpdir}/zeppelin.txt" | jqr '.data.key'
rm -rf "$tmpdir"

step "6. Prove retrieval works BEFORE involving the agent"
n=$(curl -s -X POST "${LOCALRECALL_URL}/api/collections/${AGENT}/search" \
  -H 'Content-Type: application/json' \
  -d '{"query":"Zeppelin-7 heartbeat interval","max_results":3}' | jqr '.data.count')
[ "$n" = "0" ] && die "direct search found nothing" \
  "The agent cannot retrieve what LocalRecall cannot find."
ok "direct search returned ${n} result(s)"

step "7. Ask the agent"
start=$(date +%s)
resp=$(curl -s --max-time 900 "${LOCALAGI_URL}/v1/responses" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${AGENT}\",
       \"input\":\"What heartbeat interval does the Zeppelin-7 telemetry bus use?\"}")
elapsed=$(seconds_since "$start")
answer=$(printf '%s' "$resp" | jqr '.output[0].content[0].text')
printf '\n%s\n' "$answer"
case "$answer" in
  *4200*) ok "answered from retrieved knowledge in ${elapsed}s" ;;
  *) printf '  %swarn%s  the answer does not contain 4200 — retrieval may not have run\n' \
       "$C_BAD" "$C_OFF"
     note "check: docker logs localagi 2>&1 | grep -i 'knowledge base'" ;;
esac
note "'Zeppelin-7' was invented, so 4200 could only come from the collection"

step "8. Proof it crossed a process boundary"
if command -v docker >/dev/null 2>&1; then
  docker logs localagi 2>&1 | grep -i 'Found similar strings' | tail -1 | cut -c1-200
  docker logs localrecall 2>&1 | grep "collections/${AGENT}/search" | tail -1
fi
note "matching timestamps on both sides is how you prove the hop happened"
note "reference: retrieval was 29-37 ms of a 2.27 s request"

step "9. Cleanup — BOTH are needed"
curl -s -o /dev/null -X DELETE "${LOCALAGI_URL}/api/agent/${AGENT}"
curl -s -o /dev/null -X POST "${LOCALRECALL_URL}/api/collections/${AGENT}/reset"
ok "deleted the agent and reset the collection"
note "deleting an agent leaves its collection; they are separate objects"
