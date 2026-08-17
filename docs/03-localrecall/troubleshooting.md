# LocalRecall troubleshooting

LocalRecall depends on exactly one thing — an embeddings endpoint — and is depended on by
the agent layer. Most of its failures are really failures of that one dependency, wearing
a LocalRecall error message.

Two properties shape every diagnosis on this page, so they come first.

!!! danger "There is no health endpoint, and there cannot be a healthcheck"
    LocalRecall exposes **eleven** routes, all under `/api/collections`. There is no
    `/health`, no `/readyz`, no `/metrics`.

    Its image is also built **`FROM scratch`**: no shell, no `curl`, no `wget`. A Docker
    `CMD` healthcheck cannot run inside the container at all, and neither can
    `docker exec localrecall ls`. Everything must be probed from outside.

    `GET /api/collections` is the closest thing to a health check — and it answers **from
    disk**, without touching the embeddings endpoint. A `200` proves the process is alive
    and proves **nothing** about whether ingestion or search will work.

## The ladder

```bash
curl -s -o /dev/null -w 'localai:     %{http_code}\n' http://localhost:8080/readyz
```

```bash
curl -s http://localhost:8080/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"granite-embedding-107m-multilingual","input":"probe"}' \
  | jq '.data[0].embedding | length'
```

```bash
docker exec localai-postgres pg_isready -U localrecall
```

```bash
curl -s -o /dev/null -w 'localrecall: %{http_code}\n' http://localhost:8082/api/collections
```

```bash
curl -s -X POST http://localhost:8082/api/collections \
  -H 'Content-Type: application/json' -d '{"name":"probe"}' | jq
```

| Step | If it fails |
|---|---|
| 1. LocalAI up | [LocalAI troubleshooting](../01-localai/troubleshooting.md) |
| 2. Embeddings work | [nothing here will work](#the-embeddings-edge) |
| 3. Database up | [storage failures](#storage-and-database-failures) |
| 4. Process up | [process failures](#the-process-will-not-start-or-answer) |
| 5. **Collection creation** | the first command that exercises the embeddings edge |

Step 5 is the important one. Creating a collection **constructs the vector engine**, which
connects to the database and reaches the embeddings endpoint. It is the cheapest real
end-to-end probe you have.

Or run the whole sequence:

```bash
./scripts/verify-stack.sh
```

## The embeddings edge

LocalRecall computes **no** embeddings. Every write and every search depends on an
OpenAI-compatible endpoint, and two variables configure it — neither validated at startup.

### `OPENAI_BASE_URL` unset breaks everything, silently

`main.go` assigns `config.BaseURL = openAIBaseURL` **unconditionally**, after
`openai.DefaultConfig` has already set the real OpenAI URL. An empty value does not fall
back to a default — it overwrites the default with nothing, so every request goes to a bare
relative `/embeddings`.

The process starts happily. `GET /api/collections` returns 200. The first ingestion fails.

```bash
docker inspect localrecall --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E 'OPENAI|EMBEDDING'
```

Use `docker inspect`, not `docker exec printenv` — there is no shell in this image.

### `EMBEDDING_MODEL` has no default

None at all. Unset means an **empty model name on the wire**, which LocalAI rejects. There
is no startup validation.

Note the contrast with LocalAGI, which supplies
`granite-embedding-107m-multilingual` as a default for the same library. Same code,
different robustness depending on who started it.

### No `/v1` on the base URL

LocalRecall uses the standard go-openai client, which appends the OpenAI path itself:

| Target | `OPENAI_BASE_URL` |
|---|---|
| LocalAI | `http://localai:8080` |
| Any OpenAI-compatible server | `http://host:port` |

This is the **opposite** of what LocalAGI needs, where cogito requires an explicit `/v1`
for non-LocalAI servers. Both happen to work against LocalAI, which is why the asymmetry
stays hidden until you substitute something else. See
[the `/v1` trap](../04-integration/api-flow.md#the-v1-trap).

## The process will not start or answer

```bash
docker logs localrecall 2>&1 | head -30
```

```bash
docker inspect localrecall --format '{{.State.Status}} exit={{.State.ExitCode}}'
```

Remember there is no shell in this image: `docker exec` cannot help, and neither can a
healthcheck. `docker logs` and `docker inspect` are the whole toolkit.

| Symptom | Cause | Fix |
|---|---|---|
| Exits immediately, no log | binary could not start | check the image tag actually exists |
| Starts, then nothing on 8082 | `LISTENING_ADDRESS` set to something unexpected | default is `:8080` **inside** the container; map it — `8082:8080` |
| `unknown vector engine: "…"` then exit | typo in `VECTOR_ENGINE` | `chromem`, `postgres` or `localai` |
| `DATABASE_URL is required for postgres engine` | engine set, URL not | set `DATABASE_URL` |
| Port in use on the host | another service on 8082 | change the published port |
| Exit code 137 | host OOM | raise the Docker memory limit |

Unlike LocalAGI, LocalRecall does **not** validate its embedding configuration at
startup. A process that starts cleanly tells you nothing about whether
`OPENAI_BASE_URL` and `EMBEDDING_MODEL` are usable — see
[the embeddings edge](#the-embeddings-edge).

## Symptom: `502 Vector backend unavailable`

```json
{"success":false,"error":{"code":"INTERNAL_ERROR","message":"Vector backend unavailable","details":"…"}}
```

This is LocalRecall telling you **the embeddings or database call failed** — not that its
API is broken. Read `details`; it carries the wrapped error.

| Cause | Check |
|---|---|
| Embeddings unreachable | step 2 of the ladder |
| `EMBEDDING_MODEL` wrong or empty | `docker inspect` the env |
| `OPENAI_BASE_URL` empty | as above |
| Database unreachable | `pg_isready` |
| `DATABASE_URL` missing with `VECTOR_ENGINE=postgres` | `docker inspect` the env |

The status code is deliberate. An earlier LocalRecall called `os.Exit` on this path and
crash-looped the server through transient embedding outages; the code now returns 502 so a
caller can retry. A comment in the source records the change.

## Symptom: upload fails although collection creation succeeded

Expected, and informative. Creation constructs the engine; **upload embeds every chunk**.
The embeddings edge is first exercised at scale here.

```bash
docker logs localrecall 2>&1 | tail -20
```

```bash
docker logs localrecall 2>&1 | grep -i chunk
```

A successful ingestion prints the chunking decision:

```text
INFO Chunked file file="/data/assets/handbook/<uuid>/note.txt"
     content_length=207 max_chunk_size=400 chunk_overlap=80 chunk_count=1
```

**This is the fastest way to confirm your chunk settings took effect.** No such line means
ingestion did not reach chunking.

## Symptom: search returns nothing for text you know is there

**1. Is the document actually in the collection?**

```bash
curl -s http://localhost:8082/api/collections/<name>/entries | jq
```

```json
{"success":true,"data":{"collection":"kb-probe","count":1,
  "entries":["kb-fact.txt"],
  "keys":["e040fb16-4b0b-4970-9ca4-f30f909ee50d/kb-fact.txt"]}}
```

Note the two fields: `entries` are base filenames, `keys` are the `<uuid>/<filename>`
index keys. Deletion takes the **entry**, not the key.

**2. Did you omit `max_results`?**

The default is not what you would guess. When absent or zero, LocalRecall sets it to **5**
if the collection holds five or more documents, and **1** otherwise. A small collection
silently returns a single chunk.

```bash
curl -s -X POST http://localhost:8082/api/collections/<name>/search \
  -H 'Content-Type: application/json' \
  -d '{"query":"your query","max_results":10}' | jq '.data.count'
```

Always set it explicitly.

**3. Did the embedding model change since ingestion?**

The fatal one. Vectors from a different model are not comparable, even at the same
dimension.

| Situation | Result |
|---|---|
| New model, different dimension | writes fail on dimension mismatch |
| New model, same dimension | writes succeed and **retrieval silently degrades** |

There is no migration. Re-ingest, or revert the model.

**4. Is the query simply distant?**

Embeddings are often trained asymmetrically, so a short question and a long passage that
answers it can score lower than expected. Try the stored wording verbatim as a query — if
*that* fails, the problem is the pipeline; if it succeeds, the problem is the query or the
chunking.

## Symptom: search returns something irrelevant

Not a malfunction. **There is no relevance threshold anywhere in this stack.** Top-*k*
returns *k* results if *k* chunks exist.

Measured on the reference embedding model: two unrelated sentences still score **0.54**,
against 0.87 for paraphrases. The floor is not zero, so nothing looks "unrelated enough"
to be excluded.

| Lever | Effect |
|---|---|
| Lower `max_results` / `kb_results` | fewer chances to inject noise |
| Larger `MAX_CHUNKING_SIZE` | more context per chunk, fewer fragments |
| Non-zero `CHUNK_OVERLAP` | stops sentences being cut at boundaries |
| PostgreSQL engine + hybrid search | BM25 handles exact identifiers, which embeddings match poorly |

Also note that search results carry **no similarity score**, so you cannot tell from the
response how good a match was. `Embedding` comes back `null` too — vectors are not
inspectable through the API.

## Symptom: collections vanish after a restart

The most damaging misconfiguration, and it is a default.

`COLLECTION_DB_PATH` and `FILE_ASSETS` default to `./collections` and `./assets`
**relative to the process working directory**. In a `FROM scratch` image, that is the
ephemeral container layer.

```bash
docker inspect localrecall --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -E 'COLLECTION_DB_PATH|FILE_ASSETS'
```

```bash
docker inspect localrecall --format '{{range .Mounts}}{{println .Destination}}{{end}}'
```

**Always set both explicitly and mount a volume**, as the reference environment does:

```yaml
environment:
  - COLLECTION_DB_PATH=/data/collections
  - FILE_ASSETS=/data/assets
volumes:
  - localrecall-data:/data
```

Note that LocalAGI, running the same library, resolves these **relative to its state
directory** instead — safer, and a real behavioural difference between embedded and
standalone.

## Symptom: a collection is searchable but raw files 404

Your two stores have diverged. A document is persisted **twice**:

| Copy | Where | Purpose |
|---|---|---|
| Original file | `FILE_ASSETS/<collection>/<uuid>/<filename>` | raw retrieval, re-chunking, compaction |
| Chunk text + vector | the vector store | returned by search |

With `VECTOR_ENGINE=postgres` those are **different volumes** — `localrecall-data` and
`postgres-data`.

**Back them up together or not at all.** Restoring only PostgreSQL gives searchable chunks
whose `/raw` endpoints 404; restoring only the assets gives files nothing can find.

## Storage and database failures

```bash
docker exec localai-postgres pg_isready -U localrecall
```

```bash
docker logs localrecall 2>&1 | grep -i -E 'postgres|pg_textsearch|migration|extension'
```

| Symptom | Cause | Fix |
|---|---|---|
| Error naming `pg_textsearch` | the extension is **required** for BM25 indexing and is absent | use an image that ships it — `quay.io/mudler/localrecall:<version>-postgresql`, not plain `postgres:*` |
| `DATABASE_URL is required for postgres engine` | engine set, URL not | set it |
| `unknown vector engine: "…"` | typo in `VECTOR_ENGINE` | `chromem`, `postgres` or `localai` |
| Connection refused | database not up, or wrong host | `depends_on` with `service_healthy` |

### PostgreSQL missing pg_textsearch

The most specific database failure, and the reason this handbook's reference environment
does not use a stock `postgres:` image.

```text
failed to enable pg_textsearch extension (required for BM25 indexing): …
```

Schema initialisation enables `pg_textsearch` and **fails outright** without it. The
extension backs the BM25 index that hybrid search depends on; there is no degraded
vector-only fallback on this engine.

```bash
docker exec -e PGPASSWORD=localrecall localai-postgres \
  psql -U localrecall -d localrecall -c "select extname from pg_extension;"
```

`PGPASSWORD` is required — without it `psql` prompts and fails non-interactively with
`fe_sendauth: no password supplied`.

Observed on `quay.io/mudler/localrecall:v0.6.4-postgresql`:

```text
    extname
---------------
 plpgsql
 pg_textsearch
 vector
 vectorscale
```

`pg_textsearch` backs BM25; `vector` is pgvector; `vectorscale` is pgvectorscale, which
adds DiskANN-style indexing. Three of the four are absent from a stock `postgres:` image
and `vectorscale` is absent from `pgvector/pgvector` too.

| Fix | Note |
|---|---|
| Use `quay.io/mudler/localrecall:<version>-postgresql` | LocalRecall's own build, ships both extensions. `v0.6.4-postgresql` verified present on quay.io 2026-08-17 |
| Add the extension to your own image | it is not in stock `postgres:*` or in `pgvector/pgvector` |
| Avoid it entirely | `VECTOR_ENGINE=chromem` — you lose hybrid search and multi-process access |

A related failure worth recognising: a **corrupt BM25 index** left inconsistent by an
interrupted migration can make queries fail on an otherwise healthy database. The engine
guards against a corrupt custom index access method; if you see errors naming the index
(`idx_<table>_bm25`), reindexing or resetting the collection is the way out.

### Slow ingestion on chromem

**Symptom:** ingestion of a large document set takes far longer than the per-chunk
embedding latency would suggest.

Ingestion cost is `chunks × embedding latency`, plus whatever the engine does per write.
At the default 400-character chunk size a moderately sized manual is thousands of chunks,
and the reference model's warm embedding call is 0.06–0.09 s — so tens of thousands of
chunks is tens of minutes of pure embedding.

Two engine-specific factors make it worse on `chromem`:

| Factor | Effect |
|---|---|
| Batching | engines differ; one embeds strictly **one chunk per call**, so there is no amortisation of request overhead |
| Single-file store | every write goes through one file opened by one process; there is no concurrent writer |

What actually helps, in order of effect:

1. **Raise `MAX_CHUNKING_SIZE`.** Fewer, larger chunks means proportionally fewer embedding
   calls. 400 is small; 1000–1500 is often better for prose, at some cost to retrieval
   precision.
2. **Move to PostgreSQL** if the collection is large or shared. It is a database rather
   than a file, and it is the only engine with concurrent readers.
3. **Do not lower `CHUNK_OVERLAP` to zero** to save calls. Overlap adds chunks
   sub-linearly and zero overlap cuts sentences at boundaries — a poor trade.

Watch the real numbers rather than guessing:

```bash
docker logs localrecall 2>&1 | grep -i 'Chunked file' | tail -5
```

```bash
docker logs localai 2>&1 | grep -c embeddings
```

Note that this is an **ingestion** concern only. Search costs exactly one embedding call
regardless of collection size, and measured **29–37 ms** end to end.

### Choosing an engine, and one to avoid

| Engine | Storage | Hybrid search | Concurrent readers |
|---|---|---|---|
| `chromem` (default) | one file | no | one process |
| `postgres` | database | **yes** | many |
| `localai` | LocalAI's `/stores` API | no | — |

**Do not use `localai` for new work.** Several methods on that engine return
`not implemented`, including `Reset`, `Count` and `GetEmbeddingDimensions`, so operations
the other engines support fail there. It is also undocumented in upstream's own environment
table. See [storage](storage.md#the-localai-engine).

## Symptom: `Failed to load collection at startup`

```text
ERROR Failed to load collection at startup; will retry lazily on first request
      collection=handbook engine=postgres error=…
```

Usually benign. At startup LocalRecall iterates over existing collections and constructs an
engine for each — which calls the embeddings endpoint. If LocalAI is not up yet, those
constructions fail, a `nil` placeholder is registered, and the engine is **rehydrated
lazily on first use**.

So one of these lines with everything otherwise working is a startup-ordering artefact, not
a fault. If a collection then 404s permanently, rehydration is also failing — chase the
underlying error.

`depends_on: localai: condition: service_healthy` avoids the noise, but is not load-bearing
for correctness.

## Symptom: the agent cannot see a collection that exists

Almost always naming. The agent's collection is the **lowercased agent name**, not
configurable.

```bash
curl -s http://localhost:8082/api/collections | jq '.data.collections'
```

An agent `Support-Bot` uses `support-bot`. Creating a collection called `docs` and expecting
`Support-Bot` to read it does not work.

Also confirm the agent is pointed at this service:

```bash
docker inspect localagi --format '{{range .Config.Env}}{{println .}}{{end}}' | grep LOCALRAG
```

On LocalAGI v2.8.1 — the newest published image — `LOCALAGI_LOCALRAG_URL` is **required**,
because that version has no in-process knowledge layer at all.

Full sequence: [Recipe 6](../05-recipes/agent-with-knowledge.md).

## Symptom: `reset` removed more than expected

`POST /api/collections/:name/reset` clears the collection **and deletes it from the
server's in-memory registry**. It is closer to a delete than a truncate; a subsequent
search 404s until the collection is recreated.

To remove one document instead:

```bash
curl -s -X DELETE http://localhost:8082/api/collections/<name>/entry/delete \
  -H 'Content-Type: application/json' -d '{"entry":"note.txt"}' | jq
```

The response returns `remaining_entries` and `entry_count`, which is the cheapest way to
confirm the deletion landed.

## External sources keep changing the collection

```bash
curl -s http://localhost:8082/api/collections/<name>/sources | jq
```

A registered source is polled and re-ingested. `update_interval` is in **minutes** and
defaults to **60** if you send anything below 1 — so `{"update_interval": 0}` means hourly,
not never.

This makes a collection a moving target, and a
[knowledge-poisoning surface](../06-deployment/security.md) if the URL is not under your
control. Remove one with `DELETE …/sources` and the same `{"url": …}` body.

## Reading the logs

Everything must come from `docker logs` — there is no shell in the container.

```bash
docker logs localrecall 2>&1 | grep -i chunk
```

The chunking decision, with `max_chunk_size` and `chunk_overlap`.

```bash
docker logs localrecall 2>&1 | grep -i -E 'Storing pieces|Stored file'
```

`count_before` and `count_after`, so you can watch a collection grow.

```bash
docker logs localrecall 2>&1 | tail -10
```

The Echo access log, one JSON line per request with `latency_human`. This is also where you
see **who** called: `remote_ip` and `user_agent`. A retrieval from the agent appears as
`Go-http-client/1.1` from the LocalAGI container's IP — which is how you prove the hop
happened rather than assuming it.

```bash
docker logs localai 2>&1 | grep -c embeddings
```

The other side of the edge. Should increase by one per search and once per chunk on
ingestion.

## Reference latencies

Measured with the PostgreSQL engine, CPU-only, on a 207-byte single-chunk document:

| Operation | Latency |
|---|---|
| Ingest (chunk, embed, store) | **34.9 ms** |
| Search, direct | **30.4 ms** |
| Search, as part of an agent request | **29–37 ms** |
| Embedding call alone, warm | 0.06–0.09 s |

Retrieval is not your bottleneck. If an agent request takes 25 seconds, ~30 ms of it was
retrieval — count model calls instead.

## Upstream references

- [LocalRecall `main.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/main.go) — unconditional base-URL overwrite at 60-63; `EMBEDDING_MODEL` with no default at 17; working-directory-relative paths at 33-45; chunk defaults 400 and 0 at 72-88; engine default at 47-49. Validated against v0.6.4.
- [LocalRecall `routes.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/routes.go) — all eleven routes; `newVectorEngine` and the deliberate 502 at 87-116 and 207-212, with the comment recording the earlier `os.Exit`; lazy rehydration at 121-156; `max_results` 5-or-1 default at 297-303; `reset` deleting the registry entry at 257-277; entry deletion response at 226-255.
- [LocalRecall `Dockerfile`](https://github.com/mudler/LocalRecall/blob/v0.6.4/Dockerfile) — `FROM scratch`, hence no shell and no in-container healthcheck.
- [LocalRecall `rag/engine/postgres.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/postgres.go) — `pg_textsearch` requirement at 215-218; hybrid weights at 63-94; BM25 index at 290-293.
- [LocalRecall `rag/engine/localai.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/localai.go) — the `not implemented` methods.
- [LocalRecall `rag/persistency.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/persistency.go) — asset copy into a UUID directory; the `Chunked file` and `Stored file` log lines.
- [LocalRecall `rag/source_manager.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/source_manager.go) — external source polling and the 60-minute floor.
- [LocalAGI `cmd/env.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/cmd/env.go) — the embedding-model default LocalAGI supplies and standalone LocalRecall does not.
- Response bodies, latencies, chunk log output, the `Cannot GET /api/collections` result on LocalAGI v2.8.1, and similarity scores: observed 2026-08-17, see [version matrix](../00-overview/version-matrix.md).
