# Example 7 — MCP

**Validated** over HTTP with the `time` server on Kubernetes, 2026-08-17. The manifest is
`mcp-time-k8s.yaml`; the walkthrough is
[Recipe 7](../../docs/05-recipes/mcp-agent.md).

There is still no `run.sh` here, deliberately: this example needs a *server*, and which server you
run is a decision with security consequences that a script should not make for you.

## Why HTTP and not stdio

`mcp-server-time` speaks stdio only. LocalAGI can run stdio servers, but as **child processes of
its own container** — and the v2.8.1 image has no runtime to run the usual ones with:

```text
node MISSING    npx MISSING    python3 MISSING    uvx MISSING
bash /usr/bin/bash   curl /usr/bin/curl   docker /usr/bin/docker   git /usr/bin/git
```

So `npx @modelcontextprotocol/server-*` and `uvx mcp-server-*` — most reference servers — cannot
run as stdio children as shipped. `mcp-time-k8s.yaml` therefore wraps the stdio server with
`mcp-proxy` and serves it over SSE, which is the better shape anyway: its own lifecycle, its own
restart, and something a NetworkPolicy can constrain.

For stdio, `mcp_prepare_script` runs `/bin/bash -c <script>` before MCP setup, so it can install a
runtime or fetch a static binary. A statically linked Go or Rust server needs none of that.

## Quick start

```bash
kubectl apply -f mcp-time-k8s.yaml
kubectl -n localai-stack rollout status deploy/mcp-time
```

Wait for it to serve **before** creating the agent — discovery happens at agent start and is not
retried:

```bash
kubectl -n localai-stack logs deploy/mcp-time | tail -3
```

```bash
curl -s -X POST http://localhost:18081/api/agent/create \
  -H 'Content-Type: application/json' --data @create-http.json
```

Edit `create-http.json` first: it ships with `REPLACE-ME` placeholders. For the shipped manifest
the URL is `http://mcp-time:8080/sse` and no token is needed.

```bash
curl -s http://localhost:18081/v1/responses -H 'Content-Type: application/json' \
  -d '{"model":"mcp-probe","input":"What is the current time in Asia/Tokyo? Use your tools."}' \
  | jq -r '.output[0].content[0].text'
```

```bash
curl -s http://localhost:18081/api/agent/mcp-probe/status | jq -r '.History[]'
```

Expect `get_current_time` with `{"timezone":"Asia/Tokyo"}` and a real timestamp.

## Prerequisite

**Tool calling must already work.** MCP changes only *where* a tool lives, so debug it against
[example 05](../05-agent-tools/) first:

```bash
../05-agent-tools/run.sh
```

## The two transports

`create-http.json` and `create-stdio.json` in this directory are ready to edit.

HTTP — the server has its own lifecycle:

```bash
curl -s -X POST http://localhost:8081/api/agent/create \
  -H 'Content-Type: application/json' --data @create-http.json | jq
```

stdio — **the server becomes a child process of LocalAGI**, so `cmd` must exist inside the
LocalAGI container:

```bash
docker exec localagi ls -la /usr/local/bin/your-mcp-server
```

```bash
curl -s -X POST http://localhost:8081/api/agent/create \
  -H 'Content-Type: application/json' --data @create-stdio.json | jq
```

## Verifying

Discovery happens at agent start, so a missing server is a startup problem:

```bash
docker logs localagi 2>&1 | grep -i mcp
```

No MCP lines means discovery failed and the agent silently has fewer tools.

Then run a request and read the history — MCP tools appear alongside built-in ones, because by
the time the model chooses, both are just tools with schemas:

```bash
curl -s http://localhost:8081/api/agent/example-mcp/status | jq -r '.History[]'
```

## Two things to know before you enable one

**stdout is the protocol channel.** An MCP server that logs to stdout corrupts the stream. Its
diagnostics must go to stderr.

**MCP has no permission model.** If the model can name the tool, it can call it with arguments
it chose. Constrain at the boundary — a read-only root for a filesystem server, a scoped token
for an API server, egress policy for an HTTP one. Bearer tokens you put in the config are stored
**in plain text** in the agent's JSON on disk.

See [the security model](../../docs/07-deep-dives/security-model.md).

## Cleanup

```bash
curl -s -X DELETE http://localhost:8081/api/agent/example-mcp | jq
```

Deleting the agent stops any stdio child process. It does **not** undo anything the MCP tools
did — that is outside this stack entirely.
