#!/usr/bin/env sh
#
# Remove everything the examples create. Touches only objects named 'example-*',
# so your own agents and collections are safe.

. "$(dirname "$0")/lib.sh"

step "Agents named example-*"
if [ "$(http_code "${LOCALAGI_URL}/api/agents")" = "200" ]; then
  agents=$(curl -s "${LOCALAGI_URL}/api/agents" | tr ',' '\n' \
    | sed -n 's/.*"\(example-[a-z0-9-]*\)".*/\1/p' | sort -u)
  if [ -z "$agents" ]; then
    note "none found"
  else
    for a in $agents; do
      curl -s -o /dev/null -X DELETE "${LOCALAGI_URL}/api/agent/${a}"
      ok "deleted agent ${a}"
    done
  fi
else
  note "LocalAGI not reachable — skipping"
fi

step "Collections named example-*"
if [ "$(http_code "${LOCALRECALL_URL}/api/collections")" = "200" ]; then
  colls=$(curl -s "${LOCALRECALL_URL}/api/collections" | tr ',' '\n' \
    | sed -n 's/.*"\(example-[a-z0-9-]*\)".*/\1/p' | sort -u)
  if [ -z "$colls" ]; then
    note "none found"
  else
    for c in $colls; do
      curl -s -o /dev/null -X POST "${LOCALRECALL_URL}/api/collections/${c}/reset"
      ok "reset collection ${c}"
    done
  fi
else
  note "LocalRecall not reachable — skipping"
fi

step "Not removed"
note "downloaded models and backends — deliberately kept, they are the slow part"
note "counter values — no endpoint exposes them for deletion"
note "to remove everything: cd compose && docker compose down -v"
