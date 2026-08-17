# Reference environment

A separated deployment of all three projects plus a vector database — LocalAI,
LocalRecall, LocalAGI, PostgreSQL — where every integration edge is a real
network call you can observe, break and diagnose.

This is **deployment Pattern B**. It is deliberately not the smallest way to run
the stack. For that, run one LocalAI container and let it be all three layers at
once; see [docker.md](../docs/06-deployment/docker.md). Use this environment when
you want to *understand* the boundaries, or when you actually need the layers
separated.

## Why each service is here

Every service has an architectural justification. Nothing is included because it
is conventional.

| Service | Justification | Removable? |
|---|---|---|
| `localai` | Executes the LLM and the embedding model. Nothing else works without it. | No |
| `localrecall` | The knowledge layer **as a service**, so retrieval can be probed on its own. | Yes — unset `LOCALAGI_LOCALRAG_URL` and LocalAGI embeds it instead |
| `localagi` | The agent runtime: agent loop, tools, agent state. | Yes, if you only want inference and retrieval |
| `postgres` | The vector store. Justified **only** by hybrid search — BM25 scoring exists exclusively in LocalRecall's postgres engine and needs the `pg_textsearch` extension. | Yes — set `VECTOR_ENGINE=chromem` |

There is no reverse proxy, no Redis, no metrics stack. Those are real production
concerns and they are discussed in
[production.md](../docs/06-deployment/production.md), but adding them here would
obscure what this environment exists to show.

## Prerequisites

- Docker with Compose v2
- About **4 GB of free disk** — 1.4 GiB of models, a ~0.3 GB LocalAI image, plus
  a backend downloaded on first model install
- No GPU required. See [gpu.md](../docs/06-deployment/gpu.md) for acceleration.

## Start

```bash
cp .env.example .env
docker compose up -d
```

The first start downloads two models and a backend. Watch progress:

```bash
docker compose logs -f localai
```

`localai`'s healthcheck allows 30 minutes for this, so `docker compose ps` will
show it as `starting` for a while. That is expected, not a hang.

Then verify, from the repository root:

```bash
./scripts/verify-stack.sh
```

The script checks each layer in dependency order and stops at the first failure,
naming the layer and the likely cause. It is the fastest way to find out which
component is actually broken.

## What you get

| Service | URL | Notes |
|---|---|---|
| LocalAI | http://localhost:8080 | OpenAI-compatible API, web UI at `/` |
| LocalAGI | http://localhost:8081 | agent API and UI — listens on **3000** inside the container |
| LocalRecall | http://localhost:8082 | collections API; **no web UI worth using, no health endpoint** |
| PostgreSQL | not published | uncomment the port to inspect with `psql` |

## Verification commands, by layer

Work down this list. Each one assumes the previous passed.

**Inference runtime is up:**

```bash
curl -s http://localhost:8080/readyz
```

`/readyz` means the HTTP listener is accepting connections. It does **not** mean a
model is loaded — the first inference request still pays the load cost.

**Models resolved:**

```bash
curl -s http://localhost:8080/v1/models | jq -r '.data[].id'
```

Both `qwen3-1.7b` and `granite-embedding-107m-multilingual` must appear, spelled
exactly as configured.

**Inference works:**

```bash
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-1.7b","messages":[{"role":"user","content":"Say hello."}]}' \
  | jq -r '.choices[0].message.content'
```

**Embeddings work** — the dimension is the number every collection is bound to:

```bash
curl -s http://localhost:8080/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"granite-embedding-107m-multilingual","input":"test"}' \
  | jq '.data[0].embedding | length'
```

**Knowledge layer reachable:**

```bash
curl -s http://localhost:8082/api/collections | jq
```

This answers from disk. A `200` proves the process is up and proves **nothing**
about whether embeddings work.

**Knowledge layer end to end** — creating a collection constructs the vector
engine, so this is the first command that actually exercises the embeddings edge:

```bash
curl -s -X POST http://localhost:8082/api/collections \
  -H 'Content-Type: application/json' -d '{"name":"handbook"}' | jq
```

A `502` with `Vector backend unavailable` means the embedding or database call
failed — not that the API is broken.

```bash
echo 'LocalRecall stores and retrieves knowledge used to augment model context.' > /tmp/note.txt
curl -s -X POST http://localhost:8082/api/collections/handbook/upload \
  -F file=@/tmp/note.txt | jq
```

```bash
curl -s -X POST http://localhost:8082/api/collections/handbook/search \
  -H 'Content-Type: application/json' \
  -d '{"query":"what does LocalRecall do","max_results":3}' | jq
```

**Agent runtime reachable:**

```bash
curl -s http://localhost:8081/api/agents | jq
```

An empty result is correct on a fresh start. Create an agent with
[Recipe 4](../docs/05-recipes/simple-agent.md).

## Persistent state

Six volumes, and they are not equally important.

| Volume | Holds | If you delete it |
|---|---|---|
| `localai-models` | model weights | ~1.4 GiB re-downloaded |
| `localai-backends` | backend binaries | re-downloaded on next model load |
| `localai-configuration` | runtime settings | settings reset |
| `localagi-pool` | **agent definitions and agent state** | **every agent is gone** |
| `localrecall-data` | original uploaded documents | raw-file endpoints 404; vectors survive |
| `postgres-data` | **chunks and vectors** | **all knowledge is gone** |

The two that matter are `localagi-pool` and `postgres-data`. Note that a
collection's data is split across `localrecall-data` (originals) and
`postgres-data` (chunks and vectors) — **back up both or neither.** Restoring only
PostgreSQL gives you a searchable collection whose original documents have
vanished.

## Common changes

**No hybrid search needed — drop PostgreSQL.**

```bash
# in .env
VECTOR_ENGINE=chromem
```

Then remove the `postgres` service and LocalRecall's `depends_on` entry for it.
Vectors move into a file under `localrecall-data`.

**Embed the knowledge layer in LocalAGI instead of running it separately.**
Comment out `LOCALAGI_LOCALRAG_URL` in `docker-compose.yml`. LocalAGI then links
LocalRecall as a library and its own `/api/collections` routes operate on a store
it opens itself. The `localrecall` service becomes unused — remove it.

Note that collections do **not** migrate automatically when you do this. See
[deployment-patterns.md](../docs/04-integration/deployment-patterns.md#migration-paths).

**Use a bigger model.**

```bash
# in .env
LLM_MODEL=qwen3-4b
```

Same configuration, 2.33 GiB instead of 1.19 GiB.

**Point at an inference server you already run.** Remove the `localai` service,
then set `LOCALAGI_LLM_API_URL` and LocalRecall's `OPENAI_BASE_URL` to it. If it
is not LocalAI, **append `/v1` to `LOCALAGI_LLM_API_URL`** — cogito does not insert
a version segment. LocalRecall's client does, so leave that one without `/v1`. The
asymmetry is real and is explained in
[api-flow.md](../docs/04-integration/api-flow.md#the-v1-trap).

**Turn on authentication.** Uncomment the key variables in
`docker-compose.yml` and set all five in `.env`. Every hop authenticates
independently; setting one and assuming the rest follow produces 401s on internal
hops while the external surface stays healthy.

## Troubleshooting

**`localai` stays `starting` for a long time.** Normal on first run. Follow
`docker compose logs -f localai` and watch the model download.

**`localrecall` has no health status.** By design — its image is built
`FROM scratch` and contains no shell, so a Docker `CMD` healthcheck cannot run
inside it. Probe it from outside.

**Retrieval returns nothing and no errors appear.** The three guards that skip
knowledge lookup log at **debug level only**. Set `DEBUG=true` in `.env`, restart,
and look again.

**An agent request times out at 60 s exactly.** Something between you and LocalAGI
has a 60-second read timeout. An agent request is a loop and can legitimately
exceed it. Raise the proxy timeout, not `LOCALAGI_TIMEOUT` — that one is per model
call.

Layer-by-layer diagnosis:
[LocalAI](../docs/01-localai/troubleshooting.md) ·
[LocalAGI](../docs/02-localagi/troubleshooting.md) ·
[LocalRecall](../docs/03-localrecall/troubleshooting.md)

## Stop and clean up

Stop, keeping all data:

```bash
docker compose down
```

Remove everything including models — a full re-download next time:

```bash
docker compose down -v
```

Remove agents and knowledge but keep the models:

```bash
docker compose down
docker volume rm localai-stack_localagi-pool localai-stack_postgres-data localai-stack_localrecall-data
```

## Versions

Pinned in `.env.example`. Registry presence verified 2026-08-17:

| Service | Tag | Note |
|---|---|---|
| LocalAI | `v4.8.2` | |
| LocalRecall | `v0.6.4` | plus `v0.6.4-postgresql` for the database |
| LocalAGI | `v2.8.1` | **not `v2.9.0`** — that image does not exist |

The LocalAGI pin is the one to remember. `v2.9.0` is a real source tag with no
published image; the build has been failing since 2026-04-15. Full record in
[the version matrix](../docs/00-overview/version-matrix.md).
