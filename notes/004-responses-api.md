# 004 — The Responses API

**Question:** why does an agent use the Responses API rather than Chat Completions, and how
faithful is the implementation?

**Answer:** because an agent request is a *loop*, and Chat Completions has no way to express
"pursue this until done". The implementation borrows the shape and omits several things a
client will assume are present.

## Why not Chat Completions

Chat Completions is one model call. Everything about it assumes that:

| Property | Chat Completions | What an agent needs |
|---|---|---|
| Calls per request | exactly 1 | 1 per iteration |
| Conversation state | caller sends all of it | server may hold it |
| Tool execution | the caller does it | the platform does it |
| Latency | proportional to tokens | unbounded |
| Output shape | one message | a sequence of items |

The Responses shape fits because it is item-oriented: an `output` array can contain messages
*and* `function_call` items, which is what a loop produces.

That is the honest answer to "why". Not that Responses is newer, but that a loop needs a
response format that can carry more than one kind of thing.

## The one thing to know

```text
model  =  the AGENT name
```

Verified: sending a model name returns HTTP **500** `{"error":"Agent not found"}`.

Every other endpoint in this stack means "a model" by `model`. This one means "an agent". In
LocalAI's integrated deployment a middleware inspects the field and diverts the request into the
agent runtime, otherwise falling through to ordinary inference — **so the same URL runs two
different engines, and a typo silently changes which one.**

## What we verified, and what diverges

Response observed from LocalAGI v2.8.1:

```json
{
  "id": "b9ec1e4d-41c5-42b7-a18a-d12d21040be4",
  "object": "response", "status": "completed", "model": "handbook-probe",
  "output": [{"type":"message","id":"msg_1786981102342119587","role":"assistant",
              "content":[{"type":"output_text","text":"4"}]}],
  "usage": {"input_tokens":0,"output_tokens":0,"total_tokens":0},
  "store": false, "previous_response_id": null
}
```

| Field | Divergence |
|---|---|
| `id` | a **bare UUID**, not `resp_…` |
| `usage` | **always zero** — hardcoded, with `// TODO: calculate actual usage` |
| `previous_response_id` | echoed as `null` even when sent |
| `stream` | **accepted and silently ignored** |
| `temperature`, `top_p` | reported as `0` |
| `store` | `false`, and accurate |

### `stream` is the one that breaks clients

The field exists on the request type (`webui/types/openai.go:161`) and **no handler reads it** —
confirmed by grep across the whole `webui` and `core` trees.

A client asking for a stream gets one complete JSON body, HTTP 200, and no signal that its
request was not honoured. An SSE consumer hangs waiting for events that never arrive.

Streaming exists elsewhere: LocalAI's `/v1/chat/completions` supports it, and LocalAGI has its
own `GET /sse/:name` channel. Just not here.

### `usage` being zero has a downstream cost

Token accounting is impossible at the agent layer. It must come from LocalAI's per-call
responses — and since one agent request produces several calls, you must sum them, and there is
**no request-ID propagation** to attribute them by. Correlation is by timestamp.

## Conversation state: the mechanism and its three sharp edges

```text
request(previous_response_id=A) -> read conv[A] -> run -> conv[B] = conv[A] + turn -> return B
```

Verified working: a second request with the prior `id` did recall the earlier fact.

**Each reply returns a new UUID.** `b9ec1e4d-…` → `00c6abcf-…`. Conversation identity is a
chain of per-turn IDs, not one session ID. Continuing from an older ID branches.

**It is memory-only with a TTL.** `LOCALAGI_CONVERSATION_DURATION`, falling back to **1 hour**
if unset or unparseable. Never written to disk; lost on restart.

**Expiry and non-existence are indistinguishable.** Verified with a deliberately invalid ID:

```text
previous_response_id: "does-not-exist-at-all"
-> 200, "I don't have access to personal information such as favorite colors."
```

No error, no warning. `GetConversation` returns an empty conversation for unknown *or* expired
keys, and additionally garbage-collects other expired conversations on the way through. So
three states look identical to a client: valid-but-new, expired, never existed.

This is the mechanism behind "the agent forgot everything over lunch".

There is one guard: continuing with **no new input** is rejected, with a genuinely useful
message —

```json
{"error":"previous_response_id was set but no new input was sent; send at least one user or tool message when continuing a conversation"}
```

The source comment explains why: the job would end on an assistant message, which backends with
`enable_thinking` reject.

## A method note

Our first attempt at testing continuation extracted the id with a greedy
`sed 's/.*"id":"\([^"]*\)".*/\1/'`. That captures the **last** `"id"` in the body — the
`msg_<nanoseconds>` inside `output[0]` — not the response id. The test then behaved exactly like
an unknown conversation, and briefly looked like "`previous_response_id` doesn't work".

Two lessons: use `jq -r '.id'`, and a negative result that matches a known failure mode deserves
a second look before it becomes a finding.

## Three kinds of tool, easy to conflate

| Kind | Executed by | Configured |
|---|---|---|
| Chat Completions `tools` | your client | per request |
| Responses user-defined `tools` | **your client** | per request |
| Agent `actions` / MCP | **LocalAGI** | on the agent |

The endpoint supports the client-side loop *and* the server-side one simultaneously.
User-defined tools come back as a `function_call` output item, the conversation is saved
**without** an assistant message, and your client is expected to return a
`function_call_output`. Meanwhile the agent's own actions execute server-side with no client
involvement.

Mixing them without noticing produces a request where some tools ran on your side and some did
not.

## Latency: the reason all of this matters

| Request | Model calls | Wall clock |
|---|---|---|
| Agent, no tools, no knowledge | 1 | 2–3 s |
| Agent, knowledge only | 1 | 2.27 s |
| Agent, knowledge + 1 tool | 2 | 24.1 s |
| Agent, 1 tool | 3 | **38.7 s** |

Same model, same hardware, an order of magnitude apart — because the loop iterated.

`LOCALAGI_TIMEOUT` (default `5m`) bounds **one model call**, not the request. So three timeouts
must be ordered `client > proxy > LOCALAGI_TIMEOUT`, and an ingress default of 60 s is already
too short. When it fires, the client gets a **504 while the agent completes and commits its
side effects** — which is why agent requests are not retry-safe and Chat Completions is.

## Open questions

1. Is `stream` unimplemented deliberately, or unfinished? The field's presence suggests
   intent.
2. Does LocalAI's agent interceptor produce a `resp_`-prefixed id, unlike standalone LocalAGI's
   bare UUID? Not tested — we ran only standalone.
3. Will `usage` be populated? The `TODO` suggests yes, eventually.

## References

- `LocalAGI/webui/app.go:575-692` — the handler: input normalisation, the no-new-input guard at
  598-602, agent lookup at 604-608, tool separation at 616-626, the tool-call response path at
  646-658, new-UUID storage at 644 and 666
- `LocalAGI/webui/app.go:567-571` — hardcoded zero `usage`
- `LocalAGI/webui/types/openai.go:161` — `Stream`, read by nothing
- `LocalAGI/core/conversations/` — the tracker, TTL expiry, opportunistic GC
- `LocalAGI/webui/options.go:42-50` — the 1 hour fallback
- `LocalAGI/webui/routes.go:58, 75, 83` — `/sse/:name`, `/api/chat/:name`, `/v1/responses`
- `LocalAI/core/http/endpoints/localai/agent_responses.go` — the interceptor
- Response bodies, the 500, the unknown-id behaviour and all latencies: observed 2026-08-17,
  [006](006-validation-log.md)
