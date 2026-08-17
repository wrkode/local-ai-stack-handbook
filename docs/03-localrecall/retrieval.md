# Retrieval

One query, one collection, one call into the backend. `POST
/api/collections/:name/search` embeds the query text, asks the engine for the
top-K nearest chunks, and returns them.

Everything a mature retrieval stack adds around that — query rewriting, HyDE,
multi-query expansion, reranking, cross-encoders, metadata filters — is absent. A
grep for `rerank` across the sources returns zero hits.

## The path

```text
POST /api/collections/:name/search
  → search handler (routes.go:279)
  → PersistentKB.Search(query, maxResults)   [takes the collection mutex]
  → Engine.Search(query, similarEntries)
      → embed the query   [HTTP to $OPENAI_BASE_URL/embeddings]
      → nearest-neighbour lookup in the backend
```

Two properties of that path matter operationally.

**Every search costs one embedding round trip.** There is no query cache. If the
embeddings endpoint is slow, every search is slow, including repeated identical
queries.

**Searches serialise per collection.** `PersistentKB` holds one `sync.Mutex` and
`Search` takes it, so concurrent searches against the same collection queue behind
one another and behind any in-flight ingestion. Different collections are
independent.

## Top-K

`max_results` in the request body. When it is 0 or absent the handler defaults to
**5 if the collection holds at least 5 documents, otherwise 1** — and it counts
*documents*, via `len(collection.ListDocuments())`, not chunks.

That combination produces a genuinely surprising result: a collection containing
one 500-page PDF, chunked into thousands of pieces, has **one document**, so an
unspecified query returns **one chunk**. Always send `max_results` explicitly.

There is no server-side cap. `max_results: 1000000` is accepted and passed
straight through as the SQL `LIMIT` or chromem's `nResults`.

## Score semantics differ by engine

**This is the trap of the page.** The same query against the same corpus returns
numbers on three different scales depending on which engine is configured and
whether its indexes are healthy.

| Path | What `Similarity` is | Range | Higher is better? |
|---|---|---|---|
| chromem | cosine similarity of normalised vectors | `[-1, 1]` | yes |
| postgres, hybrid (normal) | **Reciprocal Rank Fusion score** | `(0, ~0.0164]` with default weights | yes |
| postgres, vector-only fallback | `1 - cosine_distance` | `[0, 1]` | yes |
| localai | whatever LocalAI's `/stores/find` returns | server-defined | yes |

And the DTO's own documentation is wrong. `rag/types/result.go:10-12` documents
`Similarity` as cosine similarity in `[-1,1]` — accurate for chromem, inaccurate
for the PostgreSQL hybrid path, which is the *default* path in the shipped compose
stack. The `Engine` interface imposes no contract at all.

Three rules follow:

1. **Never threshold on an absolute similarity value.** A filter like
   `similarity > 0.5` returns everything on chromem and **nothing** on PostgreSQL
   hybrid, where the theoretical maximum is about 0.0164.
2. **Never compare scores across engines**, or across a migration, or between two
   collections that might be on different backends.
3. **Use rank, not score.** The ordering is meaningful on every path. The number
   is only meaningful relative to other numbers from the same query on the same
   engine.

A caution that applies even when you stay on one engine: cosine values from a
small embedding model are not calibrated. Measurements recorded in
[terminology](../00-overview/terminology.md#semantic-search) show an unrelated
sentence scoring 0.46 against a query where a genuinely relevant one scored 0.70.
Only the ranking carries signal.

## chromem — dense only, brute force

`ChromemDB.Search` calls `collection.Query(ctx, s, similarEntries, nil, nil)` —
the two `nil`s are the `where` and `whereDocument` filters, never populated.

chromem-go embeds the query, then iterates **every** document in the collection
computing a dot product against the normalised query vector (which, for normalised
vectors, is the cosine similarity), keeping a bounded max-heap of size K.

- **No ANN index.** Cost is O(N·d) per query, in memory, parallelised across
  goroutines. Fine for thousands of chunks. See [storage](storage.md#chromem-the-default)
  for where that stops being fine.
- **No keyword arm.** chromem is dense-only. Exact identifiers, error codes, part
  numbers and rare proper nouns are retrieved only if the embedding model happens
  to place them nearby.
- Results carry `ID`, `Metadata`, `Content` and `Similarity` — but **not**
  `Embedding`, which is left zero.

## PostgreSQL — real hybrid search, RRF

Hybrid search in LocalRecall is real, index-backed, and **PostgreSQL-only**.

`PostgresDB.Search` embeds the query, formats it as a pgvector literal with six
decimal places, and runs one statement fusing two independently-indexed arms:

```sql
WITH bm25_results AS (
  SELECT id, ROW_NUMBER() OVER (ORDER BY full_text <@> to_bm25query($1, 'idx_<t>_bm25')) AS rank
  FROM <t> ORDER BY full_text <@> to_bm25query($1, 'idx_<t>_bm25') LIMIT GREATEST($5*10, 100)
),
vector_results AS (
  SELECT id, ROW_NUMBER() OVER (ORDER BY embedding <=> $3::vector) AS rank
  FROM <t> WHERE embedding IS NOT NULL ORDER BY embedding <=> $3::vector LIMIT GREATEST($5*10, 100)
),
fused AS (
  SELECT COALESCE(b.id, v.id) AS id,
         COALESCE($2 / (60 + b.rank), 0) + COALESCE($4 / (60 + v.rank), 0) AS similarity
  FROM bm25_results b FULL OUTER JOIN vector_results v ON b.id = v.id
)
SELECT d.id::text, COALESCE(d.title,''), d.content, d.metadata, f.similarity
FROM fused f JOIN <t> d ON d.id = f.id
ORDER BY f.similarity DESC LIMIT $5
```

Bind parameters: `$1` query text, `$2` BM25 weight, `$3` query embedding, `$4`
vector weight, `$5` limit.

Constants:

| Constant | Value | Meaning |
|---|---|---|
| `rrfK` | **60** | the standard IR value, chosen to match pgvector/Timescale reference examples |
| `hybridCandidateMultiplier` | 10 | |
| `hybridCandidateFloor` | 100 | |

**Each arm pulls `max(limit*10, 100)` candidates before fusion.** So a `max_results`
of 5 still ranks 100 BM25 candidates against 100 vector candidates. A `max_results`
of 50 pulls 500 from each arm — the query cost grows with K faster than the result
count suggests.

### Why RRF rather than score blending

The design comment is explicit: RRF fuses by **rank**, not raw score, which avoids
mixing BM25's unbounded scores with cosine's bounded range. It is the right call
and it is why the returned number is not a similarity.

The maximum possible score, with both weights at their 0.5 default, is a document
ranked first in both arms: `0.5/61 + 0.5/61 ≈ 0.0164`. A document found by only
one arm tops out near 0.0082. That is the whole scale.

### Weights

`HYBRID_SEARCH_BM25_WEIGHT` and `HYBRID_SEARCH_VECTOR_WEIGHT`, both `0.5` by
default, parsed with `strconv.ParseFloat` and **silently ignored on a parse
failure**. Because they are plain multipliers on `w/(60+rank)`, only their
**ratio** affects ordering; the absolute scale merely rescales the reported
number.

Tune the ratio, not the magnitudes:

| Corpus | Suggested lean |
|---|---|
| Prose, conceptual questions, paraphrased queries | favour the vector arm |
| Code, logs, part numbers, error codes, exact identifiers | favour the BM25 arm |
| Mixed documentation | leave both at 0.5 |

Nothing here has been benchmarked by us; the ratio is the knob, and A/B against
your own queries is the only way to set it.

### Why the query looks the way it does

v0.6.3 rewrote it. The previous version sorted on a wrapped scalar similarity
expression in a single stage, which blinded the planner into a full sequential
scan over every row and exceeded the statement timeout on multi-million-row
collections — LocalAI issue #10186, cited verbatim in the source. The fix gives
each arm a **bare** operator in its `ORDER BY` (`full_text <@> to_bm25query(...)`
and `embedding <=> $3::vector`), so the BM25 and DiskANN/HNSW indexes are actually
used.

If you modify this query, preserve the bare operators.

### The silent fallback

If the hybrid query errors for **any** reason — missing BM25 index, `pg_textsearch`
unavailable, a config mismatch — the engine logs a warning and retries a
**vector-only** query. That one returns `1 - (embedding <=> $1::vector)`, a
genuine cosine similarity in `[0, 1]`.

So the same collection can return two incompatible score scales depending on
whether an index is healthy, and the only signal is a log line. If your PostgreSQL
scores suddenly jump from ~0.01 to ~0.8, you have lost BM25, not gained quality —
you are now running dense-only search and every keyword-matched result is gone.
[troubleshooting](troubleshooting.md#postgresql-missing-pg_textsearch) covers the
fix.

The row-scan loop also `continue`s on a scan error, silently dropping malformed
rows rather than failing the query.

## What retrieval cannot do

**No metadata filtering.** `Engine.Search` has no `where` parameter, chromem is
called with `nil, nil`, and the hybrid SQL has no metadata predicate. You cannot
scope a query to one document, one source, one date range or one tag. The only
metadata lookup in the codebase is `GetBySource`, used internally by the entries
endpoints.

If you need scoped retrieval, the unit of scoping is the **collection**. Create
one per scope, at the cost of losing cross-scope recall.

**No reranking, no query rewriting, no multi-query, no HyDE.** If you want any of
these, they belong in the calling application, between LocalRecall's response and
the model's context.

**No pagination.** Raise `max_results` or ask again.

**Chunk metadata attached to every result**, for what it is worth downstream:
`type="file"`, `source="<uuid>/<filename>"`, `file_name`, plus `created_at` from
uploads or `url` from external sources. `source` is what a citation layer uses to
link a chunk back to its original file.

## Upstream references

- [`routes.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/routes.go) — the `search` handler at 279-318 and the 5-or-1 default at 297-303. Source-verified against v0.6.4, validated 2026-08-17.
- [`rag/persistency.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/persistency.go) — mutex-guarded `Search` at 185-190; chunk metadata at 446-448. Validated 2026-08-17.
- [`rag/engine.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine.go) — the `Search` signature with no filter parameter, line 13. Validated 2026-08-17.
- [`rag/engine/chromem.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/chromem.go) — `Search` at 196-215, `nil, nil` filters at 197, absent `Embedding` at 206-211. Validated 2026-08-17.
- [`rag/engine/postgres.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/postgres.go) — `Search` at 915-977, `buildHybridSearchQuery` at 879-913, RRF constants at 851-859, design rationale and the LocalAI #10186 citation at 861-878, weights at 64-75, vector-only fallback at 929-948. Validated 2026-08-17.
- [`rag/engine/localai.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/localai.go) — `Search` at 95-131 with no ID or metadata populated. Validated 2026-08-17.
- [`rag/types/result.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/types/result.go) — the incorrect cosine doc comment at 10-12. Validated 2026-08-17.
- [LocalRecall release v0.6.3](https://github.com/mudler/LocalRecall/releases/tag/v0.6.3) — index-backed RRF hybrid search (PR #46). Validated 2026-08-17.
- [`philippgille/chromem-go v0.7.0` `query.go`](https://github.com/philippgille/chromem-go/blob/v0.7.0/query.go) — brute-force scan at 165-244 and the normalised-dot-product comment at 214. Read at the pinned tag, validated 2026-08-17.
