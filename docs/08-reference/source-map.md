# Source map

Where to look in the upstream repositories when you need to answer a question this handbook does
not. Organised by question rather than by directory, because that is how the need arises.

Paths are relative to each repository root, at the pinned tags: LocalAI `v4.8.2`, LocalAGI
`v2.9.0`, LocalRecall `v0.6.4`.

## Getting the source

```bash
git clone --depth 1 --branch v4.8.2 https://github.com/mudler/LocalAI.git
git clone --depth 1 --branch v2.9.0 https://github.com/mudler/LocalAGI.git
git clone --depth 1 --branch v0.6.4 https://github.com/mudler/LocalRecall.git
```

Also clone **v2.8.1** of LocalAGI if you are running the published image, because it differs
architecturally — no LocalRecall dependency, no `/api/collections` routes:

```bash
git clone --depth 1 --branch v2.8.1 https://github.com/mudler/LocalAGI.git localagi-281
```

There is a fourth repository that neither README emphasises and that owns the agent loop:

```bash
git clone https://github.com/mudler/cogito.git
```

## By question

### "What HTTP routes exist?"

| Project | File |
|---|---|
| LocalAI | `core/http/app.go`, `core/http/routes/*.go` |
| LocalAI, agents | `core/http/routes/agents.go` |
| LocalAGI | `webui/routes.go` |
| LocalAGI, collections | `webui/collections_handlers.go` |
| LocalRecall | `routes.go` |

Do **not** trust `/swagger/doc.json` as the authoritative surface: it documents 111 paths and
omits live routes including `/api/agents`.

### "Where does configuration come from?"

| Project | File |
|---|---|
| LocalAI | `core/cli/run.go` — all 148 `env:` bindings, defaults, help text |
| LocalAI, model YAML schema | `core/config/backend_config.go` |
| LocalAGI | `cmd/env.go` |
| LocalAGI, agent schema | `core/state/config.go` |
| LocalRecall | `main.go:15-49` |

`core/cli/run.go` is the single most useful file in the ecosystem for operators: every flag,
every environment variable, every default, in one place.

### "What actually happens during inference?"

| Question | File |
|---|---|
| Chat handler, MCP loop | `core/http/endpoints/openai/chat.go` |
| Embeddings handler | `core/http/endpoints/openai/embeddings.go` |
| Predict / tokenize path | `core/backend/llm.go` |
| **Backend process spawn, port allocation, load, eviction** | `pkg/model/initializers.go` |
| Middleware chain | `core/http/middleware/` |

`pkg/model/initializers.go` is where the two-process architecture lives: free-port allocation on
`127.0.0.1`, `fork/exec` of the backend's `run.sh`, gRPC health polling, `LoadModel`, and
eviction.

### "What does the agent loop do?"

| Question | File |
|---|---|
| Agent lifecycle, job consumption | LocalAGI `core/agent/agent.go` |
| Agent options → cogito options | LocalAGI `core/agent/agent.go:1340-1365` |
| Knowledge lookup and write-back | LocalAGI `core/agent/knowledgebase.go` |
| MCP tool wrapping | LocalAGI `core/agent/mcp.go` |
| Pool, providers, action assembly | LocalAGI `core/state/pool.go` |
| **The loop itself** | **`mudler/cogito`** |

The last row is the important one. Reason/act/observe, tool selection, forced reasoning, loop
detection, retries and compaction are **not in LocalAGI**. If you are asking why an agent behaved
a certain way, cogito is frequently the answer and neither project's documentation will say so.

### "How is the Responses API implemented?"

| Question | File |
|---|---|
| The handler | LocalAGI `webui/app.go:575-692` |
| Request and response types | LocalAGI `webui/types/openai.go` |
| Conversation tracker | LocalAGI `core/conversations/` |
| LocalAI's agent interceptor | LocalAI `core/http/endpoints/localai/agent_responses.go` |

`webui/types/openai.go:161` is where `Stream` is declared — and grepping for its use across the
tree is how you establish that nothing reads it.

### "What happens to an ingested document?"

| Question | File |
|---|---|
| Upload, search, reset handlers | LocalRecall `routes.go` |
| Chunking | LocalRecall `pkg/chunk/chunking.go` |
| Asset storage, the `Chunked file` log | LocalRecall `rag/persistency.go` |
| Engine contract | LocalRecall `rag/engine.go` |
| chromem engine | LocalRecall `rag/engine/chromem.go` |
| **PostgreSQL engine, hybrid search, BM25** | LocalRecall `rag/engine/postgres.go` |
| LocalAI-as-store engine | LocalRecall `rag/engine/localai.go` |
| External source polling | LocalRecall `rag/source_manager.go` |

### "Which tools can an agent use?"

| Question | File |
|---|---|
| All 40 built-in actions | LocalAGI `services/actions/` |
| Delegation, whitelist/blacklist | LocalAGI `services/actions/callagents.go` |
| Connectors (Slack, Discord, …) | LocalAGI `services/connectors/` |
| Dynamic prompts | LocalAGI `services/` |
| Skills | LocalAGI `services/skills/` |

### "How do the projects depend on each other?"

| File | What it settles |
|---|---|
| LocalAI `go.mod` | the pinned LocalAGI, LocalRecall and cogito commits |
| LocalAGI `go.mod` | whether LocalRecall is a dependency **at all** — differs by tag |
| LocalAGI `webui/collections/rag_provider.go:152-156` | a comment naming LocalAI as an intended embedder |
| LocalAGI `cmd/serve.go:113-120` | the retrieval-provider fork |
| LocalAGI `webui/routes.go:217-227` | the collections-backend fork |

Reading the two `go.mod` files is the fastest way to establish what a given release actually
contains — and it is how the v2.8.1 divergence was found.

### "What does the container actually ship?"

| Project | File |
|---|---|
| LocalAI | `Dockerfile` — build targets, declared volumes |
| LocalAGI | `Dockerfile.webui` — Ubuntu base, has curl and wget |
| LocalRecall | `Dockerfile` — **`FROM scratch`**, no shell |
| Upstream compose examples | `docker-compose.yaml` in LocalAGI and LocalRecall |

LocalRecall's `FROM scratch` explains several operational constraints at once: no `docker exec`,
no `CMD` healthcheck, and working-directory-relative paths landing in the container layer.

LocalAGI's `docker-compose.yaml` is worth reading for what it reveals rather than as a template:
it maps `8080:3000`, uses a bare `http://localai:8080` base URL, and pulls
`quay.io/mudler/localrecall:*-postgresql` as its database.

### "Which models are available, and how are they configured?"

| File | Note |
|---|---|
| LocalAI `gallery/index.yaml` | every gallery entry, its `files` URIs and `overrides` |
| LocalAI `gallery/<family>.yaml` | the shared `config_file` each entry merges |

These are large but greppable, and they are the ground truth for a model's real configuration —
including the fact that `qwen3-1.7b` inherits `context_size: 8192` rather than the model's native
32,768.

They are also served over HTTP from `raw.githubusercontent.com`, which is why a rate limit there
breaks model installation entirely. Having a local clone is a genuine workaround.

## Useful greps

Establishing that a field is unused — the technique behind the `stream` finding:

```bash
grep -rn 'Stream' --include='*.go' webui/ core/ | grep -v _test
```

Every environment variable a project reads:

```bash
grep -o 'env:"[^"]*"' core/cli/run.go | sort -u
```

```bash
grep -rn 'os.Getenv' --include='*.go' . | grep -v _test
```

Every route, in one pass:

```bash
grep -rn '\(app\|webapp\|e\|ag\|cg\)\.\(Get\|Post\|Put\|Delete\|GET\|POST\|PUT\|DELETE\)("' \
  --include='*.go' . | grep -v _test
```

Whether a dependency exists at all:

```bash
grep -rl 'mudler/localrecall' --include='*.go' . | wc -l
```

## Reading order, if you are new

1. **LocalAI `core/cli/run.go`** — what is configurable, and the vocabulary
2. **LocalRecall `main.go` and `routes.go`** — the smallest complete project; read it whole
3. **LocalAGI `core/state/config.go`** — what an agent *is*
4. **LocalAGI `core/agent/knowledgebase.go`** — short, and explains most retrieval behaviour
5. **LocalAI `pkg/model/initializers.go`** — the two-process architecture
6. **cogito** — when you need to know why an agent chose what it chose

LocalRecall is genuinely small and repays reading end to end. Start there if you want a complete
mental model of one component before tackling the others.

## Upstream references

- [mudler/LocalAI](https://github.com/mudler/LocalAI/tree/v4.8.2)
- [mudler/LocalAGI](https://github.com/mudler/LocalAGI/tree/v2.9.0) — and [v2.8.1](https://github.com/mudler/LocalAGI/tree/v2.8.1)
- [mudler/LocalRecall](https://github.com/mudler/LocalRecall/tree/v0.6.4)
- [mudler/cogito](https://github.com/mudler/cogito)
- Swagger path count and the v2.8.1 dependency check: observed 2026-08-17, see [version matrix](../00-overview/version-matrix.md).
