# Storage engines and on-disk state

`VECTOR_ENGINE` picks one of three backends, read once at process start and
defaulted to `chromem`. The switch is four cases (`routes.go:87-116`):

| Value | Constructor | Extra requirement |
|---|---|---|
| `chromem` (default) | `rag.NewPersistentChromeCollection` | — |
| `postgres` | `rag.NewPersistentPostgresCollection` | `DATABASE_URL` |
| `localai` | `rag.NewPersistentLocalAICollection` | a LocalAI `/stores` endpoint |
| anything else | — | error `unknown vector engine: %q` |

There is no milvus, qdrant, weaviate or faiss support, and no plugin mechanism —
the switch is compiled in.

> **Discrepancy (#4).** `README.md:18-21` advertises two engines, Chromem and
> PostgreSQL, and the env table row for `VECTOR_ENGINE` (`README.md:203`) names
> only those two. The `localai` engine is a real, selectable third value
> (`routes.go:99`). It is arguably omitted on purpose — most of it is
> unimplemented — but it is undocumented, not removed. Believe the code that it
> exists; believe the README that you should not use it.

`DATABASE_URL` is the only environment variable not hoisted into `main.go`'s var
block; it is read lazily inside the `postgres` case.

## Filesystem state exists under every engine

Choosing PostgreSQL does **not** make a deployment stateless on disk. Independent
of `VECTOR_ENGINE`, every collection has:

| Path | Contents | Lost if you lose it |
|---|---|---|
| `<COLLECTION_DB_PATH>/collection-<name>.json` | **only** `{"external_sources": [...]}` | the source registry, and the collection's very existence in `GET /api/collections` |
| `<FILE_ASSETS>/<collection>/<uuid>/<filename>` | the original uploaded bytes, mode 0644 | every original; downloads and entry-content break; `Repopulate` has nothing to re-chunk |

Three behaviours follow from that layout, and they explain most confusing
symptoms:

- **The document list is filesystem-derived, not index-derived.** `ListDocuments`
  walks the asset directory taking every file inside every subdirectory. That is
  why entries list correctly while the vector store is down — and why deleting
  files under `FILE_ASSETS` out of band makes entries disappear while their chunks
  remain in the store, permanently orphaned.
- **Entry resolution falls back to basename.** `findEntryKey` tries an exact
  `uuid/filename` match, then matches on `filepath.Base`. So `GET
  /entries/report.pdf` works without knowing the UUID — but if two UUID
  directories hold the same basename, **the first match wins arbitrarily**, by
  directory iteration order.
- **A one-time layout migration runs on open.** If any *file* sits directly in the
  asset directory, `migrateToUUIDLayout` rewrites the whole directory into the
  UUID scheme, copying then removing.

`loadDB` also tolerates three historical state-file formats: the current object,
an older object carrying an `index` field, and an even older bare JSON array of
strings. The `index` field was the persisted chunk index, dropped in v0.5.9;
chunk-to-file mapping is now resolved by querying the engine for
`metadata.source`.

**What to back up:** `COLLECTION_DB_PATH` and `FILE_ASSETS` under every engine,
plus the database under `postgres`. Backing up only PostgreSQL loses the source
registry and every original file.

## chromem — the default

`rag/engine/chromem.go`, wrapping `github.com/philippgille/chromem-go v0.7.0`.
Opened as `chromem.NewPersistentDB(path, true)`, where `true` means *compress*.

### On-disk layout

- Base directory is `COLLECTION_DB_PATH` — the **same directory** that holds the
  `collection-*.json` state files.
- Each collection gets a subdirectory named `hash2hex(collectionName)`: the first
  4 bytes of the SHA-256 of the name, hex-encoded — **8 hex characters**.
  Collection names are therefore **not recoverable** from the vector store
  directory. Map them via the `collection-*.json` filenames.
- **One file per document**, named `hash2hex(docID)`, gob-encoded and
  gzip-compressed because compression is on — `.gob.gz`.
- Plus one `metadata` file per collection.

```text
<COLLECTION_DB_PATH>/
├── collection-handbook.json          # external sources only
├── 3f7a2b91/                         # SHA-256[0:4] of "handbook"
│   ├── metadata
│   ├── 0a1b2c3d.gob.gz               # one chunk
│   ├── 4e5f6a7b.gob.gz
│   └── …                             # one file per chunk
└── …
```

A 10,000-chunk collection is 10,000 small files in one directory. Every
`AddDocuments` call writes a file per document. Plan inode budget and directory
performance accordingly, and expect backup tools to be slow over this layout.

### No ANN index — what that means

Retrieval is **brute force**. chromem-go iterates every candidate document,
computes a dot product against the normalised query vector, and keeps a bounded
max-heap of size K. Cost is O(N·d) per query, in memory, parallelised across
goroutines.

There is no HNSW, no IVF, no product quantisation, no clustering — nothing that
lets a query skip candidates. Concretely:

| Collection size | Behaviour |
|---|---|
| Hundreds to low thousands of chunks | fine; latency dominated by the embedding round trip |
| Tens of thousands | noticeable per-query CPU cost, growing linearly |
| Hundreds of thousands and beyond | every query scans everything, every time |

Add the per-collection mutex from [architecture](architecture.md#persistentkb) —
searches serialise — and the ceiling arrives sooner than raw single-query timing
suggests. **Chunk count is the number that matters, not document count**; 400-byte
default chunks reach large N quickly.

### Other chromem specifics

- **IDs are a monotonic integer counter**, not UUIDs: it starts at 1 and is set to
  `count+1` on open. After deletions `Count()` shrinks while old IDs persist, so
  the counter can collide with existing IDs. Do not treat chromem chunk IDs as
  stable or unique across a collection's lifetime.
- `StoreDocuments` batches into one `AddDocuments` call with `runtime.NumCPU()`
  parallelism — but each document still costs its own embedding HTTP request, see
  [embeddings](embeddings.md#batching-differs-by-engine).
- `GetBySource` is a workaround: it issues a query with the dummy string `"."`,
  `nResults = Count()`, and a `where` filter on `source`. Correct, but it burns an
  embedding call and a full scan per entry lookup — which means viewing an entry
  in the UI costs an embedding call.
- `GetEmbeddingDimensions` reads the document whose ID equals the current count
  and returns its vector length; it errors with `"no documents in collection"`
  when empty.

## postgres

`rag/engine/postgres.go`, 977 lines, the largest file in the repository, on
`jackc/pgx/v5` with a pool. This is where essentially all recent engineering
attention has gone.

### Extensions

`setupDatabase` runs in a fixed order:

1. **`CREATE EXTENSION IF NOT EXISTS pg_textsearch` — mandatory.** A failure
   aborts construction. This is Timescale's `pg_textsearch`, providing the `bm25`
   index access method and the `<@>` / `to_bm25query` operators. Without it there
   is no hybrid search and no collection.
2. Vector extension probing, in preference order: an existing `vectorscale` or
   `pgvectorscale`; else `CREATE EXTENSION vectorscale CASCADE`; else
   `CREATE EXTENSION pgvectorscale CASCADE`; else plain **pgvector**
   (`CREATE EXTENSION vector`). Only that last failing is fatal.

So: **pgvector is the baseline, pgvectorscale/DiskANN is the preferred upgrade,
`pg_textsearch` is non-negotiable.** Not paradedb, despite the BM25 vocabulary.

If you bring your own PostgreSQL rather than using `Dockerfile.pgsql`, those three
extensions plus `shared_preload_libraries = 'timescaledb,pg_textsearch'` are your
responsibility. See [installation](installation.md#dockerfilepgsql).

### Schema

One shared registry table:

```sql
CREATE TABLE IF NOT EXISTS collection_config (
    collection_name      TEXT PRIMARY KEY,
    embedding_model      TEXT NOT NULL,
    embedding_dimensions INTEGER NOT NULL,
    created_at           TIMESTAMP DEFAULT NOW(),
    updated_at           TIMESTAMP DEFAULT NOW()
)
```

And **one table per collection**:

```sql
CREATE TABLE IF NOT EXISTS documents_<sanitized> (
    id          SERIAL PRIMARY KEY,
    title       TEXT,
    content     TEXT NOT NULL,
    category    TEXT,
    metadata    JSONB,
    word_count  INTEGER,
    search_vector TSVECTOR,
    full_text   TEXT GENERATED ALWAYS AS (COALESCE(title,'') || ' ' || content) STORED,
    embedding   VECTOR(<embeddingDims>)
)
```

`collection_config` is the migration ledger: it is what lets the engine notice
that your embedding model changed. Do not drop it.

### Table naming

`sanitizeTableName` prefixes `documents_` and replaces every rune outside
`[a-zA-Z0-9_]` with `_`. If the sanitised name does not start with a letter,
`col_` is inserted before it — `9lives` becomes `documents_col_9lives`.

The allowlist closes SQL injection, which matters because table names are
necessarily interpolated with `fmt.Sprintf` rather than bound (identifiers cannot
be parameters). It does **not** close collisions: `a-b`, `a.b` and `a b` all map to
`documents_a_b` and **silently share one table**. Nothing detects this.

The allowlist exists because the previous version stripped only a hardcoded set of
characters, so a `:` used as a namespace separator in per-user collection names
reached `CREATE TABLE` and produced `syntax error at or near ':'`. The fix shipped
in v0.6.3. Naming guidance is in
[collections](collections.md#naming).

### Indexes

| Index | Definition | On failure |
|---|---|---|
| `idx_<t>_search` | `GIN(search_vector)` | warning only |
| `idx_<t>_bm25` | `USING bm25(full_text) WITH (text_config='<cfg>')` | **fatal** |
| `idx_<t>_embedding` | `USING diskann(embedding)` when vectorscale is present; falls back to `USING hnsw(embedding vector_cosine_ops)`; if that also fails, **no index at all** and only a warning | warning |

Two things to notice.

**`search_vector` is dead weight at v0.6.4.** It is populated on every INSERT via
`to_tsvector('english', ...)` and its GIN index is built — and nothing ever
queries it. The hybrid search uses `full_text` and the BM25 index. You are paying
write cost and storage for an unused index.

**A collection can end up with no vector index and keep working**, on sequential
scans, because the third fallback only warns. On a large table that is the
difference between milliseconds and a statement timeout. Check for
`idx_<table>_embedding` after creating a collection on a fresh database.

### BM25 text configuration

`BM25_TEXT_CONFIG`, default `english`, is the v0.6.4 feature (PR #52). Two
supporting behaviours:

- `ensureTextSearchConfig` auto-provisions exactly one custom configuration,
  `de_en`, copying `pg_catalog.simple` and mapping word tokens through **both**
  `german_stem` and `english_stem`. Any other value is passed through as a
  built-in PostgreSQL text-search configuration name.
- `ensureBM25IndexConfig` makes the setting idempotent: it reads
  `pg_get_indexdef`, and if the live index does not contain
  `text_config='<desired>'` it **drops** the index so the following
  `CREATE INDEX IF NOT EXISTS` rebuilds it.

**Changing `BM25_TEXT_CONFIG` therefore triggers a full BM25 index rebuild on the
next startup.** On a large collection, expect a long startup.

Neither the LocalRecall build linked by LocalAI v4.8.2 (`v0.6.3`) nor the one
linked by standalone LocalAGI has this variable — it landed in v0.6.4.

### Connection timeouts

Set as pgx `RuntimeParams` before the pool opens:

| Parameter | Environment variable | Default |
|---|---|---|
| `lock_timeout` | `POSTGRES_LOCK_TIMEOUT` | `30s` |
| `idle_in_transaction_session_timeout` | `POSTGRES_IDLE_IN_TRANSACTION_TIMEOUT` | `300s` |
| `statement_timeout` | `POSTGRES_STATEMENT_TIMEOUT` | unset |

`"0"` or `"off"` (case-insensitive) is an explicit opt-out. The long in-source
comment records the motivating incident: a corrupt BM25 index, left inconsistent
by a past `pg_resetwal`, made an INSERT spin forever on a buffer-content lock
while holding its relation lock, head-of-line-blocking the entire table.
`lock_timeout` is described in-source as the cascade-killer.

`statement_timeout` is deliberately left unset, because a legitimate DiskANN or
HNSW build can exceed any fixed limit. Index builds are additionally exempted via
`execNoStatementTimeout`, which wraps the DDL in a transaction with
`SET LOCAL statement_timeout = 0`. If you set `POSTGRES_STATEMENT_TIMEOUT`
globally on the server instead, you will break index creation.

### Reset and delete

`Reset` drops the collection table `CASCADE`, deletes the `collection_config` row,
then re-runs `setupDatabase()`. Metadata-scoped deletes build `metadata->>$1 = $2`
conditions with both the key and the value bound.

**What PostgreSQL does not hold:** the uploaded files and the external-source
list. Those are always on the local filesystem. PostgreSQL holds chunks,
embeddings and metadata only.

## The `localai` engine

Undocumented in the README, and largely unimplemented. Seven of its nine `Engine`
methods are stubs or no-ops:

| Method | Reality |
|---|---|
| `Reset` | `not implemented` |
| `Count` | hardcoded `0` |
| `GetEmbeddingDimensions` | `not implemented` |
| `Delete` | `not implemented` |
| `GetByID` | `not implemented` |
| `GetBySource` | `not implemented` |
| `Store` | prints a notice that LocalAI stores have no IDs so entries cannot be deleted, and returns an empty ID |
| `StoreDocuments` | loops calling `Store` — one embedding round trip per chunk |
| `Search` | works: embeds the query, calls `stores/find` with `TopK`; results carry **no ID and no Metadata** |

It talks to LocalAI's `/stores/{set,get,delete,find}` API through a vendored copy
of LocalAI's store client, whose own header notes it is a duplicate.

The knock-on effects make it effectively unusable.
`NewPersistentLocalAICollection` unconditionally calls `Repopulate()` at
construction, with an in-source `TODO` admitting it does not work because there is
no `Reset()` and LocalAI stores are neither persistent nor upsert-capable.
`Repopulate` reaches `Engine.Reset()` and gets the not-implemented error — but the
constructor **discards** the return value, so construction succeeds anyway.
`RemoveEntry` and `GetEntryContent` then hard-fail against this backend, and
`Count()` returning 0 makes `PersistentKB.Count()` meaningless.

**Do not select `localai`.** It is documented here so that a reader who finds it
in a config knows what they are looking at.

## Choosing

| | chromem | postgres |
|---|---|---|
| Setup | none | a database with three extensions |
| Search | dense only | **hybrid BM25 + vector, RRF** |
| Index | **none — brute force** | DiskANN or HNSW |
| Embedding requests per N-chunk file | **N** | 1 |
| Scale ceiling | thousands to low tens of thousands of chunks | millions of rows, with the indexes healthy |
| Score returned | cosine `[-1,1]` | RRF `(0, ~0.0164]` |
| Operational surface | a directory of small files | a database to run, back up and monitor |
| Migration on model change | none (dimension change forces a full re-ingest) | a real, transactional migration |

Start on chromem for a single-node deployment holding a few thousand chunks. Move
to PostgreSQL when any of these becomes true: query latency grows with the corpus;
you need keyword matching for identifiers and error codes; ingestion time is
dominated by per-chunk HTTP; or more than one process needs the same collection.
Migration guidance is in [rag](rag.md#when-to-move-to-postgresql).

## Upstream references

- [`routes.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/routes.go) — `newVectorEngine` switch at 87-116; `DATABASE_URL` at 103-106. Source-verified against v0.6.4, validated 2026-08-17.
- [`rag/engine/chromem.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/chromem.go) — `NewPersistentDB(path, true)` at 23, integer ID counter at 31 and 42-46, `StoreDocuments` at 150, `GetBySource` dummy query at 177-180, dimensions at 67-79. Validated 2026-08-17.
- [`rag/engine/postgres.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/postgres.go) — `setupDatabase` at 212-313, `collection_config` at 250-258, per-collection DDL at 264-276, `sanitizeTableName` at 112-133, indexes at 283-306 and `createVectorIndex` at 372-397, `ensureTextSearchConfig` at 320-336, `ensureBM25IndexConfig` at 342-366, `applyConnTimeouts` at 174-191 with rationale at 151-173, `execNoStatementTimeout` at 197-210, `Reset` at 595-612, metadata delete at 759-772. Validated 2026-08-17.
- [`rag/engine/localai.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/localai.go) — the unimplemented methods at 26-36 and 83-93; `Store` notice at 76-80; `Search` at 95-131. Validated 2026-08-17.
- [`rag/engine/localai/client.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/localai/client.go) — vendored LocalAI store client, `stores/*` calls at 59-98. Validated 2026-08-17.
- [`rag/collection.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/collection.go) — state-file paths at 27, 45, 70; the discarded `Repopulate()` at 53-55. Validated 2026-08-17.
- [`rag/persistency.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/persistency.go) — asset layout at 353-355, `listDocumentKeys` at 137-160, `findEntryKey` at 164-183, `migrateToUUIDLayout` at 717-763, legacy `loadDB` formats at 42-72. Validated 2026-08-17.
- [`philippgille/chromem-go v0.7.0`](https://github.com/philippgille/chromem-go/blob/v0.7.0/persistence.go) — `hash2hex` at 22-27; per-document gzipped gob files in [`db.go`](https://github.com/philippgille/chromem-go/blob/v0.7.0/db.go) at 61 and 77-85. Read at the pinned tag, validated 2026-08-17.
- [LocalRecall release v0.6.4](https://github.com/mudler/LocalRecall/releases/tag/v0.6.4) — `BM25_TEXT_CONFIG` (PR #52), `pg_textsearch` pin (PR #50). Validated 2026-08-17.
- [`README.md`](https://github.com/mudler/LocalRecall/blob/v0.6.4/README.md) — two-engine claim at 18-21 and 203. Validated 2026-08-17.
