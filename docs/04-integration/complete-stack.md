# The complete stack

A concrete configuration of all three projects plus a vector database, with every
value explained and every edge verifiable. This is the assembled form of the
per-pair pages; read those first if a specific edge is what you are after.

The runnable version of everything below lives in
[`compose/`](https://github.com/wrkode/local-ai-stack-handbook/tree/main/compose).
This page explains *why* it is shaped that way.

## What "complete" means here

Four processes, chosen so that every logical boundary is also a physical one:

```mermaid
flowchart TB
  APP["Application"]
  subgraph AGP["localagi :3000"]
    LOOP["agent loop (cogito)"]
    PROXY["/api/collections<br/>proxied"]
  end
  subgraph LRP["localrecall :8080"]
    ING["ingest + chunk"]
    ENG["postgres engine"]
  end
  subgraph LAIP["localai :8080"]
    CHAT["/v1/chat/completions"]
    EMB["/v1/embeddings"]
  end
  BE["backend process<br/>cpu-llama-cpp"]
  PG[("postgres<br/>pgvector + pg_textsearch")]
  MCPS["MCP server"]

  APP -->|"/v1/responses"| LOOP
  LOOP -->|"HTTP"| CHAT
  LOOP -->|"HTTP search"| ENG
  PROXY -->|"HTTP"| ING
  ING -->|"HTTP embeddings"| EMB
  ENG -->|"HTTP embeddings"| EMB
  ENG -->|SQL| PG
  CHAT -->|gRPC| BE
  LOOP -->|"MCP"| MCPS
```

This is **not the minimum**. The minimum is one LocalAI container being all three
layers. The value of the separated form is that each edge can be probed, broken and
timed independently — which is why the [recipes](../05-recipes/index.md) build up to
it rather than starting here.

## The configuration, annotated

### LocalAI — the model runtime

```yaml
image: localai/localai:v4.8.2
command:
  - qwen3-1.7b
  - granite-embedding-107m-multilingual
environment:
  - LOCALAI_DISABLE_AGENTS=true
volumes:
  - localai-models:/models
  - localai-backends:/backends
  - localai-configuration:/configuration
```

| Choice | Why |
|---|---|
| Two positional models | Installed at startup. One LLM, one embedding model — the stack needs both, and they are different models on the same runtime. |
| `LOCALAI_DISABLE_AGENTS=true` | **The important one.** LocalAI ships its own agent pool, enabled by default. Leaving it on gives you two agent runtimes; if they share a state directory, agents disappear. |
| Three volumes, not one | `/models` alone is what most quickstarts show. Backends re-download without `/backends`, and settings reset without `/configuration`. |
| No `/data` volume | Only needed for LocalAI's own agent pool, which is disabled here. In Pattern A it is essential. |

### PostgreSQL — the vector store

```yaml
image: quay.io/mudler/localrecall:v0.6.4-postgresql
environment:
  - POSTGRES_DB=localrecall
  - POSTGRES_USER=localrecall
  - POSTGRES_PASSWORD=localrecall
```

Not `postgres:16`. LocalRecall's schema initialisation enables `pg_textsearch`,
which is required for BM25 indexing, and fails outright if it is unavailable. This
image is LocalRecall's own build and ships both it and pgvector. Tag verified
present on quay.io 2026-08-17.

If you do not need lexical matching, drop this service entirely and set
`VECTOR_ENGINE=chromem`. That is a supported configuration and one fewer stateful
component. The decision is:

| | chromem | postgres |
|---|---|---|
| Storage | one file | a database |
| Hybrid search | no | **yes** |
| Concurrent readers | one process | many |
| Backup | copy a file | `pg_dump` |
| Exact-identifier queries | poor | good |

### LocalRecall — the knowledge layer

```yaml
image: quay.io/mudler/localrecall:v0.6.4
environment:
  - OPENAI_BASE_URL=http://localai:8080
  - EMBEDDING_MODEL=granite-embedding-107m-multilingual
  - VECTOR_ENGINE=postgres
  - DATABASE_URL=postgresql://localrecall:localrecall@postgres:5432/localrecall?sslmode=disable
  - COLLECTION_DB_PATH=/data/collections
  - FILE_ASSETS=/data/assets
  - LISTENING_ADDRESS=:8080
  - MAX_CHUNKING_SIZE=400
  - CHUNK_OVERLAP=80
volumes:
  - localrecall-data:/data
```

Every one of those is load-bearing:

| Variable | Consequence of getting it wrong |
|---|---|
| `OPENAI_BASE_URL` | Unset does **not** fall back to a default. It overwrites go-openai's default with nothing, and every embedding call goes to a bare relative `/embeddings`. The process starts fine and the first ingestion fails. |
| `EMBEDDING_MODEL` | No default at all. An empty model name goes on the wire. |
| `COLLECTION_DB_PATH`, `FILE_ASSETS` | Default relative to the working directory. In a `FROM scratch` image, that is the ephemeral container layer — collections vanish on restart. **Always set both.** |
| `CHUNK_OVERLAP` | Upstream default is `0`, which cuts sentences at chunk boundaries. 20% of chunk size is a better starting point. |

No `/v1` on the base URL here, deliberately. LocalRecall's client appends the
OpenAI path itself; cogito, one service over, does not. See
[the `/v1` trap](api-flow.md#the-v1-trap).

### LocalAGI — the agent runtime

```yaml
image: quay.io/mudler/localagi:v2.8.1
environment:
  - LOCALAGI_LLM_API_URL=http://localai:8080
  - LOCALAGI_MODEL=qwen3-1.7b
  - LOCALAGI_STATE_DIR=/pool
  - LOCALAGI_LOCALRAG_URL=http://localrecall:8080
  - LOCALAGI_TIMEOUT=5m
ports:
  - "8081:3000"
volumes:
  - localagi-pool:/pool
```

| Choice | Why |
|---|---|
| `v2.8.1` | `v2.9.0` has no published image. Independently re-verified against the quay tag list 2026-08-17. |
| `8081:3000` | The listen address is hardcoded in `cmd/serve.go`. No variable changes it. |
| `LOCALAGI_LOCALRAG_URL` set | Flips **both** the agent's retrieval provider and the `/api/collections` backend from in-process to HTTP. Omit it and the `localrecall` service is unused. |
| `LOCALAGI_STATE_DIR=/pool` + volume | Agent definitions are JSON here. Without the volume, every agent is lost on restart. |

## Startup ordering, and why it matters

Dependencies are real, not cosmetic:

```mermaid
flowchart LR
  PG["postgres<br/>service_healthy"] --> LR["localrecall<br/>service_started"]
  LAI["localai<br/>service_healthy"] --> LR
  LAI --> AG["localagi"]
  LR --> AG
```

LocalRecall iterates over existing collections at startup and constructs a vector
engine for each — which calls the embedding endpoint. If LocalAI is not up yet,
those constructions fail. Current versions handle this gracefully: a `nil`
placeholder is registered and the engine is rehydrated lazily on first use, with an
error logged. Earlier versions called `os.Exit` here and crash-looped through
transient embedding outages.

So `depends_on` improves the first-boot experience but is not load-bearing for
correctness. Worth knowing when you see one `Failed to load collection at startup;
will retry lazily` line and nothing else wrong.

**`localrecall` gets `service_started`, not `service_healthy`**, because it cannot
have a healthcheck: the image is built `FROM scratch` and contains no shell, curl
or wget. There is also no `/health` route. Probe it externally with
`GET /api/collections`, remembering that this answers from disk and says nothing
about the embeddings edge.

## Bringing it up and proving it works

```bash
cd compose
cp .env.example .env
docker compose up -d
```

```bash
./scripts/verify-stack.sh
```

The script walks the layers in dependency order and stops at the first failure,
naming the layer and the likely cause. Run it before believing anything else.

To exercise a real agent request, create an agent first —
[Recipe 4](../05-recipes/simple-agent.md) — then:

```bash
./scripts/verify-stack.sh --agent <agent-name>
```

## The five API keys

The single most common misconfiguration in a separated deployment. Each hop
authenticates **independently**:

```mermaid
flowchart LR
  C["client"] -->|"LOCALAGI_API_KEYS"| AG["localagi"]
  AG -->|"LOCALAGI_LLM_API_KEY"| LAI["localai"]
  AG -->|"local_rag_api_key"| LR["localrecall"]
  LR -->|"OPENAI_API_KEY"| LAI
  C2["client"] -->|"LOCALAI_API_KEY"| LAI
```

| Variable | Direction | Must match |
|---|---|---|
| `LOCALAI_API_KEY` | inbound to LocalAI | — |
| `LOCALAGI_LLM_API_KEY` | LocalAGI → LocalAI | `LOCALAI_API_KEY` |
| `OPENAI_API_KEY` on LocalRecall | LocalRecall → LocalAI | `LOCALAI_API_KEY` |
| `LOCALAGI_API_KEYS` | inbound to LocalAGI | your client |
| `API_KEYS` on LocalRecall | inbound to LocalRecall | LocalAGI's RAG key |

Two traps in that table:

- When `LOCALAGI_LLM_API_KEY` is unset the client sends the literal string
  `sk-xxx`. That is a placeholder, not an absence — LocalAI with a key configured
  rejects it as a *wrong token*, so you will never see "no credentials supplied".
- The HTTP RAG provider is constructed with the **model server's** key as its
  default token for LocalRecall. If the two services use different keys, retrieval
  authenticates with the wrong one unless you set the per-agent
  `local_rag_api_key`.

Setting one key and assuming the rest follow produces the characteristic failure:
the external surface works, agents fail, and nothing above debug explains why.

## What this configuration still lacks

Stated plainly, because a working stack is not a production one:

| Missing | Where it is discussed |
|---|---|
| TLS anywhere | [security](../06-deployment/security.md) |
| Any authentication, by default | [security](../06-deployment/security.md) |
| Backup and restore procedure | [persistence](../06-deployment/persistence.md) |
| Metrics, tracing, request correlation | [observability](../06-deployment/observability.md) |
| More than one replica of anything | [scaling](../07-deep-dives/scaling.md) |
| Tool sandboxing and MCP trust boundaries | [security model](../07-deep-dives/security-model.md) |
| Multi-tenant isolation of collections | [production](../06-deployment/production.md) |

The last one deserves emphasis: collections have no tenancy model, and an agent's
collection is derived from its lowercased name. Two agents whose names differ only
in case share one collection. Do not put two tenants' documents in one deployment
and assume they are separated.

## Upstream references

- [LocalAI `core/cli/run.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/cli/run.go) — `LOCALAI_DISABLE_AGENTS` at 124, the `LOCALAI_AGENT_POOL_*` variables at 125-143. Validated against v4.8.2.
- [LocalAI `Dockerfile`](https://github.com/mudler/LocalAI/blob/v4.8.2/Dockerfile) — the four declared volumes.
- [LocalRecall `main.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/main.go) — base URL overwrite at 60-63, working-directory-relative defaults at 33-45, chunk defaults at 72-88. Validated against v0.6.4.
- [LocalRecall `routes.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/routes.go) — startup collection load with lazy rehydration at 121-156, and the comment recording the earlier `os.Exit` behaviour at 78-86.
- [LocalRecall `Dockerfile`](https://github.com/mudler/LocalRecall/blob/v0.6.4/Dockerfile) — `FROM scratch` final stage, which is why no in-container healthcheck is possible.
- [LocalRecall `rag/engine/postgres.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/postgres.go) — `pg_textsearch` requirement at 215-218.
- [LocalAGI `cmd/serve.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/cmd/serve.go) — hardcoded `:3000` at 126, RAG provider fork at 113-120. Validated against v2.9.0.
- [LocalAGI `pkg/llm/client.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/pkg/llm/client.go) — the `sk-xxx` placeholder.
- [LocalAGI `core/state/pool.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/state/pool.go) — HTTP RAG provider defaulting to the LLM API key at 36-49.
- Image tag availability (`localagi` highest is `v2.8.1`; `localrecall:v0.6.4-postgresql` present): quay.io tag API, observed 2026-08-17.
