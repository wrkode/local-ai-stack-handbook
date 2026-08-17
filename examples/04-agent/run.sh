#!/usr/bin/env sh
#
# Example 4 — a simple agent.
# Recipe: docs/05-recipes/simple-agent.md
#
# Shows: agent creation, /v1/responses, conversation chaining, and the three
# indistinguishable conversation states. Creates agent 'example-simple'.

. "$(dirname "$0")/../lib.sh"
AGENT=example-simple

step "1. Layers below"
require_localai "$LLM_MODEL"
require_localagi

step "2. Create an agent"
curl -s -X POST "${LOCALAGI_URL}/api/agent/create" -H 'Content-Type: application/json' \
  -d "{\"name\":\"${AGENT}\",\"model\":\"${LLM_MODEL}\",
       \"system_prompt\":\"You are a terse assistant. Answer in one short sentence.\",
       \"strip_thinking_tags\":true,\"enable_kb\":false,\"max_attempts\":1}" | pretty

step "3. The pool now reports it"
curl -s "${LOCALAGI_URL}/api/agents" | pretty
note "'actions' and 'connectors' are what is COMPILED IN, not what this agent has"

step "4. A request — note that 'model' is the AGENT name"
start=$(date +%s)
resp=$(curl -s --max-time 600 "${LOCALAGI_URL}/v1/responses" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${AGENT}\",\"input\":\"What is 2+2? Answer with just the number.\"}")
elapsed=$(seconds_since "$start")
case "$resp" in
  *'"output"'*) ok "answered in ${elapsed}s" ;;
  *'Agent not found'*) die "Agent not found" \
    "The 'model' field carries an AGENT name here, not a model name." ;;
  *) die "unexpected: $(printf '%s' "$resp" | head -c 300)" \
    "See docs/02-localagi/troubleshooting.md" ;;
esac
printf '%s\n' "$(printf '%s' "$resp" | jqr '.output[0].content[0].text')"

step "5. What the envelope does NOT give you"
printf '%s' "$resp" | jqr '{id, usage, store, previous_response_id}'
note "usage is hardcoded to zero; id is a bare UUID, not resp_...;"
note "previous_response_id is echoed as null even when you send one"

step "6. Conversation chaining"
r1=$(curl -s --max-time 600 "${LOCALAGI_URL}/v1/responses" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${AGENT}\",\"input\":\"My favourite colour is teal. Please remember it.\"}")
id=$(printf '%s' "$r1" | jqr '.id')
note "response id: ${id}"
note "use jq -r .id — a greedy regex grabs the msg_... id inside output[0] instead"
curl -s --max-time 600 "${LOCALAGI_URL}/v1/responses" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${AGENT}\",\"input\":\"What is my favourite colour?\",\"previous_response_id\":\"${id}\"}" \
  | jqr '.output[0].content[0].text'

step "7. An unknown previous_response_id does NOT error"
curl -s --max-time 600 "${LOCALAGI_URL}/v1/responses" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${AGENT}\",\"input\":\"What is my favourite colour?\",\"previous_response_id\":\"does-not-exist\"}" \
  | jqr '.output[0].content[0].text'
note "HTTP 200, no warning. Valid-but-new, expired and never-existed are"
note "indistinguishable — history is in memory with a 1h default TTL."

step "8. Cleanup"
curl -s -o /dev/null -X DELETE "${LOCALAGI_URL}/api/agent/${AGENT}"
ok "deleted '${AGENT}'"
note "the agent DEFINITION was on disk; the conversations never were"
