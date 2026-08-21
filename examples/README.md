# Examples

Runnable counterparts to the [recipes](../docs/05-recipes/index.md). Each directory is
self-contained, uses only `curl` and `sh`, and prints what it is doing so you can see which
boundary is being crossed.

The recipes explain *why*. These are the *what to run*.

## Prerequisites

Start the reference environment first — everything here talks to it:

```bash
cd ../compose
cp .env.example .env
docker compose up -d
```

Then verify, from the repository root:

```bash
./scripts/verify-stack.sh
```

Every script honours these, so a non-default deployment needs no edits:

| Variable | Default |
|---|---|
| `LOCALAI_URL` | `http://localhost:8080` |
| `LOCALAGI_URL` | `http://localhost:8081` |
| `LOCALRECALL_URL` | `http://localhost:8082` |
| `LLM_MODEL` | `qwen3-1.7b` |
| `EMBEDDING_MODEL` | `granite-embedding-107m-multilingual` |

```bash
LOCALAI_URL=http://gpu-box:8080 ./01-localai/run.sh
```

`jq` is optional throughout — scripts fall back to raw output.

## The examples

| Directory | Recipe | Demonstrates |
|---|---|---|
| [`01-localai/`](01-localai/) | [1](../docs/05-recipes/localai-chat.md) | model listing, chat completion, cold vs warm latency |
| [`02-embeddings/`](02-embeddings/) | [2](../docs/05-recipes/localai-embeddings.md) | dimensions, L2 normalization, similarity, batching |
| [`03-localrecall/`](03-localrecall/) | [3](../docs/05-recipes/localrecall-rag.md) | collection, ingest, chunking, search |
| [`04-agent/`](04-agent/) | [4](../docs/05-recipes/simple-agent.md) | agent creation, `/v1/responses`, conversation chaining |
| [`05-agent-tools/`](05-agent-tools/) | [5](../docs/05-recipes/agent-with-tools.md) | tool schema, direct run, agent invocation, tool history |
| [`06-agent-memory/`](06-agent-memory/) | [6](../docs/05-recipes/agent-with-knowledge.md) | agent + knowledge, and proof retrieval happened |
| [`07-mcp/`](07-mcp/) | [7](../docs/05-recipes/mcp-agent.md) | MCP over HTTP — **validated** with the `time` server; manifest included |
| [`08-full-stack/`](08-full-stack/) | [8](../docs/05-recipes/complete-agent-stack.md) | knowledge and a tool in one request, with the trace |

Run them in order. Each assumes the previous one worked, which is what makes a failure
attributable.

```bash
./01-localai/run.sh
```

## What every script does

| Step | Why |
|---|---|
| Checks its dependencies first | so a failure names the layer, not the symptom |
| Prints the request before sending it | so you can copy it |
| Prints observed timings | so you learn what is normal |
| Cleans up what it created | except downloaded models |

Scripts exit non-zero on failure and say which layer failed.

## Conventions

- POSIX `sh`, no bashisms — they run under `sh`, `bash` 3.2 and `zsh`
- No `set -e` surprises: failures are checked and reported, not silent
- Nothing is destructive beyond the objects the script itself created
- Agent and collection names are prefixed `example-` so they cannot collide with your own

## What these do not cover

| Not here | Why | See |
|---|---|---|
| GPU | no GPU was available to validate against | [GPU](../docs/06-deployment/gpu.md) |
| Kubernetes | not validated | [`kubernetes/`](../kubernetes/) |
| Multi-agent | not validated | [Recipe 9](../docs/05-recipes/multi-agent.md) |
| Production hardening | deliberately out of scope | [security](../docs/06-deployment/security.md) |

## Cleanup

Each script removes what it created. To remove everything the examples might have left:

```bash
./cleanup.sh
```

That deletes agents and collections named `example-*` and nothing else.
