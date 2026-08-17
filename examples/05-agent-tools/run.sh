#!/usr/bin/env sh
#
# Example 5 — an agent with a tool.
# Recipe: docs/05-recipes/agent-with-tools.md
#
# Shows: the tool schema the model sees, a direct tool run, the agent choosing
# to call it, and why tool HISTORY is ground truth rather than the reply.

. "$(dirname "$0")/../lib.sh"
AGENT=example-tools

step "1. Layers below"
require_localai "$LLM_MODEL"
require_localagi

step "2. How many built-in actions exist"
curl -s "${LOCALAGI_URL}/api/actions" | jqr '. | length'
note "these execute IN-PROCESS. They are not MCP."

step "3. The schema the model will be shown"
curl -s -X POST "${LOCALAGI_URL}/api/action/counter/definition" \
  -H 'Content-Type: application/json' -d '{}' | pretty
note "when an agent misuses a tool, this description is usually why"

step "4. Run the tool with NO agent involved"
note "this separates 'the tool is broken' from 'the model will not choose it'"
curl -s -X POST "${LOCALAGI_URL}/api/action/counter/run" -H 'Content-Type: application/json' \
  -d '{"config":{},"params":{"name":"example-widgets","adjustment":3}}' | pretty

step "5. Create an agent that HAS the tool"
note "config is a JSON STRING, not an object — the commonest mistake here"
curl -s -X POST "${LOCALAGI_URL}/api/agent/create" -H 'Content-Type: application/json' \
  -d "{\"name\":\"${AGENT}\",\"model\":\"${LLM_MODEL}\",
       \"system_prompt\":\"You use tools when asked. Be terse.\",
       \"strip_thinking_tags\":true,
       \"actions\":[{\"name\":\"counter\",\"config\":\"{}\"}],
       \"max_attempts\":1}" | pretty

curl -s "${LOCALAGI_URL}/api/agent/${AGENT}/config" | jqr '.actions'

step "6. Ask for something that needs two steps"
start=$(date +%s)
resp=$(curl -s --max-time 900 "${LOCALAGI_URL}/v1/responses" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${AGENT}\",
       \"input\":\"Increase the counter named example-apples by 7, then tell me its value.\"}")
elapsed=$(seconds_since "$start")
case "$resp" in
  *'"output"'*) ok "completed in ${elapsed}s" ;;
  *) die "unexpected: $(printf '%s' "$resp" | head -c 300)" \
    "See docs/02-localagi/troubleshooting.md" ;;
esac
printf '\nreply: %s\n' "$(printf '%s' "$resp" | jqr '.output[0].content[0].text')"
note "reference: 38.7s for three model calls on CPU"

step "7. What ACTUALLY ran — this is ground truth"
curl -s "${LOCALAGI_URL}/api/agent/${AGENT}/status" | jqr '.History[]'
note "compare the tool Results above against the reply's prose."
note "Observed once: two correct calls returning 7, and a reply claiming 14."
note "The tools were right; the 1.7B model's summary was not."
note "History is truth; the reply is a summary by the weakest component."

step "8. Cleanup"
curl -s -o /dev/null -X DELETE "${LOCALAGI_URL}/api/agent/${AGENT}"
ok "deleted '${AGENT}'"
note "counter values are not exposed for deletion by any endpoint"
