# Installing standalone LocalAGI

LocalAGI needs an OpenAI-compatible model server before it will start at all.
`LOCALAGI_MODEL` and `LOCALAGI_LLM_API_URL` are checked first thing in
`runServe`, and an empty value prints help and exits (`cmd/serve.go:31-36`).
Nothing else is mandatory.

## From source

The Go build depends on the React bundle, which is built inside a container:

```bash
git clone https://github.com/mudler/LocalAGI
cd LocalAGI
make build          # builds webui/react-ui/dist in an oven/bun:1 container, then go build
```

`Makefile:17-18` runs the Bun build; `Makefile:20-22` makes `webui/react-ui/dist`
a prerequisite of `go build -o localagi ./`. Building with plain `go build`
without that step will not embed a UI.

Minimum run:

```bash
export LOCALAGI_MODEL=gemma-3-4b-it-qat
export LOCALAGI_LLM_API_URL=http://localhost:8080
./localagi serve
```

The server listens on **`:3000`** (`cmd/env.go:55`). State lands in `$CWD/pool`
(`cmd/serve.go:38-46`) unless `LOCALAGI_STATE_DIR` says otherwise. Run it from a
directory you intend to keep — see [state](state.md).

## The environment surface

Read once at startup into the `Env` struct (`cmd/env.go:10-98`). There are **no
CLI flags** for any of these.

| Variable | Default | Effect |
|---|---|---|
| `LOCALAGI_MODEL` | *required* | Model name sent on every reasoning request |
| `LOCALAGI_LLM_API_URL` | *required* | Base URL of the model server — read the `/v1` note below |
| `LOCALAGI_LLM_API_KEY` | `""` (becomes `sk-xxx`) | Bearer token for the model server |
| `LOCALAGI_BASE_URL` | `:3000` | Listen address |
| `LOCALAGI_STATE_DIR` | `$CWD/pool` | Everything persisted, see [state](state.md) |
| `LOCALAGI_API_KEYS` | `""` | Comma-separated. **Empty means no authentication at all** |
| `LOCALAGI_TIMEOUT` | `5m` | HTTP client timeout for model calls |
| `LOCALAGI_MULTIMODAL_MODEL` | `""` | If set, images are described by this model before reasoning |
| `LOCALAGI_TRANSCRIPTION_MODEL` / `_LANGUAGE` | `""` | Audio input |
| `LOCALAGI_TTS_MODEL` | `""` | Audio output |
| `LOCALAGI_LOCALRAG_URL` | `""` | **Empty selects the embedded knowledge base.** Set it to use a remote LocalRecall server |
| `LOCALAGI_CUSTOM_ACTIONS_DIR` | `""` | Directory of yaegi-interpreted Go actions and prompts |
| `LOCALAGI_SSHBOX_URL` | `""` | `user:pass@host:port` for the `run_command` action |
| `LOCALAGI_ENABLE_CONVERSATIONS_LOGGING` | `false` | Write conversation transcripts to disk |
| `LOCALAGI_CONVERSATION_DURATION` | `""` | TTL of the `/v1/responses` conversation store; parse failure falls back to 1h |
| `COLLECTION_DB_PATH` | `<stateDir>/collections` | Vector store location |
| `FILE_ASSETS` | `<stateDir>/assets` | Uploaded knowledge-base source files |
| `VECTOR_ENGINE` | `chromem` | `chromem`, `localai` or `postgres` |
| `EMBEDDING_MODEL` | `granite-embedding-107m-multilingual` | Requested from the model server |
| `DATABASE_URL` | `""` | Required when `VECTOR_ENGINE=postgres` |
| `MAX_CHUNKING_SIZE` | `400` | Bytes per chunk |
| `CHUNK_OVERLAP` | `0` | |

`README.md:747` documents `LOCALAGI_IMAGE_MODEL`. **No Go source reads that
variable.** Treat the README line as stale; the image action takes its model
from its own action configuration instead.

### Pointing at LocalAI, and the missing `/v1`

`LOCALAGI_LLM_API_URL` is passed through unchanged to cogito's client, which
concatenates the path with no version segment:

```go
// cogito/clients/localai_client.go:305
url := llm.baseURL + "/chat/completions"
```

With the documented value `http://localai:8080` the request goes to
`http://localai:8080/chat/completions` — no `/v1`. That works because LocalAI
registers both the prefixed and un-prefixed routes
(`LocalAI/core/http/routes/openai.go:97-98`).

**Against any other OpenAI-compatible server, include the version segment
yourself**: `https://api.openai.com/v1`, not `https://api.openai.com`. The same
applies to embeddings, which LocalRecall issues against the same base URL.
Details in [troubleshooting](troubleshooting.md).

## The shipped compose stack

`docker-compose.yaml` defines five services:

| Service | Image / build | Ports | Role |
|---|---|---|---|
| `localai` | `localai/localai:master` | `8081:8080` | Model server; preloads the chat, multimodal and embedding models; healthcheck on `/readyz` |
| `postgres` | `quay.io/mudler/localrecall:${LOCALRECALL_VERSION:-v0.5.2}-postgresql` | — | **A PostgreSQL + pgvector image, not a LocalRecall server** |
| `sshbox` | `Dockerfile.sshbox` | — | SSH target for the `run_command` action |
| `dind` | `docker:dind`, privileged, TLS off | — | Docker daemon for agents that shell out |
| `localagi` | `Dockerfile.webui` | **`8080:3000`** | LocalAGI itself |

Start it:

```bash
docker compose up -d          # default (CPU)
docker compose -f docker-compose.yaml -f docker-compose.nvidia.yaml up -d
docker compose -f docker-compose.yaml -f docker-compose.intel.yaml up -d
docker compose -f docker-compose.yaml -f docker-compose.amd.yaml up -d
```

The three GPU files are thin `extends:` overlays. They change only the `localai`
image, the device reservations, and add `LOCALAI_SINGLE_ACTIVE_BACKEND=true`.
Nothing about LocalAGI changes between them.

The UI is then on `http://localhost:8080` — the host side of `8080:3000`.

### The `postgres` service is not LocalRecall

This one costs people an afternoon. The image name contains `localrecall`, so it
reads as "the LocalRecall service". It is not:

- The image is `quay.io/mudler/localrecall:<version>-postgresql`, built from
  LocalRecall's `Dockerfile.pgsql` — Ubuntu with PostgreSQL 18, `pgvector`,
  `pg_textsearch` and `pgvectorscale`. Its entrypoint is PostgreSQL.
- The database, user and password are all `localrecall`
  (`docker-compose.yaml:30-33`), which reinforces the misreading.
- **`LOCALAGI_LOCALRAG_URL` is set in none of the compose files.** The
  knowledge-base code therefore runs *inside* the `localagi` container as a
  linked library, and this container is only its vector store.

So the shipped "stack" is two services plus a database, not three services. A
genuine three-service deployment — LocalRecall's own HTTP server as a separate
process — is possible but is not shipped as a compose file: run LocalRecall's
image and set `LOCALAGI_LOCALRAG_URL` to it. That switches both the agent RAG
path and the web UI's collections API to the HTTP client
(`cmd/serve.go:113-120`, `webui/routes.go:218-226`).

### How the compose file wires LocalAGI to LocalAI

```yaml
LOCALAGI_MODEL=${MODEL_NAME:-gemma-3-4b-it-qat}
LOCALAGI_MULTIMODAL_MODEL=${MULTIMODAL_MODEL:-moondream2-20250414}
LOCALAGI_LLM_API_URL=http://localai:8080
LOCALAGI_STATE_DIR=/pool
VECTOR_ENGINE=postgres
DATABASE_URL=postgresql://localrecall:localrecall@postgres:5432/localrecall?sslmode=disable
EMBEDDING_MODEL=granite-embedding-107m-multilingual
LOCALAGI_SSHBOX_URL=root:root@sshbox:22
DOCKER_HOST=tcp://dind:2375
```

Service-name DNS, container port 8080 — not the published 8081.

**Compose inconsistency to know about.** The `localagi` service defaults
`MULTIMODAL_MODEL` to `moondream2-20250414` (`docker-compose.yaml:88`) while the
`localai` service preloads `${MULTIMODAL_MODEL:-gemma-3-4b-it-qat}`
(`docker-compose.yaml:11`). Unless you set `MULTIMODAL_MODEL` yourself, LocalAGI
asks for a model LocalAI was never told to load.

Volumes: `postgres_data`, `models`, `backends`, `images`, `localagi_pool`. The
last is the one holding your agents. A bind mount for host-supplied skills at
`./skills:/pool/skills` is present but commented out.

`extra_hosts: host.docker.internal:host-gateway` is set so agents can reach
services on the host.

## Headless: `agent run`

No HTTP server, one agent:

```bash
local-agi agent run my-agent                       # from <stateDir>/pool.json
local-agi agent run --config agent.json            # from a file; name derived from the filename
local-agi agent run my-agent --prompt "summarise the backlog"
```

With `--prompt` the agent starts, runs one `Ask`, prints the response to stdout
and exits (`cmd/agent_run.go:63-162`). Without it, the agent runs until SIGINT
with `periodic_runs` defaulting to 10m and the scheduler polling every 30s
(`cmd/agent_run.go:291-296`).

Two caveats: `validateConfig` is a no-op that always returns nil
(`cmd/agent_run.go:244-248`), and this path wires **only** the HTTP RAG provider
— there is no embedded knowledge-base fallback in `agent run`
(`cmd/agent_run.go:130-132, 326-328`).

## Before exposing it

The API-key middleware is installed only when `LOCALAGI_API_KEYS` is non-empty
(`webui/routes.go:30-36`). When installed it covers every route, reads keys from
`Authorization: Bearer`, `x-api-key`, `xi-api-key` or a `token` cookie, and
compares them in constant time (`webui/routes.go:253-295`).

With no keys set, an unauthenticated caller can create an agent whose
configuration contains interpreted Go with the interpreter's restrictions
disabled (`core/action/custom.go:62-67`), a shell script that runs before MCP
servers start (`core/agent/mcp.go:184`), and a webhook action pointed anywhere.
Treat an exposed LocalAGI with no API keys as remote code execution.

## Upstream references

- [`cmd/serve.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/cmd/serve.go) — required variables, defaults, RAG selection. Validated against v2.9.0, 2026-08-17.
- [`cmd/env.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/cmd/env.go) — the complete environment surface and its defaults. Validated against v2.9.0, 2026-08-17.
- [`cmd/agent_run.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/cmd/agent_run.go) — headless mode, no-op config validation, HTTP-only RAG. Validated against v2.9.0, 2026-08-17.
- [`docker-compose.yaml`](https://github.com/mudler/LocalAGI/blob/v2.9.0/docker-compose.yaml) — services, ports, the pgvector `postgres` service. Validated against v2.9.0, 2026-08-17.
- [`docker-compose.nvidia.yaml`](https://github.com/mudler/LocalAGI/blob/v2.9.0/docker-compose.nvidia.yaml), [`.intel.yaml`](https://github.com/mudler/LocalAGI/blob/v2.9.0/docker-compose.intel.yaml), [`.amd.yaml`](https://github.com/mudler/LocalAGI/blob/v2.9.0/docker-compose.amd.yaml) — GPU overlays. Validated against v2.9.0, 2026-08-17.
- [`Makefile`](https://github.com/mudler/LocalAGI/blob/v2.9.0/Makefile) — the Bun UI build as a build prerequisite. Validated against v2.9.0, 2026-08-17.
- [`webui/routes.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/routes.go) — conditional API-key middleware. Validated against v2.9.0, 2026-08-17.
- [LocalRecall `Dockerfile.pgsql`](https://github.com/mudler/LocalRecall/blob/v0.6.4/Dockerfile.pgsql) — what the `-postgresql` image actually contains. Validated against v0.6.4, 2026-08-17.
- [LocalAI `core/http/routes/openai.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/openai.go) — prefixed and un-prefixed route aliases. Validated against v4.8.2, 2026-08-17.
