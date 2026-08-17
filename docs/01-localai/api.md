# The HTTP API

LocalAI serves four API dialects on one port, plus its own administrative
surface. Which dialect you are speaking changes the request shape, the middleware
that runs, and in one case whether the request goes to a model at all.

## The spec is incomplete

| Path | Result |
|---|---|
| `GET /swagger/doc.json` | **200** — OpenAPI document, 111 paths, `info.title` `LocalAI API`, `info.version` `2.0.0` |
| `GET /swagger/index.html` | 200 — Swagger UI |
| `GET /openapi.json` | 404 |
| `GET /swagger.json` | 404 |

Tested 2026-08-17. Two caveats you must carry into any generated client:

- **`info.version` is `2.0.0` while the product is v4.8.2.** The annotation block
  in `core/http/app.go` has not tracked the product version. It is the spec's
  version string, nothing more.
- **The document is not the full surface.** `GET /api/agents` returns 200 on a
  stock instance and does not appear in the document at all (tested 2026-08-17).
  Counting distinct `(method, path)` registrations across `core/http/routes/`
  yields **341** entries against the spec's 111. Generate clients from the spec
  if you like; do not use it to conclude a route does not exist.

Path count by swagger tag, from the running instance (tested 2026-08-17):

| Tag | Paths | Tag | Paths |
|---|---|---|---|
| monitoring | 16 | config | 6 |
| audio | 11 | Nodes | 5 |
| backends | 11 | branding | 4 |
| agent-jobs | 11 | tokenize | 4 |
| models | 9 | voice-profiles | 4 |
| inference | 7 | images | 3 |
| face-recognition | 6 | 3d, p2p, pii, instructions | 2 each |
| voice-recognition | 6 | embeddings, mcp, rerank, router, moderation | 1 each |

## Four dialects

| Dialect | Entry points | Notes |
|---|---|---|
| **OpenAI** | `/v1/chat/completions`, `/v1/completions`, `/v1/edits`, `/v1/embeddings`, `/v1/moderations`, `/v1/audio/*`, `/v1/images/*`, `/v1/models`, `/v1/realtime` | The primary surface |
| **OpenAI Responses** | `/v1/responses`, `GET /v1/responses/:id`, `POST /v1/responses/:id/cancel` | Server-side state, background execution, WebSocket transport, **and agent addressing** |
| **Anthropic** | `POST /v1/messages` | Requires `max_tokens > 0`, matching Anthropic's own contract. Echoes `x-request-id`, logs `anthropic-version` |
| **Ollama** | `/api/chat`, `/api/generate`, `/api/embed`, `/api/embeddings`, `/api/tags`, `/api/show`, `/api/ps`, `/api/version` | `GET /` heartbeat only when `LOCALAI_OLLAMA_API_ROOT_ENDPOINT=true`, because it collides with the web UI |

Two more compatibility shims sit alongside them: **Jina** reranking at
`POST /v1/rerank`, and **ElevenLabs** at `POST /v1/text-to-speech/:voice-id` and
`POST /v1/sound-generation`.

Point a stock OpenAI SDK at `http://localhost:8080/v1` and it works. Point the
Anthropic SDK at `http://localhost:8080` and `/v1/messages` works. Point an
Ollama client at `http://localhost:8080` and `/api/*` works, but the root
heartbeat needs the flag.

## Un-prefixed route aliases

Nearly every OpenAI-compatible route is registered **twice** — with and without
the `/v1` prefix (source-verified, v4.8.2):

| Prefixed | Alias |
|---|---|
| `/v1/chat/completions` | `/chat/completions` |
| `/v1/completions` | `/completions`, `/v1/engines/:model/completions` |
| `/v1/embeddings` | `/embeddings`, `/v1/engines/:model/embeddings` |
| `/v1/edits` | `/edits` |
| `/v1/moderations` | `/moderations` |
| `/v1/audio/transcriptions`, `/v1/audio/speech` | `/audio/transcriptions`, `/audio/speech` |
| `/v1/images/generations` | `/images/generations` |
| `/v1/models` | `/models` |
| `/v1/messages` | `/messages` |
| `/v1/responses` | `/responses` |
| `/v1/mcp/chat/completions` | `/mcp/chat/completions`, `/mcp/v1/chat/completions` |

This matters for clients that build URLs by concatenation rather than by joining
a base URL. The agent pool's own LLM client (cogito) constructs endpoints without
the `/v1` segment, so these aliases are load-bearing for in-process agents rather
than cosmetic. The exact concatenation site inside cogito was not traced in this
pass — what is verified is that LocalAI registers both forms and that removing
the un-prefixed ones would break any such caller.

Two routes have **no** alias: `POST /v1/rerank` and the ElevenLabs endpoints.

Note also that some LocalAI-specific endpoints are un-prefixed only:
`/tts`, `/vad`, `/video`, `/3d/generations`, `/3d/remesh`, `/stores/*`. The
v4.8.0 release notes call the 3D endpoint `/v1/3d/generations`; the route is
registered as `/3d/generations` and the tests assert the un-prefixed path
(source-verified, v4.8.2).

## Inference routes

| Method | Path | Usecase filter |
|---|---|---|
| POST | `/v1/chat/completions` | chat |
| POST | `/v1/completions` | completion |
| POST | `/v1/edits` | edit |
| POST | `/v1/embeddings` | embeddings |
| POST | `/v1/moderations` | — |
| POST | `/v1/messages` (Anthropic) | chat |
| POST | `/v1/responses` | chat |
| POST | `/api/chat`, `/api/generate` (Ollama) | chat |
| POST | `/api/embed`, `/api/embeddings` (Ollama) | embeddings |
| POST | `/v1/rerank` | rerank |
| POST | `/v1/audio/transcriptions` | transcript |
| POST | `/v1/audio/speech`, `/tts` | tts |
| POST | `/v1/audio/diarization`, `/v1/audio/classification` | diarization, sound classification |
| POST | `/v1/images/generations`, `/inpainting`, `/upscale` | image |
| POST | `/video` | video |
| POST | `/3d/generations`, `/3d/remesh` | 3d |
| POST | `/v1/detection`, `/v1/depth` | detection, depth |
| POST | `/v1/tokenize`, `/v1/detokenize` | tokenize |
| POST | `/vad`, `/v1/vad` | vad |
| POST | `/audio/transformations` (+ WebSocket `/stream`) | audio transform |
| POST | `/v1/face/{verify,analyze,embed,register,identify,forget}` | face recognition |
| POST | `/v1/voice/{verify,analyze,embed,register,identify,forget}` | speaker recognition |
| GET | `/v1/realtime` (WebSocket/WebRTC), POST `/v1/realtime/sessions` | realtime audio |
| POST | `/api/score` | — (admin) |

The usecase filter is not decoration: a route only offers models whose declared
or guessed usecases include that flag, and it picks a default from that filtered
set when the request omits `model`. See [models](models.md).

### Per-route middleware

`/v1/chat/completions` carries the canonical chain (outermost first):
`ExposeNodeHeader` → `UsageMiddleware` → `TraceMiddleware` →
default-model selection → `SetModelAndConfig` → body parse → **`RouteModel`** →
**`AdmissionControl`** → **PII redaction**.

PII redaction is innermost deliberately, so per-model PII policy applies to the
model the router *chose*, not the model the client named.

`/v1/messages` gets the same shape plus an Anthropic probe and adapter.
Ollama chat/generate/embed get the PII middleware too.

**`/v1/responses` gets none of `RouteModel`, `AdmissionControl` or PII.** If you
rely on per-model concurrency limits or redaction, the Responses API bypasses
both.

## The Responses API

| Aspect | `/v1/chat/completions` | `/v1/responses` |
|---|---|---|
| Request shape | `messages[]` | `input` — a string or a polymorphic item array |
| Conversation state | Client resends everything | Server-side via `previous_response_id` |
| Persistence | None | `ResponseStore`, **in memory**, with `LOCALAI_OPEN_RESPONSES_STORE_TTL` |
| Retrieval | No | `GET /v1/responses/:id` |
| Cancellation | Close the connection | `POST /v1/responses/:id/cancel` |
| Background execution | No | Yes |
| Stream resume | No | Yes — buffered events replayed after `starting_after` |
| Transport | HTTP + SSE | HTTP + SSE **+ WebSocket** (`GET /v1/responses`) |
| Router / admission / PII | Yes | **No** |
| Agent addressing | No | **Yes** |

The store is a process-global singleton and is not on disk. Stored responses do
not survive a restart. In distributed mode it is replicated across frontend
replicas over NATS, which exists to stop a load balancer 404ing a `GET` that
lands on a replica that did not create the response.

### Agents as models

`AgentResponsesInterceptor` is registered as the **first** middleware on
`POST /v1/responses` and `POST /responses`. It buffers the body, reads only
`{model, input, previous_response_id, tools, tool_choice}`, and asks the agent
pool whether `model` names a registered agent. If not, it restores the body and
falls through to the ordinary model pipeline.

This is the **only** place an agent name works as a `model`. There is no
equivalent on `/v1/chat/completions`, and `/v1/models` does not list agents.

Two behaviours to design around (source-verified, v4.8.2):

- **The agent path never streams.** It always returns a single completed JSON
  response with HTTP 200, even when the request sets `"stream": true`.
- **In distributed mode only the last user message is forwarded** to the agent;
  local mode passes the full conversation history. `tools`, `tool_choice` and
  `previous_response_id` are parsed and then unused on this path.

## MCP

| Method | Path | Purpose |
|---|---|---|
| POST | `/v1/mcp/chat/completions` (+ two aliases) | Chat completions **with MCP tool execution attached** |
| GET | `/v1/mcp/servers/:model` | Configured MCP servers for a model |
| GET | `/v1/mcp/prompts/:model`, POST `/v1/mcp/prompts/:model/:prompt` | MCP prompts |
| GET | `/v1/mcp/resources/:model`, POST `/v1/mcp/resources/:model/read` | MCP resources |
| GET/POST/OPTIONS | `/api/cors-proxy` | Browser-side MCP access |

`/v1/mcp/chat/completions` is **not** OpenAI-compatible in streaming mode. The
source comment is explicit that it streams a richer set of states than the
OpenAI protocol defines. Treat it as a LocalAI-specific endpoint that happens to
accept an OpenAI-shaped request body.

All of it disappears under `LOCALAI_DISABLE_MCP=true`, along with the agent-job
routes.

## Administration

Gallery and model administration (admin-gated, removed by
`--disable-gallery-endpoint`):

| Method | Path |
|---|---|
| POST | `/models/apply`, `/models/import`, `/models/import-uri`, `/models/delete/:name`, `/models/edit/:name`, `/models/reload` |
| GET | `/models/available`, `/models/galleries`, `/models/jobs`, `/models/jobs/:uuid`, `/api/aliases` |
| PUT | `/models/toggle-state/:name/:action`, `/models/toggle-pinned/:name/:action` |
| POST | `/backends/apply`, `/backends/delete/:name`, `/backends/upgrades/check`, `/backends/upgrade/:name` |
| GET | `/backends`, `/backends/available`, `/backends/known`, `/backends/galleries`, `/backends/jobs/:uuid`, `/backends/upgrades` |

Monitoring and diagnostics (admin-gated):

| Method | Path | Notes |
|---|---|---|
| GET | `/metrics` | Prometheus. **Admin**, contrary to upstream's authentication page |
| GET | `/backend/monitor`, POST `/backend/shutdown`, POST `/backend/load` | Backend lifecycle |
| GET | `/api/traces`, `/api/traces/summary`, `/api/traces/:id` | API exchange traces |
| GET | `/api/backend-traces`, `/api/backend-traces/:id` | Backend operation traces |
| GET | `/api/backend-logs`, `/api/backend-logs/:modelId`, WS `/ws/backend-logs/:modelId` | **Standalone mode only** |
| GET | `/api/p2p`, `/api/p2p/token` | P2P state; the token is a credential |
| GET | `/system` | Backends and loaded models |
| GET | `/api/router/status`, `/api/router/decisions`, `/api/router/cache/stats`, POST `/api/router/decide` | Content router |
| GET | `/api/middleware/status`, `/api/middleware/proxy-ca.crt` | MITM proxy |

Public routes:

| Method | Path | Notes |
|---|---|---|
| GET | `/healthz` | Always 200 |
| GET | `/readyz` | 200 when ready, 503 only under socket activation |
| GET | `/version` | |
| GET | `/.well-known/localai.json` | **Agent discovery document** |
| GET | `/api/instructions`, `/api/instructions/:name` | Explicitly no-auth, for agent discovery |
| GET | `/api/features` | Feature flags |

Other groups, all LocalAI-specific: `/api/agents/*` (agents, skills, git-repos,
collections), `/api/agent/*` (tasks and jobs — note the **singular** namespace),
`/api/fine-tuning/*`, `/api/quantization/*`, `/api/auth/*`, `/api/usage`,
`/api/pii/*`, `/api/nodes/*` and `/api/node/*` (distributed), `/stores/*`
(vector store), `/api/voice-profiles`, and the web UI's `/api/*` JSON surface.

The two agent namespaces catch people out: `/api/agents` is the agent pool,
`/api/agent` is MCP CI tasks and jobs. They are unrelated.

## Authentication boundaries

With static keys or an auth database, `auth.Middleware` accepts credentials from
`Authorization: Bearer`, a raw `Authorization` value, `x-api-key`, `xi-api-key`,
or the `token` cookie. A matching static key yields a **synthetic admin user**.

| Category | Paths |
|---|---|
| Always exempt | Everything under `/api/auth/`, the four node self-service endpoints, anything in `PathWithoutAuth` (which includes `/healthz` and `/readyz`, matched by prefix) |
| Always required | `/api/`, `/v1/`, `/models/`, `/backends/`, `/backend/`, `/tts`, `/vad`, `/video`, `/3d/`, `/stores/`, `/system`, `/ws/`, `/generated-`, `/chat/`, `/completions`, `/edits`, `/embeddings`, `/audio/`, `/images/`, `/messages`, `/responses`, and exactly `/metrics` |
| Pass through | Web UI and static assets — the React app handles login client-side |

`--disable-api-key-requirement-for-http-get` plus the
`LOCALAI_HTTP_GET_EXEMPTED_ENDPOINTS` regex list opens GETs on matching route
patterns. The default list covers the UI, login, assets and swagger.

Failures return 401 with `WWW-Authenticate: Bearer`, or a bare 401 under
`--opaque-errors`.

## Response codes worth handling

| Code | Cause |
|---|---|
| 503 + `Retry-After` | Model-load failure cooldown; model still cold-loading (`LOCALAI_MODEL_LOAD_WAIT`); admission rejection on `limits.max_concurrent` |
| 503, `{"error":"agent pool is starting, please retry shortly"}` | Agent routes before the pool finishes starting |
| 429 + `Retry-After` | Quota exceeded (auth DB only) |
| 409 | Embedding-dimension mismatch when uploading to an agent collection |
| 404 with `{"error":{"code":404,"message":"Resource not found","type":""}}` | The standard miss shape (tested 2026-08-17) |

## Upstream references

- [`core/http/app.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/app.go) — route group registration order, swagger annotations, static/SPA surface. Validated against v4.8.2.
- [`core/http/routes/openai.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/openai.go) — OpenAI routes, prefixed and un-prefixed, per-route middleware. Validated against v4.8.2.
- [`core/http/routes/anthropic.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/anthropic.go) — `/v1/messages`, `max_tokens` requirement. Validated against v4.8.2.
- [`core/http/routes/ollama.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/ollama.go) — Ollama surface and the root-endpoint flag. Validated against v4.8.2.
- [`core/http/routes/openresponses.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/openresponses.go) — Responses routes and interceptor ordering. Validated against v4.8.2.
- [`core/http/endpoints/localai/agent_responses.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/endpoints/localai/agent_responses.go) — agent detection, non-streaming reply, distributed last-message behaviour. Validated against v4.8.2.
- [`core/http/routes/localai.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/localai.go) — administration, MCP, monitoring, discovery routes. Validated against v4.8.2.
- [`core/http/auth/middleware.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/auth/middleware.go) — credential extraction, exempt and always-authenticated path lists. Validated against v4.8.2.
- Swagger path count, tag distribution, `/api/agents` absence from the spec, 404 body shape: observed 2026-08-17 on `localai/localai:latest` reporting `v4.8.2 (5ff25d9d)`.
