# Example 7 — MCP

**Not validated.** No MCP server was run during this handbook's validation, so unlike every
other example here there is no `run.sh` that has been executed end to end. What follows is a
configuration template derived from LocalAGI v2.9.0 source.

The recipe is [docs/05-recipes/mcp-agent.md](../../docs/05-recipes/mcp-agent.md).

## Why there is no script

An MCP example needs an MCP server, and any server we picked would be either a dependency you
do not have or a security decision we should not make for you. Writing a `run.sh` that has
never run would violate this handbook's own evidence rules.

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
