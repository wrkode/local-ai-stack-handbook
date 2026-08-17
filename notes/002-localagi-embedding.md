# 002 — What LocalAI embeds, and which version

**Question:** when people say "LocalAGI is built into LocalAI", what is actually true?

**Answer:** LocalAI imports LocalAGI as a Go module and runs its agent pool in-process. But it
imports an **untagged commit from `main`**, not a release — and it cannot do otherwise.

## The Go module constraint

`LocalAI/go.mod` pins:

```text
github.com/mudler/LocalAGI v0.0.0-20260606071251-14aed1ae4336
```

That is a pseudo-version: `v0.0.0`, a timestamp, and a commit hash. Not `v2.9.0`.

**This is not a choice.** LocalAGI's module path is `github.com/mudler/LocalAGI`, with no
`/v2` suffix. Go's semantic import versioning requires a major version above 1 to carry that
suffix in the path, so **Go cannot resolve LocalAGI's `v2.x` tags at all**. LocalAI's only
option is to pin raw commits.

Consequence: the embedded agent platform always tracks an untagged commit. There is no
LocalAI release that embeds a LocalAGI *release*, and there cannot be until upstream adds the
module suffix.

## What is embedded, and what starts

Observed in a stock LocalAI v4.8.2 container:

```text
INFO Agent pool started (standalone/LocalAGI mode) stateDir="//data" apiURL="http://127.0.0.1:8080"
INFO LocalAI Assistant in-memory MCP server initialised tools=36 read_only=false
```

The agent pool starts **automatically**. `LOCALAI_DISABLE_AGENTS` defaults to `false`, so a
plain `docker run localai/localai` is already an agent platform.

Route groups it adds (`core/http/routes/agents.go`):

| Group | Feature flag |
|---|---|
| `/api/agents` — CRUD, chat, SSE, actions | `agents` |
| `/api/agents/skills` | `skills` |
| `/api/agents/git-repos` | `skills` |
| `/api/agents/collections` | `collections` |

Note the prefix. The same collections contract that LocalRecall serves at `/api/collections`
appears here under `/api/agents/collections`. A client that makes the prefix configurable works
against all three projects.

There is also a `poolReadyMw` middleware returning `503 agent pool is starting, please retry
shortly` — so the pool is genuinely asynchronous relative to the listener.

## Three sets of names for one set of knobs

The clearest illustration of [001](001-logical-vs-physical.md)'s point. The same LocalRecall
settings are read under different names depending on who started the library:

| Setting | Standalone LocalRecall | Standalone LocalAGI | Inside LocalAI |
|---|---|---|---|
| engine | `VECTOR_ENGINE` | `VECTOR_ENGINE` | `LOCALAI_AGENT_POOL_VECTOR_ENGINE` |
| model | `EMBEDDING_MODEL` | `EMBEDDING_MODEL` | `LOCALAI_AGENT_POOL_EMBEDDING_MODEL` |
| chunk size | `MAX_CHUNKING_SIZE` | `MAX_CHUNKING_SIZE` | `LOCALAI_AGENT_POOL_MAX_CHUNKING_SIZE` |
| database | `DATABASE_URL` | `DATABASE_URL` | `LOCALAI_AGENT_POOL_DATABASE_URL` |

Same code, three namespaces. Configuration written for one shape silently does nothing in
another.

## The self-referencing loopback

`apiURL="http://127.0.0.1:8080"` in the startup log is the detail worth dwelling on.

The embedded agent pool does **not** call inference through Go function calls. It POSTs to
`/chat/completions` on its own process, over loopback HTTP. Likewise the embedded knowledge
layer POSTs `/embeddings` to itself.

| Consequence | Detail |
|---|---|
| API keys apply internally | `LOCALAI_AGENT_POOL_API_KEY` defaults to the first LocalAI key |
| Internal calls appear in the access log | indistinguishable from external traffic, apart from `remote_ip` |
| Startup ordering is load-bearing | the pool must start after the listener, or it deadlocks |
| Loopback failures are possible | rare, but they are real network calls |

So "embedded" removes the *network*, not the *protocol*.

## The cogito split is what actually changes behaviour

The versions that matter are not LocalAGI's but cogito's, since cogito owns the loop:

| Runs | cogito version | Date |
|---|---|---|
| LocalAI v4.8.2 | `v0.11.1-0.20260721…` | 2026-07-21 |
| LocalAGI v2.9.0 (source) | `v0.9.5-0.20260315…` | 2026-03-15 |
| LocalAGI v2.8.1 (image) | `v0.9.1-0.20260216…` | 2026-02-16 |

**Five months between the extremes**, across a minor version. Capabilities present in the newer
cogito — sub-agent spawning, KV-cache prefill, self-editing system prompts, park/resume — are
not reachable from the LocalAGI image.

The practical statement: **"the same agent feature" behaves differently in Pattern A and
Pattern B**, and Pattern A is the *newer* one. That inverts the usual assumption that the
standalone service is more current.

## Why run standalone LocalAGI at all, then?

A fair question given the above. Reasons that survive scrutiny:

| Reason | Holds? |
|---|---|
| Scale agents independently of inference | **no** — agents do not scale horizontally either way ([005](005-memory-model.md), `docs/07-deep-dives/scaling.md`) |
| Restart agents without unloading models | **yes** |
| Point agents at inference you do not run | **yes** — an existing OpenAI-compatible platform |
| Separate failure domains | **yes** |
| Use LocalAGI features LocalAI lacks | **partly** — the UI and connectors, but the loop is older |
| Newer agent behaviour | **no** — LocalAI's cogito is newer |

The strongest case is the third: LocalAGI standalone is how you keep agents local while
inference lives elsewhere.

## Open questions

1. Does commit `14aed1ae4336` (2026-06-06) include v2.9.0's in-process LocalRecall path? Dated
   after v2.9.0's release, and LocalAI's `/api/agents/collections` routes exist, which is
   consistent — but we did not read the commit.
2. Is the module-path `/v2` omission deliberate or an oversight? It has a real cost.
3. What exactly do the newer cogito capabilities change in observable behaviour? We could not
   compare, having no runnable v2.9.0.

## References

- `LocalAI/go.mod` — the pseudo-version pins
- `LocalAI/core/http/routes/agents.go` — the four route groups and `poolReadyMw`
- `LocalAI/core/cli/run.go:123-143` — the `LOCALAI_AGENT_POOL_*` variables; `LOCALAI_DISABLE_AGENTS` at 124
- `LocalAGI/go.mod` at v2.9.0 and v2.8.1 — cogito versions
- `LocalAGI/webui/collections/rag_provider.go:152-156` — the external-consumer comment
- Startup log, MCP log line and route probes: observed 2026-08-17, [006](006-validation-log.md)
