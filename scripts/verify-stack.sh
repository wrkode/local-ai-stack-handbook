#!/usr/bin/env bash
#
# verify-stack.sh — progressive verification of a LocalAI / LocalAGI /
# LocalRecall deployment.
#
# Checks run in dependency order and STOP at the first failure, because a
# failure at layer N makes every result after it meaningless. That ordering is
# the whole point: it tells you which layer to debug, not merely that something
# is wrong.
#
#   inference -> embeddings -> vector store -> retrieval -> orchestration -> agent
#
# Usage:
#   ./verify-stack.sh                       # all layers, default ports
#   ./verify-stack.sh --agent my-agent      # also exercise a real agent request
#   ./verify-stack.sh --skip-knowledge      # LocalAI + LocalAGI only
#   LOCALAI_URL=http://gpu-box:8080 ./verify-stack.sh
#
# Environment:
#   LOCALAI_URL       default http://localhost:8080
#   LOCALAGI_URL      default http://localhost:8081
#   LOCALRECALL_URL   default http://localhost:8082
#   LLM_MODEL         default qwen3-1.7b
#   EMBEDDING_MODEL   default granite-embedding-107m-multilingual
#   LOCALAI_API_KEY / LOCALAGI_API_KEY / LOCALRECALL_API_KEY  optional bearer tokens
#
# Exit codes:
#   0  every attempted check passed
#   1  a check failed (the message names the layer and the likely cause)
#   2  a prerequisite is missing
#
set -uo pipefail

LOCALAI_URL="${LOCALAI_URL:-http://localhost:8080}"
LOCALAGI_URL="${LOCALAGI_URL:-http://localhost:8081}"
LOCALRECALL_URL="${LOCALRECALL_URL:-http://localhost:8082}"
LLM_MODEL="${LLM_MODEL:-qwen3-1.7b}"
EMBEDDING_MODEL="${EMBEDDING_MODEL:-granite-embedding-107m-multilingual}"

AGENT_NAME=""
SKIP_KNOWLEDGE=0
SKIP_AGI=0
PROBE_COLLECTION="verify-stack-probe"
CREATED_COLLECTION=0

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)          AGENT_NAME="${2:-}"; shift 2 ;;
    --skip-knowledge) SKIP_KNOWLEDGE=1; shift ;;
    --skip-agi)       SKIP_AGI=1; shift ;;
    -h|--help)        sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# --- output helpers --------------------------------------------------------

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_HEAD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_BAD=''; C_DIM=''; C_HEAD=''; C_OFF=''
fi

LAYER=""
layer()  { LAYER="$1"; printf '\n%s== %s ==%s\n' "$C_HEAD" "$1" "$C_OFF"; }
pass()   { printf '  %sPASS%s  %s\n' "$C_OK" "$C_OFF" "$1"; }
info()   { printf '        %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }
skip()   { printf '  %sSKIP%s  %s\n' "$C_DIM" "$C_OFF" "$1"; }

# fail <what failed> <why it probably failed> <where to read more>
fail() {
  printf '  %sFAIL%s  %s\n' "$C_BAD" "$C_OFF" "$1"
  printf '\n%sLayer that failed:%s %s\n' "$C_HEAD" "$C_OFF" "$LAYER"
  printf '%sLikely cause:%s     %s\n' "$C_HEAD" "$C_OFF" "$2"
  [ -n "${3:-}" ] && printf '%sSee:%s              %s\n' "$C_HEAD" "$C_OFF" "$3"
  printf '\nEverything after this layer was not checked; a failure here makes\n'
  printf 'later results meaningless. Fix this, then re-run.\n'
  cleanup
  exit 1
}

cleanup() {
  if [ "$CREATED_COLLECTION" = "1" ]; then
    curl -s -o /dev/null -X POST "${LOCALRECALL_URL}/api/collections/${PROBE_COLLECTION}/reset" \
      ${LOCALRECALL_API_KEY:+-H "Authorization: Bearer ${LOCALRECALL_API_KEY}"} || true
    info "removed probe collection '${PROBE_COLLECTION}'"
  fi
}

# --- prerequisites ---------------------------------------------------------

command -v curl >/dev/null 2>&1 || { printf 'curl is required\n' >&2; exit 2; }

HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; fi

# Optional bearer tokens, as curl argument arrays.
#
# Expanded below as ${arr[@]+"${arr[@]}"} rather than plain "${arr[@]}". That is
# not decoration: macOS ships bash 3.2, where an empty array expanded under
# `set -u` aborts with "unbound variable". The ${x+...} alternate-value form
# suppresses that and behaves identically in bash 3.2 and 5.x.
ai_auth=();  [ -n "${LOCALAI_API_KEY:-}" ]     && ai_auth=(-H "Authorization: Bearer ${LOCALAI_API_KEY}")
agi_auth=(); [ -n "${LOCALAGI_API_KEY:-}" ]    && agi_auth=(-H "Authorization: Bearer ${LOCALAGI_API_KEY}")
lr_auth=();  [ -n "${LOCALRECALL_API_KEY:-}" ] && lr_auth=(-H "Authorization: Bearer ${LOCALRECALL_API_KEY}")

printf '%sVerifying the LocalAI stack%s\n' "$C_HEAD" "$C_OFF"
info "LocalAI      ${LOCALAI_URL}"
info "LocalAGI     ${LOCALAGI_URL}"
info "LocalRecall  ${LOCALRECALL_URL}"
info "LLM          ${LLM_MODEL}"
info "embeddings   ${EMBEDDING_MODEL}"
[ "$HAVE_JQ" = "0" ] && info "jq not found — output shown raw, checks still run"

# ===========================================================================
layer "Layer 1 — inference runtime reachable"
# ===========================================================================

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${LOCALAI_URL}/readyz" ${ai_auth[@]+"${ai_auth[@]}"})
case "$code" in
  200) pass "GET /readyz returned 200" ;;
  000|'') fail "cannot connect to ${LOCALAI_URL}" \
            "LocalAI is not running, or the port/host is wrong. From inside another container, 'localhost' is not your host — use the service name or host.docker.internal." \
            "docs/01-localai/troubleshooting.md" ;;
  401|403) fail "GET /readyz returned ${code}" \
            "LocalAI requires an API key. Set LOCALAI_API_KEY for this script." \
            "docs/06-deployment/security.md" ;;
  *) fail "GET /readyz returned ${code}" \
            "The process is listening but not ready. Check 'docker logs localai' for a failed startup." \
            "docs/01-localai/troubleshooting.md" ;;
esac

info "note: /readyz means the listener is up, NOT that a model is loaded"

# ===========================================================================
layer "Layer 2 — models resolvable"
# ===========================================================================

models=$(curl -s --max-time 15 "${LOCALAI_URL}/v1/models" ${ai_auth[@]+"${ai_auth[@]}"})
[ -z "$models" ] && fail "GET /v1/models returned an empty body" \
  "Unexpected — the endpoint answered but said nothing." "docs/01-localai/api.md"

if [ "$HAVE_JQ" = "1" ]; then
  ids=$(printf '%s' "$models" | jq -r '.data[].id' 2>/dev/null)
else
  ids=$(printf '%s' "$models" | tr ',' '\n' | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')
fi

[ -z "$ids" ] && fail "no models are installed" \
  "LocalAI starts with zero models. Install one: pass it as a positional argument, or POST to the gallery API." \
  "docs/01-localai/models.md"

# grep -c '.' not wc -l: the last line has no trailing newline, so wc undercounts.
pass "$(printf '%s\n' "$ids" | grep -c '.') model(s) installed"

printf '%s\n' "$ids" | grep -qx "$LLM_MODEL" \
  || fail "model '${LLM_MODEL}' is not installed" \
       "The name must match exactly. Installed: $(printf '%s' "$ids" | tr '\n' ' ')" \
       "docs/01-localai/models.md"
pass "LLM '${LLM_MODEL}' present"

printf '%s\n' "$ids" | grep -qx "$EMBEDDING_MODEL" \
  || fail "embedding model '${EMBEDDING_MODEL}' is not installed" \
       "Retrieval cannot work without it. Install it before testing knowledge." \
       "docs/01-localai/embeddings.md"
pass "embedding model '${EMBEDDING_MODEL}' present"

# ===========================================================================
layer "Layer 3 — inference actually produces tokens"
# ===========================================================================

info "first call may take seconds while the model loads"
start=$(date +%s)
chat=$(curl -s --max-time 300 "${LOCALAI_URL}/v1/chat/completions" ${ai_auth[@]+"${ai_auth[@]}"} \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${LLM_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: ok\"}],\"max_tokens\":16}")
elapsed=$(( $(date +%s) - start ))

printf '%s' "$chat" | grep -q '"choices"' \
  || fail "chat completion did not return choices" \
       "Body was: $(printf '%s' "$chat" | head -c 400)" \
       "docs/01-localai/troubleshooting.md"

pass "POST /v1/chat/completions returned a completion (${elapsed}s)"

# ===========================================================================
layer "Layer 4 — embeddings"
# ===========================================================================

emb=$(curl -s --max-time 300 "${LOCALAI_URL}/v1/embeddings" ${ai_auth[@]+"${ai_auth[@]}"} \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${EMBEDDING_MODEL}\",\"input\":\"verification probe\"}")

if [ "$HAVE_JQ" = "1" ]; then
  dims=$(printf '%s' "$emb" | jq -r '.data[0].embedding | length' 2>/dev/null)
else
  dims=$(printf '%s' "$emb" | tr ',' '\n' | grep -c '^-\?[0-9]\+\.\?[0-9eE+-]*$')
fi

case "${dims:-0}" in
  ''|0|null) fail "no embedding vector returned" \
       "Body was: $(printf '%s' "$emb" | head -c 400). A model without embedding support returns an error here." \
       "docs/01-localai/embeddings.md" ;;
esac

pass "POST /v1/embeddings returned a ${dims}-dimension vector"
info "every collection is bound to this dimension AND this model"

# ===========================================================================
layer "Layer 5 — knowledge layer"
# ===========================================================================

if [ "$SKIP_KNOWLEDGE" = "1" ]; then
  skip "--skip-knowledge given"
else
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${LOCALRECALL_URL}/api/collections" ${lr_auth[@]+"${lr_auth[@]}"})
  case "$code" in
    200) pass "GET /api/collections returned 200" ;;
    000|'') fail "cannot connect to ${LOCALRECALL_URL}" \
              "LocalRecall is not running, or knowledge is EMBEDDED in LocalAGI rather than separate — in which case there is no service to reach and you should probe LocalAGI's own /api/collections instead. Re-run with --skip-knowledge." \
              "docs/04-integration/localagi-localrecall.md" ;;
    401|403) fail "GET /api/collections returned ${code}" \
              "Set LOCALRECALL_API_KEY for this script." "docs/06-deployment/security.md" ;;
    *) fail "GET /api/collections returned ${code}" \
              "Check 'docker logs localrecall'." "docs/03-localrecall/troubleshooting.md" ;;
  esac
  info "note: this answers from disk — it does NOT prove the embeddings edge works"

  # Creating a collection DOES exercise the embeddings edge: the engine is
  # constructed here, and a 502 means the embedding call failed.
  create=$(curl -s -w '\n%{http_code}' --max-time 60 -X POST "${LOCALRECALL_URL}/api/collections" ${lr_auth[@]+"${lr_auth[@]}"} \
    -H 'Content-Type: application/json' -d "{\"name\":\"${PROBE_COLLECTION}\"}")
  ccode=$(printf '%s' "$create" | tail -n1)
  cbody=$(printf '%s' "$create" | sed '$d')

  case "$ccode" in
    200|201) CREATED_COLLECTION=1; pass "created probe collection '${PROBE_COLLECTION}'" ;;
    502) fail "collection creation returned 502" \
              "The vector backend is unavailable. This is LocalRecall telling you the EMBEDDINGS or DATABASE call failed — not an API problem. Check OPENAI_BASE_URL, EMBEDDING_MODEL and DATABASE_URL. Body: $(printf '%s' "$cbody" | head -c 300)" \
              "docs/04-integration/localai-localrecall.md" ;;
    *) fail "collection creation returned ${ccode}" \
              "Body: $(printf '%s' "$cbody" | head -c 300)" \
              "docs/03-localrecall/troubleshooting.md" ;;
  esac

  # Ingest, then retrieve. A distinctive phrase so a hit is unambiguous.
  probe_file="$(mktemp -t verify-stack.XXXXXX)"
  cat > "$probe_file" <<'EOF'
The verification sentinel phrase is xylophone-marmalade-7731.
This document exists only so that verify-stack.sh can prove that ingestion,
chunking, embedding and retrieval all work end to end.
EOF
  mv "$probe_file" "${probe_file}.txt"; probe_file="${probe_file}.txt"

  up=$(curl -s -w '\n%{http_code}' --max-time 120 -X POST \
    "${LOCALRECALL_URL}/api/collections/${PROBE_COLLECTION}/upload" ${lr_auth[@]+"${lr_auth[@]}"} \
    -F "file=@${probe_file}")
  ucode=$(printf '%s' "$up" | tail -n1)
  rm -f "$probe_file"

  [ "$ucode" = "200" ] || fail "document upload returned ${ucode}" \
    "Ingestion embeds every chunk. A failure here is usually the embeddings edge. Body: $(printf '%s' "$up" | sed '$d' | head -c 300)" \
    "docs/03-localrecall/ingestion.md"
  pass "ingested a probe document (chunked and embedded)"

  search=$(curl -s --max-time 60 -X POST \
    "${LOCALRECALL_URL}/api/collections/${PROBE_COLLECTION}/search" ${lr_auth[@]+"${lr_auth[@]}"} \
    -H 'Content-Type: application/json' \
    -d '{"query":"what is the verification sentinel phrase","max_results":3}')

  printf '%s' "$search" | grep -q 'xylophone-marmalade-7731' \
    || fail "retrieval did not return the ingested chunk" \
         "Ingestion succeeded but search did not find it. If EMBEDDING_MODEL changed after ingestion, existing vectors are no longer comparable. Body: $(printf '%s' "$search" | head -c 300)" \
         "docs/03-localrecall/retrieval.md"

  pass "retrieved the ingested chunk by semantic query"
  info "full round trip proven: ingest -> chunk -> embed -> store -> search"
fi

# ===========================================================================
layer "Layer 6 — agent runtime"
# ===========================================================================

if [ "$SKIP_AGI" = "1" ]; then
  skip "--skip-agi given"
else
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${LOCALAGI_URL}/api/agents" ${agi_auth[@]+"${agi_auth[@]}"})
  case "$code" in
    200) pass "GET /api/agents returned 200" ;;
    000|'') fail "cannot connect to ${LOCALAGI_URL}" \
              "LocalAGI is not running, or you are using LocalAI's built-in agent pool instead — in which case agents live at ${LOCALAI_URL}/api/agents and there is no separate LocalAGI. Remember LocalAGI listens on 3000 INSIDE its container." \
              "docs/02-localagi/troubleshooting.md" ;;
    401|403) fail "GET /api/agents returned ${code}" \
              "Set LOCALAGI_API_KEY for this script." "docs/06-deployment/security.md" ;;
    *) fail "GET /api/agents returned ${code}" \
              "Check 'docker logs localagi'." "docs/02-localagi/troubleshooting.md" ;;
  esac

  agents=$(curl -s --max-time 10 "${LOCALAGI_URL}/api/agents" ${agi_auth[@]+"${agi_auth[@]}"})
  if printf '%s' "$agents" | grep -q '\[\]\|{}'; then
    info "no agents are defined yet — that is expected on a fresh deployment"
  fi

  if [ -n "$AGENT_NAME" ]; then
    layer "Layer 7 — end-to-end agent request"
    info "model field carries the AGENT name, not a model name"
    start=$(date +%s)
    resp=$(curl -s --max-time 600 "${LOCALAGI_URL}/v1/responses" ${agi_auth[@]+"${agi_auth[@]}"} \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${AGENT_NAME}\",\"input\":\"Reply with the single word: ok\"}")
    elapsed=$(( $(date +%s) - start ))

    printf '%s' "$resp" | grep -q '"Agent not found"' \
      && fail "agent '${AGENT_NAME}' is not in the pool" \
           "Names are case-sensitive here. List them with: curl -s ${LOCALAGI_URL}/api/agents" \
           "docs/02-localagi/agents.md"

    printf '%s' "$resp" | grep -q '"output"' \
      || fail "agent request did not return an output envelope" \
           "Body: $(printf '%s' "$resp" | head -c 400). An agent request is a LOOP — check that your client timeout exceeds iterations x model call time." \
           "docs/02-localagi/troubleshooting.md"

    pass "POST /v1/responses completed (${elapsed}s)"
    info "one agent iteration can be three or more model calls under forced reasoning"
  else
    skip "Layer 7 — pass --agent <name> to exercise a real agent request"
  fi
fi

# ===========================================================================
cleanup
printf '\n%sAll attempted checks passed.%s\n' "$C_OK" "$C_OFF"

if [ -z "$AGENT_NAME" ]; then
  printf '\nNot verified: an actual agent request. Create an agent, then:\n'
  printf '  %s --agent <name>\n' "$0"
fi
exit 0
