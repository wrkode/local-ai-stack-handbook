# LocalAGI

LocalAGI is an agent *platform*: configuration, persistence, an HTTP API, a web
UI, chat connectors, a scheduler, a knowledge bridge and a tool registry. It is
the thing that decides which tools an agent has, where its state is written and
how a message reaches it.

It does **not** implement the agent loop. The reason/act/observe cycle —
iteration, tool selection, planning, retries, loop detection, context compaction
— belongs to [`github.com/mudler/cogito`](https://github.com/mudler/cogito), a
separate Go library. LocalAGI builds a configuration, hands it to
`cogito.ExecuteTools`, and gets control back only through three callbacks. This
is the single most useful fact about the project, and it is invisible from the
README.

## Who owns what

| Concern | Owner | Where |
|---|---|---|
| Iteration cap, tool selection, forced reasoning, planning, retries, loop detection, compaction, streaming events | **cogito** | `cogito.ExecuteTools` |
| Which tools exist, their JSON schemas, their Go implementations | LocalAGI | `services/actions/`, `core/action/` |
| Agent configuration and its persistence | LocalAGI | `core/state/` |
| Prompt assembly, HUD, filters, knowledge recall, conversation write-back | LocalAGI | `core/agent/` |
| MCP connection setup (but not MCP tool execution) | LocalAGI | `core/agent/mcp.go` |
| MCP tool execution | **cogito** | via `cogito.WithMCPs` |
| Embedding, chunking, vector storage | **LocalRecall** | linked in-process as a library |
| Token generation | a model server, normally LocalAI | over HTTP |

Source-verified against v2.9.0: `core/agent/agent.go:1368` is the single call
site where the loop leaves LocalAGI's code.

## Two ways it runs, and they are not the same code

### Standalone

The `localagi` binary. `local-agi serve` (or the bare binary, which defaults to
`serve`) starts a Fiber HTTP server, loads `pool.json`, instantiates every agent
in it and runs them. This is what [installation](installation.md) covers.

Version: **v2.9.0**, released 2026-05-08.

### Embedded in LocalAI

LocalAI v4.8.2 imports LocalAGI as a Go library — `core/state`, `core/agent`,
`core/types`, `core/sse`, `services`, `services/skills`, `webui/collections` —
and re-implements the HTTP surface itself. LocalAGI's own web server,
`/v1/responses` handler, React UI and `pkg/localrag` HTTP client are not used.

The pinned version there is **not v2.9.0**. LocalAI's `go.mod` requires
`github.com/mudler/LocalAGI v0.0.0-20260606071251-14aed1ae4336` — an untagged
commit from 2026-06-06. The module path has no `/v2` suffix, so Go's import-path
versioning rules make the `v2.x` tags unusable: the only way to depend on
LocalAGI is to pin a raw commit. Every statement in this chapter about
"LocalAGI v2.9.0" describes the standalone product; the embedded platform tracks
`main` and can differ.

The two also pin **different versions of cogito** — v0.9.5 (March 2026) in
LocalAGI v2.9.0, v0.11.1 (July 2026) in LocalAI v4.8.2. What that costs is in
[the agent loop](agent-loop.md).

## Default port is 3000, and the README says 8080

`LOCALAGI_BASE_URL` defaults to `:3000` (`cmd/env.go:55`), and that value is
passed straight to `app.Listen` (`cmd/serve.go:126`). Run the binary and it
listens on 3000.

`README.md:75` tells the reader to open `http://localhost:8080`. That is correct
only under the shipped compose file, which publishes the container's 3000 as host
8080 (`docker-compose.yaml:83-84`, `ports: - 8080:3000`). Both statements are
individually true; the README does not say which is which. The README's own
environment-variable table (`README.md:243`) and its curl examples
(`README.md:918`) use 3000.

**Believe the source: 3000 for a local binary, 8080 for the shipped compose
stack.**

## What LocalAGI is not

- **Not a model server.** It has no inference code. It requires
  `LOCALAGI_LLM_API_URL` and `LOCALAGI_MODEL` and refuses to start without them
  (`cmd/serve.go:31-36`).
- **Not an OpenAI drop-in.** It serves exactly one OpenAI-compatible route,
  `POST /v1/responses`. There is no `/v1/chat/completions`, no `/v1/models`, no
  `/v1/embeddings`. See [the Responses API](responses-api.md).
- **Not an MCP server.** It is an MCP *client*. Nothing in the tree binds an MCP
  server to a socket. See [MCP](mcp.md).
- **Not database-backed.** Agent configuration, runtime state and scheduled tasks
  are JSON files. The only database in the picture is PostgreSQL as a vector
  store for LocalRecall, and it is optional. See [state](state.md).
- **Not authenticated by default.** The API-key middleware is installed only when
  `LOCALAGI_API_KEYS` is non-empty (`webui/routes.go:30-36`). With no keys set,
  every route is open — including the ones that accept interpreted Go and shell
  scripts.

## Chapter map

| Page | Answers |
|---|---|
| [architecture.md](architecture.md) | What runs in which process, and how the pieces are wired |
| [installation.md](installation.md) | Getting it running, standalone or under compose |
| [agents.md](agents.md) | The configuration schema and its traps |
| [agent-loop.md](agent-loop.md) | What actually happens between a prompt and an answer |
| [tools.md](tools.md) | The built-in actions and how to add one |
| [mcp.md](mcp.md) | External tools, transports, and the client-only boundary |
| [skills.md](skills.md) | Instructions the model reads, versus tools it calls |
| [state.md](state.md) | Every file on disk, and what is lost on restart |
| [memory.md](memory.md) | The three unrelated things called "memory" |
| [responses-api.md](responses-api.md) | The one OpenAI-compatible route |
| [troubleshooting.md](troubleshooting.md) | Diagnostics for the failure modes above |

## A note on the citations in this chapter

Every claim here is **source-verified**: read in the implementation, cited
`path:LINE`. Nothing in this chapter has been executed by us, so no page carries
a `tested:` block and no page describes observed runtime behaviour.

The reading was done against commit `9a6b32f`, three commits past the `v2.9.0`
tag; the diff over `core/`, `services/` and `webui/` in that range is empty.
Links are pinned to the `v2.9.0` tag, so a line number may be off by a small
offset in files that changed after the tag.

## Upstream references

- [`cmd/env.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/cmd/env.go) — `LOCALAGI_BASE_URL` default `:3000`, full environment surface. Validated against v2.9.0, 2026-08-17.
- [`cmd/serve.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/cmd/serve.go) — startup order, required model and API URL. Validated against v2.9.0, 2026-08-17.
- [`core/agent/agent.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/agent/agent.go) — `cogito.ExecuteTools` call site at line 1368. Validated against v2.9.0, 2026-08-17.
- [`go.mod`](https://github.com/mudler/LocalAGI/blob/v2.9.0/go.mod) — cogito `v0.9.5-0.20260315222927`, localrecall, skillserver pins. Validated against v2.9.0, 2026-08-17.
- [`docker-compose.yaml`](https://github.com/mudler/LocalAGI/blob/v2.9.0/docker-compose.yaml) — `8080:3000` port mapping. Validated against v2.9.0, 2026-08-17.
- [`README.md`](https://github.com/mudler/LocalAGI/blob/v2.9.0/README.md) — the `localhost:8080` instruction at line 75. Validated against v2.9.0, 2026-08-17.
- [LocalAI `go.mod`](https://github.com/mudler/LocalAI/blob/v4.8.2/go.mod) — `LocalAGI v0.0.0-20260606071251-14aed1ae4336`, cogito `v0.11.1`. Validated against v4.8.2, 2026-08-17.
- [LocalAGI release v2.9.0](https://github.com/mudler/LocalAGI/releases/tag/v2.9.0) — released 2026-05-08. Validated 2026-08-17.
