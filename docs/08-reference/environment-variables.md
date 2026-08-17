# Environment variables

A curated map, not an exhaustive dump. LocalAI alone declares **148** environment bindings;
listing them all here would go stale and would bury the twenty that actually matter.

**The authoritative list is the binary itself:**

```bash
docker run --rm localai/localai:v4.8.2 --help
```

Every flag prints with its environment variable, default and group. Nothing in this handbook
supersedes that output.

## Naming conventions, and a trap

| Project | Prefix |
|---|---|
| LocalAI | `LOCALAI_*`, most also accepting an un-prefixed alias |
| LocalAGI | `LOCALAGI_*` — **plus un-prefixed LocalRecall variables** |
| LocalRecall | un-prefixed: `OPENAI_BASE_URL`, `VECTOR_ENGINE`, `EMBEDDING_MODEL`, … |

Most LocalAI variables accept two spellings: `LOCALAI_API_KEY` and `API_KEY`,
`LOCALAI_ADDRESS` and `ADDRESS`. Prefer the prefixed form — the bare names collide with
other software in a shared environment, and `API_KEY` in particular is a name half the
ecosystem uses.

**The trap:** because LocalAGI links LocalRecall as a library, it reads LocalRecall's
**un-prefixed** variables directly. `VECTOR_ENGINE`, `EMBEDDING_MODEL`, `DATABASE_URL`,
`COLLECTION_DB_PATH`, `FILE_ASSETS`, `MAX_CHUNKING_SIZE` and `CHUNK_OVERLAP` are read by
LocalAGI, with no `LOCALAGI_` prefix. If you set `LOCALAGI_EMBEDDING_MODEL` expecting it to
work, it is silently ignored.

## The twelve that decide whether the stack works

If you get these right, everything else is tuning.

| Variable | Service | Default | Why it matters |
|---|---|---|---|
| `LOCALAGI_LLM_API_URL` | LocalAGI | none, **required** | no inference without it; `serve` exits |
| `LOCALAGI_MODEL` | LocalAGI | none, **required** | must match `/v1/models` exactly |
| `LOCALAGI_STATE_DIR` | LocalAGI | `./pool` | **agent definitions live here** |
| `LOCALAGI_LOCALRAG_URL` | LocalAGI | empty | flips retrieval to HTTP; **required on v2.8.1** |
| `OPENAI_BASE_URL` | LocalRecall | **none — and this breaks it** | see below |
| `EMBEDDING_MODEL` | LocalRecall | **none** (LocalAGI supplies one) | empty model name on the wire |
| `VECTOR_ENGINE` | LocalRecall / LocalAGI | `chromem` | `postgres` for hybrid search |
| `DATABASE_URL` | LocalRecall | none | required when engine is `postgres` |
| `COLLECTION_DB_PATH` | LocalRecall | `./collections` | **relative to the working directory** |
| `FILE_ASSETS` | LocalRecall | `./assets` | same hazard |
| `LOCALAI_DISABLE_AGENTS` | LocalAI | `false` | **set `true`** when running a standalone LocalAGI |
| `LOCALAI_API_KEY` | LocalAI | none | and then four other keys must agree |

### `OPENAI_BASE_URL` has no working default

The most consequential unvalidated variable in the stack.

`main.go` assigns `config.BaseURL = openAIBaseURL` **unconditionally**, after
`openai.DefaultConfig` has already set the real OpenAI URL. An empty value therefore does not
fall back — it overwrites the default with nothing, and every embedding request goes to a
bare relative `/embeddings`.

The process starts. `GET /api/collections` returns 200. The first ingestion fails.

### The path defaults are relative to the working directory

`COLLECTION_DB_PATH` and `FILE_ASSETS` default to `./collections` and `./assets`. In
LocalRecall's `FROM scratch` image that is the **ephemeral container layer** — collections
silently vanish on restart.

Note the difference when the same library runs inside LocalAGI: there they default to
`<stateDir>/collections` and `<stateDir>/assets`, which is safe. Same code, different
robustness depending on who started it.

**Always set both explicitly, in both modes.**

## LocalAI

### Core

| Variable | Default | Note |
|---|---|---|
| `LOCALAI_ADDRESS` | `:8080` | listen address |
| `LOCALAI_MODELS_PATH` | `/models` | weights and generated YAML |
| `LOCALAI_BACKENDS_PATH` | `/backends` | backend binaries |
| `LOCALAI_CONFIG_DIR` | `/configuration` | runtime settings |
| `LOCALAI_DATA_PATH` | `<basepath>/data` | **collection DB, agent state, tasks, jobs** |
| `LOCALAI_CONTEXT_SIZE` | per model | global default context |
| `LOCALAI_F16` | false | half precision |
| `DEBUG` | false | verbose logging |

`LOCALAI_DATA_PATH` is the one to notice in Pattern A: it holds agent state. The image
declares `/data` as a volume, and mounting only `/models` — as most quickstarts show —
silently discards every agent.

### Security

| Variable | Default | Note |
|---|---|---|
| `LOCALAI_API_KEY` | none | bearer token on inbound requests |
| `LOCALAI_ALLOW_INSECURE_PUBLIC_BIND` | false | **guard rail** — do not set it to bind publicly without auth |
| `LOCALAI_CORS` | false | |
| `LOCALAI_CORS_ALLOW_ORIGINS` | — | |
| `LOCALAI_DISABLE_WEBUI` | false | removes the UI surface |
| `LOCALAI_DISABLE_GALLERY_ENDPOINT` | false | prevents model installation over the API |
| `LOCALAI_DISABLE_RUNTIME_SETTINGS` | false | prevents settings changes over the API |
| `LOCALAI_DISABLE_MCP` | false | disables the in-process MCP server |
| `LOCALAI_AUTH`, `LOCALAI_AUTH_DATABASE_URL`, `LOCALAI_AUTH_HMAC_SECRET` | — | a fuller auth mode exists; **not exercised in our validation** |
| `LOCALAI_GITHUB_CLIENT_ID` / `_SECRET` | — | OAuth for the UI |

The four `DISABLE_*` variables are the cheapest hardening available: if you only need
inference, turning off the web UI, the gallery endpoint, runtime settings and MCP removes most
of the write surface. See [security](../06-deployment/security.md).

Note that `LOCALAI_AUTH*` suggests a more capable authentication mode than a shared bearer
key. We did not exercise it, and it is not documented in the material we reviewed — treat it
as unverified.

### Agent pool (Pattern A)

Present because LocalAI embeds the agent platform. All ignored when
`LOCALAI_DISABLE_AGENTS=true`.

| Variable | Default |
|---|---|
| `LOCALAI_DISABLE_AGENTS` | `false` — the pool is **on** by default |
| `LOCALAI_AGENT_POOL_API_URL` | self-referencing LocalAI |
| `LOCALAI_AGENT_POOL_API_KEY` | first LocalAI API key |
| `LOCALAI_AGENT_POOL_DEFAULT_MODEL` | — |
| `LOCALAI_AGENT_POOL_STATE_DIR` | — |
| `LOCALAI_AGENT_POOL_TIMEOUT` | `5m` |
| `LOCALAI_AGENT_POOL_VECTOR_ENGINE` | `chromem` |
| `LOCALAI_AGENT_POOL_EMBEDDING_MODEL` | `granite-embedding-107m-multilingual` |
| `LOCALAI_AGENT_POOL_MAX_CHUNKING_SIZE` | `400` |
| `LOCALAI_AGENT_POOL_CHUNK_OVERLAP` | `0` |
| `LOCALAI_AGENT_POOL_ENABLE_SKILLS` | `false` |
| `LOCALAI_AGENT_POOL_ENABLE_LOGS` | `false` |
| `LOCALAI_AGENT_POOL_DATABASE_URL` | — |
| `LOCALAI_AGENT_HUB_URL` | `https://agenthub.localai.io` |

Note that the embedded pool has its **own** prefixed copies of the LocalRecall settings,
where standalone LocalAGI reads the un-prefixed ones. Same knobs, three different names
depending on deployment shape — this is the clearest single illustration of
[logical versus physical](../00-overview/logical-vs-physical.md).

`LOCALAI_AGENT_HUB_URL` points at a remote service by default; worth knowing if egress is
restricted.

### Models and backends

| Variable | Note |
|---|---|
| `LOCALAI_GALLERIES` | model gallery sources |
| `LOCALAI_BACKEND_GALLERIES` | backend gallery sources |
| `LOCALAI_AUTOLOAD_GALLERIES` / `_BACKEND_GALLERIES` | fetch indexes at startup |
| `LOCALAI_AUTO_UPGRADE_BACKENDS` | upgrade backends automatically |
| `HF_TOKEN` | **Hugging Face token** — needed for gated repositories |
| `LOCALAI_EXTERNAL_BACKENDS`, `LOCALAI_EXTERNAL_GRPC_BACKENDS` | register your own backends |
| `LOCALAI_LOAD_TO_MEMORY` | preload models |
| `LOCALAI_FORCE_EVICTION_WHEN_BUSY` | evict a model even while in use |
| `LOCALAI_GPU_RECLAIMER`, `_THRESHOLD` | release GPU memory |

`HF_TOKEN` is the fix for a specific documented failure: the gallery entry
`LocalAI-functioncall-llama3.2-3b-v0.5` fails because its Hugging Face repository returns
**HTTP 401** to anonymous requests.

`LOCALAI_GALLERIES` matters for a different reproduced failure: the default galleries are
YAML on `raw.githubusercontent.com`, and when that host rate-limits you (**HTTP 429**), no
model resolves — while `/readyz` still returns 200 with zero models. Pointing this at a
mirror is the durable fix.

### Observability

| Variable | Default |
|---|---|
| `LOCALAI_DISABLE_METRICS_ENDPOINT` | `false` — `/metrics` is on |
| `LOCALAI_ENABLE_TRACING` | `false` |
| `LOCALAI_AGENT_JOB_RETENTION_DAYS` | `30` |

`/metrics` exposes 44 families of which exactly one is application-specific. LocalAGI and
LocalRecall expose none. See [observability](../06-deployment/observability.md).

## LocalAGI

Every variable, from `cmd/env.go` — this list *is* exhaustive.

| Variable | Default | Note |
|---|---|---|
| `LOCALAGI_MODEL` | none | **required** |
| `LOCALAGI_LLM_API_URL` | none | **required**; no `/v1` needed against LocalAI |
| `LOCALAGI_LLM_API_KEY` | **`sk-xxx`** | a literal placeholder, not an absence |
| `LOCALAGI_MULTIMODAL_MODEL` | — | |
| `LOCALAGI_TRANSCRIPTION_MODEL` | — | |
| `LOCALAGI_TRANSCRIPTION_LANGUAGE` | — | |
| `LOCALAGI_TTS_MODEL` | — | |
| `LOCALAGI_TIMEOUT` | `5m` | **per model call**; falls back to **150 s** if unparseable |
| `LOCALAGI_STATE_DIR` | `./pool` | agent definitions |
| `LOCALAGI_LOCALRAG_URL` | empty | HTTP retrieval; **required on v2.8.1** |
| `LOCALAGI_CUSTOM_ACTIONS_DIR` | — | |
| `LOCALAGI_SSHBOX_URL` | — | for the shell action's sandbox |
| `LOCALAGI_ENABLE_CONVERSATIONS_LOGGING` | `false` | audit log, **not** state |
| `LOCALAGI_CONVERSATION_DURATION` | — | in-memory TTL; **1 h** if unset or unparseable |
| `LOCALAGI_API_KEYS` | none | comma-separated; auth is **global** |
| **`VECTOR_ENGINE`** | `chromem` | un-prefixed |
| **`EMBEDDING_MODEL`** | `granite-embedding-107m-multilingual` | un-prefixed; LocalAGI *does* default it |
| **`DATABASE_URL`** | — | un-prefixed |
| **`COLLECTION_DB_PATH`** | `<stateDir>/collections` | un-prefixed |
| **`FILE_ASSETS`** | `<stateDir>/assets` | un-prefixed |
| **`MAX_CHUNKING_SIZE`** | `400` | un-prefixed |
| **`CHUNK_OVERLAP`** | `0` | un-prefixed |

Two silent fallbacks worth internalising:

**`LOCALAGI_LLM_API_KEY` unset sends the literal `sk-xxx`.** With a key configured on
LocalAI you will see a *rejected token*, never "no credentials supplied" — so the log looks
like a wrong key rather than a missing one.

**A mistyped `LOCALAGI_TIMEOUT` becomes 150 s**, shorter than the documented `5m` default. A
typo silently halves your budget rather than erroring.

## LocalRecall

Also exhaustive, from `main.go`.

| Variable | Default | Note |
|---|---|---|
| `OPENAI_BASE_URL` | **none** | see above — effectively mandatory |
| `OPENAI_API_KEY` | empty | |
| `EMBEDDING_MODEL` | **none** | no default at all |
| `VECTOR_ENGINE` | `chromem` | `chromem`, `postgres`, `localai` |
| `DATABASE_URL` | — | required for `postgres` |
| `COLLECTION_DB_PATH` | `collections` | **working-directory-relative** |
| `FILE_ASSETS` | `assets` | **working-directory-relative** |
| `LISTENING_ADDRESS` | `:8080` | |
| `MAX_CHUNKING_SIZE` | `400` | **characters**, not tokens |
| `CHUNK_OVERLAP` | `0` | characters |
| `API_KEYS` | none | comma-separated; constant-time compared |
| `GIT_PRIVATE_KEY` | — | for git-backed sources |

### Hybrid search — `postgres` engine only

| Variable | Default |
|---|---|
| `HYBRID_SEARCH_VECTOR_WEIGHT` | `0.5` |
| `HYBRID_SEARCH_BM25_WEIGHT` | `0.5` |
| `BM25_TEXT_CONFIG` | `english` |

Raise the BM25 weight when queries contain exact identifiers — error codes, function names,
SKUs — which embeddings match poorly. `BM25_TEXT_CONFIG` is a PostgreSQL text-search
configuration name, so `german`, `french` and so on are valid.

These are read only by the PostgreSQL engine, and BM25 requires the `pg_textsearch`
extension.

## Set these, always

Regardless of deployment shape, the defaults that will hurt you:

| Set | Because the default |
|---|---|
| `OPENAI_BASE_URL` | breaks every embedding call, silently |
| `EMBEDDING_MODEL` (standalone LocalRecall) | is empty |
| `COLLECTION_DB_PATH`, `FILE_ASSETS` | resolve into an ephemeral container layer |
| `CHUNK_OVERLAP` to ~20% of chunk size | is `0`, cutting sentences at boundaries |
| `LOCALAI_DISABLE_AGENTS=true` when running standalone LocalAGI | gives you two agent pools |
| `LOCALAGI_LOCALRAG_URL` | leaves v2.8.1 with no knowledge at all |
| All five API keys, or none | leaves internal hops unauthenticated while you believe otherwise |

## Verifying what a container actually got

```bash
docker inspect localagi --format '{{range .Config.Env}}{{println .}}{{end}}'
```

Use `docker inspect`, not `docker exec printenv` — **LocalRecall's image has no shell**, so
`exec` fails there.

```bash
docker exec localagi printenv LOCALAGI_LOCALRAG_URL
```

Works for LocalAI and LocalAGI, which are Ubuntu-based.

## Related

- [Configuration map](configuration-map.md) — where each setting lives: env, model YAML, agent JSON
- [Ports](ports.md)
- [Storage map](storage-map.md)

## Upstream references

- [LocalAI `core/cli/run.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/cli/run.go) — all 148 `env:` bindings with defaults and help text; `LOCALAI_DISABLE_AGENTS` at 124; the `LOCALAI_AGENT_POOL_*` group at 125-143; `LOCALAI_DATA_PATH` at 46. Validated against v4.8.2.
- [LocalAGI `cmd/env.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/cmd/env.go) — the complete LocalAGI variable set, the `granite-embedding-107m-multilingual` default at 88-90, and the un-prefixed LocalRecall variables at 59-63. Validated against v2.9.0.
- [LocalAGI `pkg/llm/client.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/pkg/llm/client.go) — the `sk-xxx` placeholder and the 150 s timeout fallback.
- [LocalAGI `cmd/serve.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/cmd/serve.go) — required-variable validation at 31-36; state-dir-relative path defaults at 48-53.
- [LocalAGI `webui/options.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/options.go) — the 1 hour conversation-duration fallback at 42-50.
- [LocalRecall `main.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/main.go) — the complete variable set at 15-30; defaults at 33-49; chunk parsing at 72-88; the unconditional base-URL overwrite at 60-63. Validated against v0.6.4.
- [LocalRecall `rag/engine/postgres.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/postgres.go) — hybrid search weights at 63-94; `pg_textsearch` requirement at 215-218.
- The 148 count, metric-family inventory, and the HTTP 429 / HTTP 401 gallery failures: observed 2026-08-17, see [version matrix](../00-overview/version-matrix.md).
