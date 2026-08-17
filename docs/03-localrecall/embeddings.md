# Embeddings

LocalRecall computes no embeddings. Every vector in every collection comes from an
HTTP call to an external OpenAI-compatible endpoint. There is no ONNX runtime, no
GGML, no tokeniser and no model file anywhere in the project.

That single fact determines its failure modes: an unreachable embeddings endpoint
means no ingestion and no search, while file listing, downloads and collection
management keep working.

## The wire call

One `*openai.Client` is built at startup and shared by every collection and every
backend (`main.go:60-63`):

```go
config := openai.DefaultConfig(openAIKey)
config.BaseURL = openAIBaseURL
openAIClient := openai.NewClientWithConfig(config)
```

The client is `github.com/sashabaranov/go-openai v1.37.0`. Its
`CreateEmbeddings` posts to `fullURL("/embeddings")`, and `fullURL` is
`strings.TrimRight(BaseURL, "/") + suffix`.

So every embedding is:

```http
POST $OPENAI_BASE_URL/embeddings
Authorization: Bearer $OPENAI_API_KEY
Content-Type: application/json

{"input": ["…"], "model": "$EMBEDDING_MODEL"}
```

An embedded consumer builds the same client the same way — LocalAGI's
`inprocess.go:263-265` is character-for-character the same three lines. The
embeddings hop is the one network call that exists in **every** deployment shape,
in-process or standalone.

## `OPENAI_BASE_URL` is effectively mandatory

`openai.DefaultConfig` sets `BaseURL` to `https://api.openai.com/v1`.
`main.go:61` then **overwrites it unconditionally** — including with the empty
string when `OPENAI_BASE_URL` is unset. There is no `if` and no fallback.

With the variable unset, the request URL is the bare relative string
`"/embeddings"`, which is not a usable URL. Every embedding call fails, so:

- `POST /api/collections` returns **502** `"Vector backend unavailable"` for the
  chromem and postgres engines, because construction probes the embedder.
- Uploads of indexable files fail at the embedding step.
- Searches fail, because the query itself must be embedded.

> **Discrepancy.** `README.md:201` lists `OPENAI_BASE_URL` as one more optional row
> in the environment table. The code makes it required
> (`main.go:20,61`). Believe the code: **always set it explicitly.** Talking to
> real OpenAI requires setting it to `https://api.openai.com/v1` by hand — the
> default that would have done that for you has already been discarded.

### The `/v1` suffix

`fullURL` appends `/embeddings`, not `/v1/embeddings`. Whether you need `/v1` in
the base URL depends entirely on the server.

| Base URL | Resulting request | Works? |
|---|---|---|
| `http://localai:8080` | `POST http://localai:8080/embeddings` | yes — LocalAI registers un-prefixed aliases |
| `http://localai:8080/v1` | `POST http://localai:8080/v1/embeddings` | yes |
| `https://api.openai.com` | `POST https://api.openai.com/embeddings` | **no** |
| `https://api.openai.com/v1` | `POST https://api.openai.com/v1/embeddings` | yes |

The shipped `docker-compose.yml:46` uses the un-prefixed
`OPENAI_BASE_URL=http://localai:8080`, and the project's own migration test sets
`cfg.BaseURL = srv.URL + "/v1"`. Both work; the inconsistency runs through the
whole family. **Any third-party OpenAI-compatible server substituted into this
stack must be given a base URL that already ends in `/v1`.**

## `EMBEDDING_MODEL` has no default

Unset means the empty string is sent as `"model"`. There is no validation and no
startup check; LocalAI rejects it at request time. Standalone LocalRecall is
therefore broken by omission in two independent ways out of the box.

LocalAGI's in-process backend is better behaved here: it defaults
`EMBEDDING_MODEL` to `granite-embedding-107m-multilingual`
(`LocalAGI/cmd/env.go:93`). Standalone LocalRecall does not.

## Every call site

| Site | Batching |
|---|---|
| chromem embedding func, called per document by chromem-go | **1 text per call** |
| chromem query embedding | 1 |
| Postgres `StoreDocuments` | **all chunks of a file in ONE call** |
| Postgres query embedding | 1 |
| Postgres dimension migration re-embed | batches of 10 |
| Postgres construction probe (input `"test"`) | 1 |
| `localai` engine store | 1 per chunk |
| `localai` engine search | 1 |
| Generic dimension probe on collection open (input `"test"`) | 1 |

All of them use `openai.EmbeddingRequestStrings{Input: []string{...}, Model: ...}`.

### Batching differs by engine

This is a real performance characteristic, not a detail.

**PostgreSQL** embeds a whole file's chunks in a single HTTP request: the `Input`
array carries every chunk. A 1,000-chunk PDF is **one** request.

**chromem** embeds **one chunk per HTTP request**. It cannot do otherwise:
chromem-go's `EmbeddingFunc` signature is
`func(ctx context.Context, text string) ([]float32, error)` — one string in, one
vector out. A 1,000-chunk PDF on the default engine is **1,000 HTTP requests**.

chromem-go does fan these out across `runtime.NumCPU()` goroutines, so they are
concurrent rather than serial. That helps throughput and does nothing for the
per-request overhead: 1,000 connections, 1,000 sets of headers, 1,000 model
dispatches on the LocalAI side, and 1,000 opportunities for a transient failure.

Consequences to plan around:

| | chromem | postgres |
|---|---|---|
| Requests to ingest an N-chunk file | **N** | 1 |
| Concurrency | `NumCPU()` goroutines | serial, one call |
| Effect of raising `MAX_CHUNKING_SIZE` | proportionally fewer requests — a direct ingestion speedup | negligible |
| Sensitivity to embeddings-endpoint latency | multiplied by N | paid once |

If ingestion on chromem feels slow, this is why. See
[troubleshooting](troubleshooting.md#slow-ingestion-on-chromem).

## Dimension handling

LocalRecall **never sends a `Dimensions` field**, although go-openai supports one.
Dimensionality is whatever the server returns, discovered by probing.

| Engine | How it learns the dimension |
|---|---|
| postgres | embeds the literal string `"test"` at construction, takes `len(embedding)`, hardcodes it into the `VECTOR(n)` column |
| chromem | retroactively, from an already-stored document; errors with `"no documents in collection"` when empty |
| localai | not implemented |

A second, cruder check sits in the generic layer: on collection open,
`NewPersistentCollectionKB` embeds `"test"`, compares the length against
`Engine.GetEmbeddingDimensions()`, and calls `Repopulate()` on mismatch — a full
re-chunk and re-embed of every file on disk. Note that this check is guarded on
both calls returning `err == nil`, so **an unreachable embedder or an empty
collection silently skips it** rather than failing.

No normalisation is done by LocalRecall. chromem-go normalises internally before
its dot product; pgvector's `<=>` is cosine distance and handles it.

## Changing the embedding model

Vectors from different models are not comparable. Changing `EMBEDDING_MODEL`
against an existing collection triggers one of three behaviours depending on the
engine, and you should know which before you do it.

**PostgreSQL — an actual migration.** `checkAndRecalculateEmbeddings` compares the
stored `(embedding_model, embedding_dimensions)` in the shared `collection_config`
table against the live pair. On mismatch `migrateEmbeddingDimensions` runs, in a
deliberate order:

1. Read all `(id, full_text)` **outside** any transaction, so no long cursor is
   held while the embedder is called.
2. Re-embed **everything before touching the schema**, in batches of 10,
   validating both the returned count and each vector's dimensionality.
3. Only then, in one transaction: drop the vector index, `DROP COLUMN embedding`,
   `ADD COLUMN embedding vector(<newDims>)`, per-row `UPDATE`, update
   `collection_config`. pgvector cannot resize a `VECTOR` column in place, hence
   the drop and re-add.
4. Recreate the vector index outside the transaction; a failure here is downgraded
   to a warning.

A rollback therefore restores the old column and index intact. This is the most
carefully engineered code in the repository — but it re-embeds the entire
collection, so budget the embeddings capacity and the time before restarting with
a changed model.

**chromem — no migration path.** Nothing compares models. The generic probe fires
only if the *dimension count* differs, and then re-chunks and re-embeds from the
files on disk. Two models with the **same** dimension count — swapping one
384-dimension model for another — produce **no error, no warning and no
migration**. The collection ends up holding vectors from two different models in
one space, and similarity scores between them are meaningless. Rankings degrade
quietly.

**localai — `GetEmbeddingDimensions` is not implemented,** so neither check can
fire.

Guidance: treat the embedding model as **fixed for the lifetime of a
collection**. If you must change it, reset the collection and re-ingest — on
chromem that is the only correct procedure, and on PostgreSQL it is the
predictable one.

## Upstream references

- [`main.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/main.go) — client construction and the unconditional `BaseURL` overwrite at 60-63; `EMBEDDING_MODEL` read at 17. Source-verified against v0.6.4, validated 2026-08-17.
- [`rag/engine/chromem.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/chromem.go) — per-text `EmbeddingFunc` at 82-89, `NumCPU` fan-out at 150, dimension read at 67-79. Validated 2026-08-17.
- [`rag/engine/postgres.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/postgres.go) — whole-file batch at 681-686, `getTestEmbedding` at 136-140, `checkAndRecalculateEmbeddings` at 409-445, `migrateEmbeddingDimensions` at 456-574. Validated 2026-08-17.
- [`rag/engine/localai.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/localai.go) — per-chunk store loop at 38-55; unimplemented dimensions at 34-36. Validated 2026-08-17.
- [`rag/persistency.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/persistency.go) — the generic `"test"` probe and its `err == nil` guards at 114-130. Validated 2026-08-17.
- [`docker-compose.yml`](https://github.com/mudler/LocalRecall/blob/v0.6.4/docker-compose.yml) — `OPENAI_BASE_URL=http://localai:8080` without `/v1` at line 46. Validated 2026-08-17.
- [`README.md`](https://github.com/mudler/LocalRecall/blob/v0.6.4/README.md) — `OPENAI_BASE_URL` presented as optional at line 201. Validated 2026-08-17.
- [`sashabaranov/go-openai v1.37.0`](https://github.com/sashabaranov/go-openai/blob/v1.37.0/embeddings.go) — `CreateEmbeddings` posting to `fullURL("/embeddings")`; `fullURL` concatenation in [`client.go`](https://github.com/sashabaranov/go-openai/blob/v1.37.0/client.go). Read at the pinned tag, validated 2026-08-17.
- [LocalAGI `cmd/env.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/cmd/env.go) — `EMBEDDING_MODEL` default at line 93. Validated against v2.9.0, 2026-08-17.
