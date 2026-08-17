#!/usr/bin/env sh
#
# Example 2 — embeddings.
# Recipe: docs/05-recipes/localai-embeddings.md
#
# Shows: dimensions, L2 normalization, semantic similarity, and batching.
# No new components: same LocalAI, different model, different endpoint.

. "$(dirname "$0")/../lib.sh"

step "1. The embedding model is installed"
require_localai "$EMBEDDING_MODEL"

step "2. One vector, and its dimension"
dims=$(curl -s --max-time 300 "${LOCALAI_URL}/v1/embeddings" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${EMBEDDING_MODEL}\",\"input\":\"LocalRecall stores and retrieves knowledge.\"}" \
  | jqr '.data[0].embedding | length')
[ -n "$dims" ] && [ "$dims" != "null" ] || die "no vector returned" \
  "See docs/01-localai/embeddings.md"
ok "${dims} dimensions"
note "this number becomes a permanent property of every collection built from it"

if ! have_jq; then
  note "jq not installed — skipping the numeric checks below"
  exit 0
fi

step "3. The vectors are already L2-normalized"
mag=$(curl -s "${LOCALAI_URL}/v1/embeddings" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${EMBEDDING_MODEL}\",\"input\":\"magnitude check\"}" \
  | jq '[.data[0].embedding[] | . * .] | add | sqrt')
ok "magnitude ${mag}"
note "so cosine similarity is a plain dot product; do NOT normalize again"
note "it is 1 within float32 rounding error — never assert equality with 1.0"

step "4. Semantic similarity, which is the whole point"
curl -s "${LOCALAI_URL}/v1/embeddings" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${EMBEDDING_MODEL}\",\"input\":[
        \"a cat sat on the mat\",
        \"a feline rested on the rug\",
        \"quarterly revenue increased\"]}" \
  | jq "[.data[].embedding] as \$e
        | {paraphrase: ([range(${dims}) | \$e[0][.] * \$e[1][.]] | add),
           unrelated:  ([range(${dims}) | \$e[0][.] * \$e[2][.]] | add)}"
note "observed: paraphrase 0.868, unrelated 0.540"
note "the FLOOR is not zero. Combined with no relevance threshold anywhere,"
note "that is why a top-k search always returns k results, however irrelevant."

step "5. Batching preserves order via 'index'"
curl -s "${LOCALAI_URL}/v1/embeddings" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${EMBEDDING_MODEL}\",\"input\":[\"first\",\"second\",\"third\"]}" \
  | jq -c '[.data[] | {index, dims: (.embedding | length)}]'
note "read the index field, not the array position"

step "Done"
note "LocalAI computed these and stored NOTHING. Persisting them is example 03."
