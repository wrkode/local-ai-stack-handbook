# Deployment patterns

[Logical vs physical](../00-overview/logical-vs-physical.md) establishes *what* the
three patterns are. This page is the operational companion: how to choose one, what
each split actually costs, how to migrate between them, and which combinations to
avoid.

The short version: **start integrated, split one layer at a time, and only when a
specific pressure forces it.** Every split you make is a network hop, a failure
domain and a version pair you now own.

## Choosing, by pressure rather than by size

Deployment shape should be driven by a concrete constraint, not by how important
the system feels. Each row below is a reason to split; nothing else is.

| Pressure you actually have | Split to make |
|---|---|
| None yet | Pattern A, one container |
| Inference needs a GPU node; agents do not | LocalAI separate from LocalAGI |
| Agents restart often; you cannot afford model reloads | LocalAI separate from LocalAGI |
| Two or more consumers need the same knowledge | LocalRecall as a service |
| Knowledge must be backed up on its own schedule | LocalRecall as a service, PostgreSQL |
| Queries need exact-token matching | PostgreSQL engine — but not necessarily a separate service |
| You already have an OpenAI-compatible inference platform | LocalAGI only, pointed at it |
| You need agents from more than one replica | See [scaling](../07-deep-dives/scaling.md) first — this is the hard one |

Note the fourth-from-last row. Switching to PostgreSQL for hybrid search is a
*storage* decision, not a *topology* decision. You can run PostgreSQL with an
embedded knowledge layer and gain hybrid search without adding a LocalRecall
service. People routinely conflate these and add two components when they needed
one.

## Pattern A cannot read a Pattern B knowledge base

This is the constraint that decides whether the two patterns can coexist, so it
comes before the cost tables.

LocalAI v4.8.2 embeds LocalRecall as a **library**. Its agent-pool configuration is
storage-level throughout — there is no remote-server option:

| `LOCALAI_AGENT_POOL_*` | Equivalent LocalRecall variable |
|---|---|
| `VECTOR_ENGINE` | `VECTOR_ENGINE` |
| `EMBEDDING_MODEL` | `EMBEDDING_MODEL` |
| `DATABASE_URL` | `DATABASE_URL` |
| `COLLECTION_DB_PATH` | `COLLECTION_DB_PATH` |
| `MAX_CHUNKING_SIZE` | `MAX_CHUNKING_SIZE` |
| `CHUNK_OVERLAP` | `CHUNK_OVERLAP` |

Compare the two runtimes on the one question that matters:

| Runtime | Can point at a remote LocalRecall? | How |
|---|---|---|
| LocalAGI | **yes** | `LOCALAGI_LOCALRAG_URL` — empty selects the embedded base |
| LocalAI | **no** | no flag exists; `local_rag_url` on the agent is accepted and ignored |

!!! danger "`local_rag_url` is a field that does nothing"
    LocalAI's per-agent config includes `local_rag_url`. It accepts a URL, returns
    `201`, and persists the value — and has no effect. Tested three ways: LocalAI
    logs `Chromem collection ... dbPath="/data/collections"` at agent start with the
    URL set; the target LocalRecall's access log recorded **zero** requests from the
    agent across the whole test; and the same question that failed answered
    correctly once the identical sentence was uploaded to LocalAI's *own* collection.

    The field is inherited from the shared LocalAGI agent config struct, where it
    works. This is the same shape as the LocalAGI defect where embeddings do not
    follow `api_url`: **a populated URL field in this codebase is not evidence that
    anything reads it.**

So "chat in LocalAI, retrieve from my existing LocalRecall" is not a configuration
you can reach. The three ways out, in the order worth trying:

| Approach | Cost | Status |
|---|---|---|
| Chat in LocalAGI instead | none — `LOCALAGI_LOCALRAG_URL` already does this | **tested** |
| Re-ingest into LocalAI's own collections | duplicate storage and ingestion | **tested**, see [`kubernetes/pattern-a/`](https://github.com/wrkode/local-ai-stack-handbook/tree/main/kubernetes/pattern-a) |
| Point both at one PostgreSQL database | two processes migrating one schema | **untested** |
| Wrap LocalRecall as an MCP server | write and run a shim | **untested** |

The shared-database route is the tempting one and the one to be careful with. Both
sides embed the same library, so the schema *should* match — but two pods running
different library versions against one database can migrate it under each other.
Test it against a scratch database, never the one holding collections you want.

The migration direction that does work cleanly is B → A by re-ingestion, because
`LOCALAI_AGENT_POOL_EMBEDDING_MODEL` defaults to
`granite-embedding-107m-multilingual` — the same default LocalRecall uses. Leave it
alone and the vectors are comparable. Change it on either side and every stored
collection returns confident nonsense, with nothing in the log.

## What each split costs

Measured or source-verified, not estimated.

### Splitting LocalAI from the agent runtime

```text
before:  agent loop --loopback HTTP--> /chat/completions   (same process)
after:   agent loop --network HTTP---> /chat/completions   (another host)
```

| Effect | Detail |
|---|---|
| Latency added | one network RTT **per model call** — and one agent iteration can be three or more calls under forced reasoning |
| New failure mode | inference unreachable; the agent fails mid-loop after doing partial work, including tool side effects |
| New configuration | `LOCALAGI_LLM_API_KEY` must now match `LOCALAI_API_KEY`; both are silent when wrong |
| New timeout to order | any proxy between them, in addition to `LOCALAGI_TIMEOUT` |
| Gained | independent scaling, GPU placement, restart isolation, model reuse across agent deployments |

This is the split worth making first, because inference is the layer with genuinely
different hardware requirements. It is also the split where the
[`/v1` trap](api-flow.md#the-v1-trap) bites, since the URL becomes something you
type rather than something that defaulted.

### Splitting LocalRecall out as a service

```text
before:  agent --in-process Go call--> PersistentKB --> store
after:   agent --network HTTP-------> localrecall  --> store
```

| Effect | Detail |
|---|---|
| Latency added | one network RTT per retrieval, on top of the embedding call that already crossed the network |
| New failure mode | retrieval unreachable — the agent still returns HTTP 200 with a plausible, unsourced answer |
| New configuration | `LOCALAGI_LOCALRAG_URL`, plus API-key alignment; the HTTP provider defaults to reusing the *model* API key |
| Version pair you now own | LocalAGI's linked `localrecall` and the standalone service can differ |
| Gained | shared knowledge, independent backup, independent scaling of readers, something you can curl |

The failure mode deserves emphasis, and it is worth being precise about it because the
two cases differ. Verified by stopping the service and re-asking a question whose answer
existed only in the collection:

| Failure | Response | Log level |
|---|---|---|
| Knowledge service unreachable | `200`, `status: completed`, **hallucinated answer** | **INFO** — `Error finding similar strings inside KB`, with the dial error |
| Knowledge disabled by config | `200`, `status: completed`, unsourced answer | **DEBUG** only |

Either way the agent stays *available* while becoming *unreliable*, so liveness
monitoring will not notice. Alert on the INFO line for the first case, and assert agent
configuration separately for the second. See
[observability](../06-deployment/observability.md).

### Splitting to PostgreSQL

| Effect | Detail |
|---|---|
| Latency | comparable for small collections; better for large ones with an index |
| New failure mode | database unreachable, connection exhaustion, migration failure |
| New requirement | the `pg_textsearch` extension, required for BM25 indexing |
| Gained | hybrid search, concurrent readers, real backup and restore, real operational tooling |
| Lost | the ability to move a collection by copying a file |

This is the only split that makes multi-reader knowledge safe. A chromem file store
is opened by one process; PostgreSQL is a database.

## Migration paths

### A → B: extracting LocalAI

The mechanical part is easy; the data part is what to plan.

1. Start LocalAI separately with the **same `/models` and `/backends` volumes** if
   you want to avoid re-downloading. They are portable.
2. Point the agent runtime at it. Confirm the model name resolves —
   `GET /v1/models` — before starting agents.
3. Disable the agent pool on the LocalAI side if you do not want two pools
   competing for the same state directory.

Agent state is **not** portable in the way volumes are: in Pattern A it lives in
LocalAI's `/data`; standalone LocalAGI expects `LOCALAGI_STATE_DIR`. The pool JSON
format is shared, but confirm your agents appear (`GET /api/agents`) before
declaring the migration done. Nothing validates that the directory you mounted is
the one holding your agents — an empty state directory produces an empty pool and
no error.

### A or B → LocalRecall as a service

This is the migration with a real data hazard, so do it deliberately.

An embedded knowledge layer wrote its store somewhere specific:
`COLLECTION_DB_PATH`, defaulting to `<stateDir>/collections`, with assets under
`<stateDir>/assets`. Standalone LocalRecall defaults both **relative to its working
directory** instead.

```bash
# inspect what exists before moving anything
docker exec localagi ls -la /pool/collections /pool/assets
```

Then either mount those exact paths into the new service and set
`COLLECTION_DB_PATH` and `FILE_ASSETS` to match, or accept re-ingestion. Copying
the collections directory without the assets directory produces a searchable
collection whose raw-file endpoints 404 — the vectors moved and the originals did
not.

After switching, set `LOCALAGI_LOCALRAG_URL` and verify **both** directions:

```bash
curl -s http://localhost:8082/api/collections | jq '.data.collections'
```

```bash
curl -s -X POST http://localhost:8081/api/collections/<agent-name>/search \
  -H 'Content-Type: application/json' -d '{"query":"known phrase","max_results":3}'
```

The second command goes to LocalAGI, which should now be proxying. If it returns
results, both switches flipped. If it returns an empty collection list while the
first command shows collections, LocalAGI is still using its embedded backend —
check that the variable reached the process.

### Reverting

Both migrations reverse cleanly *except* for collection location. Reverting to
embedded means the store must be back where the embedded engine looks for it. Keep
`COLLECTION_DB_PATH` set explicitly in both directions and reverting is a variable
change; leave it defaulted and it is a data hunt.

## Anti-patterns

Each of these has a specific failure signature.

**Two agent pools on one state directory.** Running Pattern A's built-in pool *and*
a standalone LocalAGI against the same `/data` gives two processes writing one JSON
inventory. Last writer wins; agents vanish. Disable one pool.

**Splitting LocalRecall while leaving `VECTOR_ENGINE=chromem` on a shared volume.**
Two processes, one file store. Use PostgreSQL when more than one process needs the
data.

**Adding PostgreSQL without `pg_textsearch`.** Initialisation fails with an
explicit error about the extension being required for BM25 indexing. This is why
the reference environment uses an image that ships it rather than plain
`postgres:*`.

**Separate services, one API key assumed.** Each hop authenticates independently:
`LOCALAI_API_KEY` inbound to LocalAI, `LOCALAGI_LLM_API_KEY` outbound from LocalAGI,
`LOCALAGI_API_KEYS` inbound to LocalAGI, `API_KEYS` inbound to LocalRecall. Setting
one and assuming the rest follow produces 401s on the internal hops while the
external surface looks healthy.

**Using an external inference provider with LocalAI's distributed executor.** The
executor reuses one base URL for both the LLM call and the collection lookup, so
pointing it at a hosted provider aims `/api/agents/collections/...` there too. The
result is a 404, a logged warning, and **knowledge silently disabled**.

**A reverse proxy with default timeouts in front of an agent.** 60 seconds is
typical; a legitimate agent request can exceed it. The client sees a 504 while the
agent runs to completion and commits its tool side effects.

## Pattern comparison, operationally

| | A: integrated | B: separated | C: composable |
|---|---|---|---|
| Processes | 1 + backends | 2–3 + backends | varies |
| Containers to monitor | 1 | 2–4 | varies |
| Internal hops that can fail | loopback only | real network | real network |
| Version skew possible | no | yes | yes |
| GPU node isolation | no | yes | yes |
| Independent knowledge backup | no | yes, with the service | yes |
| Agent scaling | no | limited — see [scaling](../07-deep-dives/scaling.md) | limited |
| Time to first working request | minutes | tens of minutes | varies |
| Good for | learning, single-node, most self-hosting | GPU separation, shared knowledge | integrating with existing platforms |

## Where to go next

- [Complete stack](complete-stack.md) — a concrete Pattern B configuration.
- [`compose/`](https://github.com/wrkode/local-ai-stack-handbook/tree/main/compose)
  — the reference environment with justification per service.
- [Kubernetes](../06-deployment/kubernetes.md) — the same patterns as manifests,
  including which components cannot scale naively.
- [Production](../06-deployment/production.md) — what is missing for each pattern.

## Upstream references

- [LocalAGI `cmd/serve.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/cmd/serve.go) — state-dir-relative collection and asset defaults at 48-53; RAG provider fork at 113-120. Validated against v2.9.0.
- [LocalAGI `core/state/pool.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/state/pool.go) — HTTP RAG provider defaulting to the LLM API key at 36-49.
- [LocalAGI `core/agent/knowledgebase.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/agent/knowledgebase.go) — debug-only logging when retrieval is unavailable at 19-31.
- [LocalRecall `main.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/main.go) — working-directory-relative defaults at 33-41. Validated against v0.6.4.
- [LocalRecall `rag/engine/postgres.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/postgres.go) — `pg_textsearch` requirement at 215-218.
- [LocalAI `core/services/agents/knowledge.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/services/agents/knowledge.go) — the shared base URL in the distributed executor. Validated against v4.8.2.
- [LocalAI `core/config/application_config.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/config/application_config.go) — agent pool enable flag.
