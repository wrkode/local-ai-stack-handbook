#!/usr/bin/env sh
#
# Example 3 — collections, ingestion, retrieval.
# Recipe: docs/05-recipes/localrecall-rag.md
#
# Shows the full round trip: create, ingest, chunk, embed, store, search.
# Creates collection 'example-handbook' and removes it at the end.

. "$(dirname "$0")/../lib.sh"
COLL=example-handbook

step "1. Layers below must work first"
require_localai "$EMBEDDING_MODEL"
require_localrecall

step "2. Create a collection"
note "this CONSTRUCTS the vector engine — the first command that really"
note "exercises the embeddings edge and the database"
body=$(curl -s -w '\n%{http_code}' --max-time 120 -X POST "${LOCALRECALL_URL}/api/collections" \
  -H 'Content-Type: application/json' -d "{\"name\":\"${COLL}\"}")
code=$(printf '%s' "$body" | tail -n1)
case "$code" in
  200|201) ok "created '${COLL}'" ;;
  502) die "502 Vector backend unavailable" \
    "The embeddings or database call failed — not an API problem.
Check OPENAI_BASE_URL, EMBEDDING_MODEL and DATABASE_URL.
See docs/04-integration/localai-localrecall.md" ;;
  *) die "creation returned ${code}: $(printf '%s' "$body" | sed '$d' | head -c 200)" \
    "See docs/03-localrecall/troubleshooting.md" ;;
esac

step "3. Ingest a document containing an invented fact"
tmpdir=$(mktemp -d -t example03) || die "mktemp failed"
tmp="${tmpdir}/zeppelin.txt"
cat > "$tmp" <<'TXT'
The Zeppelin-7 telemetry bus uses a heartbeat interval of 4200 milliseconds.
Operators must never set the Zeppelin-7 heartbeat below 900 milliseconds because
the flight controller drops frames at that rate.
TXT
note "invented deliberately: no model can know it, so a hit proves retrieval"
curl -s --max-time 300 -X POST "${LOCALRECALL_URL}/api/collections/${COLL}/upload" \
  -F "file=@${tmp}" | pretty
rm -rf "$tmpdir"

step "4. What chunking actually did"
if command -v docker >/dev/null 2>&1; then
  docker logs localrecall 2>&1 | grep -i 'Chunked file' | tail -1 \
    || note "(no chunk log line found)"
else
  note "(docker unavailable; run: docker logs localrecall | grep 'Chunked file')"
fi
note "that line is the only way to confirm your chunk settings took effect"

step "5. List entries"
curl -s "${LOCALRECALL_URL}/api/collections/${COLL}/entries" | pretty
note "'entries' are base filenames; 'keys' are <uuid>/<filename>"

step "6. Search with wording that shares almost no words"
res=$(curl -s --max-time 120 -X POST "${LOCALRECALL_URL}/api/collections/${COLL}/search" \
  -H 'Content-Type: application/json' \
  -d '{"query":"how often does the telemetry bus send a heartbeat","max_results":3}')
printf '%s' "$res" | pretty
case "$res" in
  *4200*) ok "retrieved the ingested chunk semantically" ;;
  *) die "the chunk was not retrieved" \
    "If EMBEDDING_MODEL changed since ingestion, old vectors are not comparable.
See docs/03-localrecall/troubleshooting.md" ;;
esac
note "note: Embedding is null, and Similarity is present but returns 0"
note "so you cannot tell from the response how good a match this was"

step "7. Omitting max_results is NOT a sensible default"
n=$(curl -s -X POST "${LOCALRECALL_URL}/api/collections/${COLL}/search" \
  -H 'Content-Type: application/json' -d '{"query":"heartbeat"}' | jqr '.data.max_results')
ok "max_results defaulted to ${n}"
note "5 if the collection holds >=5 documents, otherwise 1. Always set it."

step "8. Cleanup"
curl -s -o /dev/null -X POST "${LOCALRECALL_URL}/api/collections/${COLL}/reset"
ok "reset '${COLL}'"
note "reset also removes it from the in-memory registry — nearer a delete than a truncate"
