# 003 — LocalRecall: library, service, or both

**Question:** is LocalRecall a service you deploy or a library you link?

**Answer:** both — but which one you get is decided by the *image* you run, not by a design
choice you make. And in every runnable LocalAGI, it is a service.

## The three consumers

| Consumer | How it uses LocalRecall | Verified |
|---|---|---|
| Standalone `localrecall` | it *is* the service | image runs, 11 routes |
| LocalAI v4.8.2 | **library** — imports `rag`, serves `/api/agents/collections` | `go.mod`, routes |
| LocalAGI v2.9.0 source | **library by default**, HTTP when configured | `webui/routes.go:219`, `cmd/serve.go:113` |
| **LocalAGI v2.8.1 image** | **HTTP only** — does not import it at all | `go.mod`, zero importing files |

That last row is the finding that reorganised this note. See
[006](006-validation-log.md#failure-2-localagi-v281-differs-from-v290).

## What "library" means concretely

Not vendoring, not a copy. LocalAGI v2.9.0 imports `github.com/mudler/localrecall/rag` and
constructs a `*rag.PersistentKB` directly — the same type the standalone service uses, running
in another process.

Evidence that this is intended rather than incidental
(`webui/collections/rag_provider.go:152-156`):

```go
// RAGProviderFromState returns a RAG provider function from a State.
// External consumers (e.g. LocalAI) can call NewInProcessBackend to get the state,
// then pass it here to create a RAG provider for the agent pool.
```

Upstream names LocalAI as an external consumer in LocalAGI's own source.

## The two switches, both on one variable

`LOCALAGI_LOCALRAG_URL` flips **two independent things** in two different files:

| What | Where | Empty (default) | Set |
|---|---|---|---|
| The agent's retrieval provider | `cmd/serve.go:113-120` | in-process `PersistentKB` | `localrag.Client` over HTTP |
| The collections **management** API | `webui/routes.go:219-227` | operates on its own store | **proxies** to LocalRecall |

They are separate code paths, which is why it is worth knowing they exist separately: the
management API and the retrieval path could in principle disagree, and both are keyed off the
same variable.

The API surface a client sees is identical either way — LocalAGI deliberately reimplements
LocalRecall's `{success, message, data, error}` envelope and says so in a comment.

## The same contract, three prefixes

| Operation | LocalRecall | LocalAGI v2.9.0 | LocalAI |
|---|---|---|---|
| list | `GET /api/collections` | same | `GET /api/agents/collections` |
| create | `POST /api/collections` | same | `POST /api/agents/collections` |
| upload | `POST /api/collections/:n/upload` | same | `POST /api/agents/collections/:n/upload` |
| search | `POST /api/collections/:n/search` | same | `POST /api/agents/collections/:n/search` |
| raw file | `GET …/entries/:e/raw` | *(absent)* | `GET …/entries-raw/*` |

**Practical conclusion:** a client written against LocalRecall works against all three if the
prefix is configurable. This is the single most useful thing to know when building tooling for
this stack.

## What embedding does *not* remove

The point most often missed. LocalRecall computes **no embeddings** — it is a client of an
OpenAI-compatible `/v1/embeddings`. That is true of the library form too.

```text
in-process retrieval  ->  removes the retrieval HTTP hop
                      ->  does NOT remove the embedding HTTP hop
```

So an "embedded" knowledge layer still makes a network call per search and per chunk ingested.
Verified: even in a single LocalAI container, the knowledge layer POSTs `/embeddings` to
`http://127.0.0.1:8080`.

## Same library, different robustness

The library and the service do not behave identically, because their callers configure them
differently:

| Behaviour | Standalone LocalRecall | Inside LocalAGI |
|---|---|---|
| `EMBEDDING_MODEL` default | **none** — empty model name on the wire | `granite-embedding-107m-multilingual` |
| `COLLECTION_DB_PATH` default | `./collections`, **working-directory-relative** | `<stateDir>/collections` |
| `FILE_ASSETS` default | `./assets`, working-directory-relative | `<stateDir>/assets` |
| Startup validation of embeddings config | **none** | none, but the model is defaulted |

The working-directory default is the dangerous one: LocalRecall's image is `FROM scratch`, so
"the working directory" is the ephemeral container layer. Collections silently vanish on
restart. The embedded form's state-dir-relative default is safer.

`OPENAI_BASE_URL` is worse still. `main.go:60-63` assigns `config.BaseURL = openAIBaseURL`
**unconditionally**, after `openai.DefaultConfig` has already set a real URL. An empty value
does not fall back — it overwrites the default with nothing, producing a bare relative
`/embeddings`. The process starts fine and the first ingestion fails.

## Three engines, unequal maturity

`VECTOR_ENGINE` selects one, read once at process start:

| Engine | Storage | Hybrid search | Concurrent readers | Notes |
|---|---|---|---|---|
| `chromem` (default) | one file | no | one process | not exercised in our run |
| `postgres` | database | **yes** | many | requires `pg_textsearch`; **tested** |
| `localai` | LocalAI's `/stores` API | no | — | `Reset`, `Count`, `GetEmbeddingDimensions` return `not implemented` |

The `localai` engine is a genuine trap: it is selectable, undocumented in upstream's own
environment table, and partially implemented. It is also conceptually interesting — LocalAI as
both embedder and vector store — which is presumably why it exists.

Hybrid search being **postgres-only** is the architectural justification for PostgreSQL in this
handbook's reference environment. BM25 lexical scoring is implemented only there, requires the
`pg_textsearch` extension, and is what makes exact-identifier queries work where embeddings do
poorly.

Observed extensions in `quay.io/mudler/localrecall:v0.6.4-postgresql`: `plpgsql`,
`pg_textsearch`, `vector`, `vectorscale`.

## Choosing, in practice

The decision is usually made for you:

| Situation | Form |
|---|---|
| Running a published LocalAGI image | **service** — there is no alternative |
| Running LocalAI's agent pool (Pattern A) | **library** — and it is the default |
| Building LocalAGI v2.9.0 from source | either |
| Two or more consumers need one knowledge base | service |
| You want to curl retrieval to diagnose it | service |

## Open questions

1. Does the `localai` engine's `Store` path work well enough to be useful despite the
   unimplemented methods? Not tested.
2. Does `vectorscale`'s presence mean DiskANN indexing is actually used, or merely available?
3. Why is the `localai` engine absent from upstream's documented `VECTOR_ENGINE` values?
   Abandoned, or simply undocumented?

## References

- `LocalRecall/routes.go` — the 11 routes; `newVectorEngine` at 87-116; the 502 and its
  `os.Exit` history comment; lazy rehydration at 121-156
- `LocalRecall/main.go:15-49, 60-63, 72-88` — variables, defaults, the base-URL overwrite
- `LocalRecall/Dockerfile` — `FROM scratch`
- `LocalRecall/rag/engine/postgres.go:63-94, 215-218, 290-293` — hybrid weights,
  `pg_textsearch`, BM25 index
- `LocalRecall/rag/engine/localai.go` — the `not implemented` methods
- `LocalAGI/webui/routes.go:217-227`, `LocalAGI/cmd/serve.go:113-120` — the two switches
- `LocalAGI/webui/collections/rag_provider.go:152-156` — the intent comment
- `LocalAGI/cmd/env.go:59-63, 88-90` — un-prefixed variables and the embedding default
- `LocalAGI/go.mod` at v2.8.1 — the absent dependency
- `LocalAI/core/http/routes/agents.go:80-93` — the `/api/agents/collections` group
- Route probes, extension list and latencies: observed 2026-08-17, [006](006-validation-log.md)
