# MCP in LocalAGI

LocalAGI is an MCP **client**. It connects out to MCP servers to acquire tools.
It does not expose an MCP endpoint, and no external MCP client can connect to it.

That is a stronger claim than "we did not find one", so here is the evidence:

- The complete route table contains no `/mcp` path — routes are registered in
  exactly two functions, `webui/routes.go:28` and
  `webui/collections_handlers.go:72`, and neither declares one.
- A repo-wide grep over `*.go` for `mcp.NewServer`, `NewStreamableHTTPHandler`
  and `mcp.NewSSEHandler` returns zero hits.
- The only two `mcp.NewClient` call sites are `core/agent/mcp.go:146` and
  `services/skills/service.go:173`. Both are clients.

There *is* one MCP server in the process — skillserver's — but it is bound to an
in-memory pipe, never to a socket. See [skills](skills.md).

## Configuring servers

Three fields on the agent config (`core/state/config.go:59-61`):

```go
MCPServers       []agent.MCPServer      `json:"mcp_servers"`        // {url, token}
MCPSTDIOServers  []agent.MCPSTDIOServer `json:"mcp_stdio_servers"`  // {name, cmd, args[], env[]}
MCPPrepareScript string                 `json:"mcp_prepare_script"`
```

`mcp_stdio_servers` decodes from **two shapes**
(`core/state/config.go:591-688`):

- A JSON **string** containing the Claude-Desktop form —
  `{"mcpServers": {"name": {"command": …, "args": […], "env": {…}}}}` — whose env
  map is flattened to `KEY=VALUE` strings.
- A JSON **array** of `{name, cmd, args, env}` objects.

`MarshalJSON` always re-emits the string form, so a config round-trip through
the API rewrites an array into a string. Both UI fields are textareas.

`mcp_prepare_script` runs `/bin/bash -c <script>` before any stdio server starts
(`core/agent/mcp.go:181-190`). It is arbitrary shell execution driven by agent
configuration, which on an unauthenticated deployment means arbitrary shell
execution driven by an HTTP request.

!!! danger "The image has no runtime for the usual stdio servers"
    Verified inside LocalAGI v2.8.1:

    ```text
    node MISSING    npx MISSING    python3 MISSING    uvx MISSING
    bash /usr/bin/bash   curl /usr/bin/curl   docker /usr/bin/docker   git /usr/bin/git
    ```

    Most reference MCP servers ship as `npx @modelcontextprotocol/server-*` or
    `uvx mcp-server-*`, so **they cannot run as stdio children of LocalAGI as shipped.**

    Options: bridge the server to HTTP and use `mcp_servers` (recommended — it also gives the
    server its own lifecycle); use `mcp_prepare_script` to install a runtime or fetch a static
    binary first; build a custom image; or choose a statically linked Go/Rust server, which needs
    none of this.

    Validated end to end with the HTTP bridge in
    [Recipe 7](../05-recipes/mcp-agent.md).

### Which HTTP transport

LocalAGI tries **`StreamableClientTransport`** first and falls back to **`SSEClientTransport`**
(`core/agent/mcp.go:158-166`, go-sdk v1.2.0). So either works, and a legacy SSE-only server is
fine — the fallback was exercised in Recipe 7.

On the SSE transport, client→server messages go as `POST /messages/?session_id=<id>` while
responses arrive on the open stream. That is what you look for in a server's access log to prove
the boundary was crossed.

## Transports, and the order they are tried

| Transport | When it is used | Fallback behaviour |
|---|---|---|
| **Streamable HTTP** | First attempt for every entry in `mcp_servers` (`core/agent/mcp.go:158-159`) | On failure, SSE |
| **SSE** | Second attempt for the same entry (`:163-164`) | On failure, log and skip that server |
| **stdio** | Every entry in `mcp_stdio_servers`, via `exec.Command` and `mcp.CommandTransport` (`:192-212`) | No fallback |
| **In-memory** | Pre-connected sessions injected by the host — in practice the skills server (`:215-223`) | — |

The first two are a genuine per-server fallback chain: a remote server that
speaks only SSE still works. The last two are not alternatives to the first two;
they are different configuration lists.

Remote connections get an `http.Client` with a **360-second** timeout and a round
tripper that injects `Authorization: Bearer <token>`
(`core/agent/mcp.go:153-156`, `:115-137`).

**A broken MCP server does not stop the agent.** Both transports failing produces
a log line and a `continue` (`core/agent/mcp.go:165-168`). The agent starts with
fewer tools and says nothing about it in its answers.

The client announces itself as `Name: "LocalAI"`, not `"LocalAGI"`
(`core/agent/mcp.go:146`). Cosmetic, but it shows up in MCP server logs and in
any server that gates behaviour on client identity. The skills path gets it right
(`services/skills/service.go:173`).

## Discovery happens once

`initMCPActions()` is called from `agent.New()` (`core/agent/agent.go:142`), and
`addTools` calls `client.ListTools(ctx, nil)` at that moment
(`core/agent/mcp.go:70-111`). There is no refresh timer, no `tools/list_changed`
subscription, no re-listing between jobs.

**A tool added to an MCP server after the agent started is invisible until the
agent is recreated.** The only path that re-runs discovery is
`AgentPool.RecreateAgent` (`core/state/pool.go:224-271`), which is what a
`PUT /api/agent/:name/config` triggers. Saving the config unchanged is the
supported way to pick up new tools.

`closeMCPServers` deliberately keeps the injected in-memory sessions alive across
an agent restart (`core/agent/mcp.go:230-243`), so the skills session is not
rebuilt each time.

Schema conversion carries an author's warning. Each MCP tool's input schema is
marshalled and re-unmarshalled into LocalAGI's own struct, above this comment:

> `// XXX: This is a wild guess, to verify (data types might be incompatible)`
> — `core/agent/mcp.go:94`

Treat exotic MCP argument types as unproven through this path.

## MCP tools are executed by cogito, not by LocalAGI

The wrapper LocalAGI builds for each MCP tool has a stub `Run`:

```go
// core/agent/mcp.go:41-45
// We don't call the method here, it is used by cogito.
return types.ActionResult{Result: "MCP action called"}, fmt.Errorf("not implemented")
```

The live sessions are handed to the loop with
`cogito.WithMCPs(a.mcpSessions...)` (`core/agent/agent.go:1048`), and cogito
calls `CallTool` itself. LocalAGI's wrappers exist only so the UI and the
observer can name and describe MCP tools — they populate
`a.mcpActionDefinitions`, which is read when resolving a tool name for display
(`core/agent/agent.go:1028, 1130, 1150`).

Two consequences:

- Anything cogito does to MCP schemas — nullable-type coercion, boolean-schema
  normalisation, strict-schema flattening — happens after LocalAGI's conversion
  and is not visible in LocalAGI's tree.
- LocalAGI's tool callback still sees MCP tool calls and can veto them, because
  the callback runs in cogito's loop. Connector-level vetoes therefore apply to
  MCP tools as well as to built-in actions.

## The LocalAI contrast that catches people out

If you also run LocalAI, note that LocalAI does **not** delegate MCP to LocalAGI
or to cogito. It implements MCP twice, in two stacks with different transport
support:

| Stack | Transports | Where |
|---|---|---|
| Model path (`/v1/chat/completions`, `/v1/mcp/chat/completions`) | streamable HTTP + stdio — **no SSE** | `LocalAI/core/http/endpoints/mcp/tools.go:343,369` |
| Agent path (embedded agents) | **SSE** + stdio — no streamable HTTP | `LocalAI/core/services/agents/mcp.go:26,44` |
| LocalAI Assistant admin tools | in-memory | `LocalAI/core/http/endpoints/mcp/localai_assistant.go:49` |
| LocalAI acting as an MCP server | stdio | `LocalAI/core/cli/mcp_server.go:46` |

**An MCP server that offers only streamable HTTP works with LocalAI models and
not with LocalAI agents. One that offers only SSE works with LocalAI agents and
not with LocalAI models.** Standalone LocalAGI, which tries streamable HTTP then
SSE, works with either.

This asymmetry is undocumented upstream and is worth checking first when a tool
appears on one path and not the other.

The two projects also pin different MCP SDKs — LocalAI `v1.5.0`, LocalAGI
`v1.2.0` — so protocol-level behaviour is not guaranteed identical between them.

## Upstream references

- [`core/agent/mcp.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/agent/mcp.go) — config structs, `initMCPActions`, transport fallback, the `Run` stub, the schema-conversion warning. Validated against v2.9.0, 2026-08-17.
- [`core/agent/agent.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/agent/agent.go) — `cogito.WithMCPs` at line 1048, MCP action definitions used for display. Validated against v2.9.0, 2026-08-17.
- [`core/state/config.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/state/config.go) — the two accepted shapes of `mcp_stdio_servers`. Validated against v2.9.0, 2026-08-17.
- [`core/state/pool.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/state/pool.go) — `RecreateAgent`, the only rediscovery path. Validated against v2.9.0, 2026-08-17.
- [`services/skills/service.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/services/skills/service.go) — the in-memory MCP server and its client. Validated against v2.9.0, 2026-08-17.
- [LocalAI `core/http/endpoints/mcp/tools.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/endpoints/mcp/tools.go) — model-path transports. Validated against v4.8.2, 2026-08-17.
- [LocalAI `core/services/agents/mcp.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/services/agents/mcp.go) — agent-path transports. Validated against v4.8.2, 2026-08-17.
