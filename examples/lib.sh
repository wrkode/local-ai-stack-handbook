#!/usr/bin/env sh
#
# Shared helpers for the examples. Sourced, not executed.
#
# POSIX sh deliberately: these run under sh, bash 3.2 (macOS) and zsh. In
# particular there are no arrays here — bash 3.2 with `set -u` aborts on an
# empty array expansion, which cost us a debugging session in verify-stack.sh.

LOCALAI_URL="${LOCALAI_URL:-http://localhost:8080}"
LOCALAGI_URL="${LOCALAGI_URL:-http://localhost:8081}"
LOCALRECALL_URL="${LOCALRECALL_URL:-http://localhost:8082}"
LLM_MODEL="${LLM_MODEL:-qwen3-1.7b}"
EMBEDDING_MODEL="${EMBEDDING_MODEL:-granite-embedding-107m-multilingual}"

if [ -t 1 ]; then
  C_OK=$(printf '\033[32m'); C_BAD=$(printf '\033[31m')
  C_DIM=$(printf '\033[2m'); C_HEAD=$(printf '\033[1m'); C_OFF=$(printf '\033[0m')
else
  C_OK=''; C_BAD=''; C_DIM=''; C_HEAD=''; C_OFF=''
fi

step() { printf '\n%s== %s ==%s\n' "$C_HEAD" "$1" "$C_OFF"; }
ok()   { printf '  %sok%s    %s\n' "$C_OK" "$C_OFF" "$1"; }
note() { printf '        %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }

# die <message> <hint>
die() {
  printf '  %sfail%s  %s\n' "$C_BAD" "$C_OFF" "$1"
  [ -n "${2:-}" ] && printf '\n%s\n' "$2"
  exit 1
}

# show <command...> — print a command, then run it
show() {
  printf '%s$ %s%s\n' "$C_DIM" "$*" "$C_OFF"
  "$@"
}

have_jq() { command -v jq >/dev/null 2>&1; }

# pretty — format JSON on stdin if jq exists, else pass through
pretty() { if have_jq; then jq .; else cat; fi; }

# jqr <filter> — extract a value, or empty string without jq
jqr() { if have_jq; then jq -r "$1"; else cat; fi; }

# http_code <url> — status code, or 000 when unreachable
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$1"; }

# require_localai — inference must be reachable and hold the model
require_localai() {
  code=$(http_code "${LOCALAI_URL}/readyz")
  case "$code" in
    200) ;;
    000|'') die "cannot reach LocalAI at ${LOCALAI_URL}" \
      "Start the reference environment:  cd compose && docker compose up -d" ;;
    *) die "LocalAI returned ${code} from /readyz" \
      "See docs/01-localai/troubleshooting.md" ;;
  esac

  # /readyz says the listener is up, NOT that any model is installed. That
  # distinction is not pedantic: we reproduced a run where the model gallery
  # was rate-limited, every install failed, and /readyz still returned 200
  # with zero models.
  models=$(curl -s --max-time 20 "${LOCALAI_URL}/v1/models")
  case "$models" in
    *"\"$1\""*) ok "LocalAI has '$1'" ;;
    *) die "model '$1' is not installed" \
      "Installed: $(printf '%s' "$models" | tr ',' '\n' | sed -n 's/.*\"id\" *: *\"\([^\"]*\)\".*/\1/p' | tr '\n' ' ')
See docs/01-localai/models.md" ;;
  esac
}

require_localagi() {
  code=$(http_code "${LOCALAGI_URL}/api/agents")
  case "$code" in
    200) ok "LocalAGI is up at ${LOCALAGI_URL}" ;;
    000|'') die "cannot reach LocalAGI at ${LOCALAGI_URL}" \
      "Remember LocalAGI listens on 3000 INSIDE its container; the reference
environment maps 8081:3000.  See docs/08-reference/ports.md" ;;
    401|403) die "LocalAGI returned ${code}" \
      "LOCALAGI_API_KEYS is set. Auth is global on LocalAGI, including /api/agents." ;;
    *) die "LocalAGI returned ${code} from /api/agents" \
      "See docs/02-localagi/troubleshooting.md" ;;
  esac
}

require_localrecall() {
  code=$(http_code "${LOCALRECALL_URL}/api/collections")
  case "$code" in
    200) ok "LocalRecall is up at ${LOCALRECALL_URL}"
         note "note: this answers from disk — it proves nothing about embeddings" ;;
    000|'') die "cannot reach LocalRecall at ${LOCALRECALL_URL}" \
      "If knowledge is embedded in the agent runtime there is no service to reach.
See docs/04-integration/localagi-localrecall.md" ;;
    *) die "LocalRecall returned ${code}" \
      "See docs/03-localrecall/troubleshooting.md" ;;
  esac
}

# seconds_since <start> — whole seconds elapsed
seconds_since() { echo $(( $(date +%s) - $1 )); }
