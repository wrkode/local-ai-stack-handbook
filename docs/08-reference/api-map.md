# API map

Every HTTP endpoint the three projects serve, in one place. Paths are grouped by project and then
by purpose. Swagger is not a complete map of LocalAI — `/api/agents*` is live and absent from it.

> **Source caveat.** The LocalAI clone read for this chapter is `master` at `c29c99e1`
> (2026-08-17), ten days after the v4.8.2 tag (2026-08-07). LocalAI line citations are from that
> tree; the delta to the tag was not diffed. LocalAGI is `v2.9.0-3-g9a6b32f`; LocalRecall is
> exactly `v0.6.4`.

## Auth column legend (LocalAI)

| Value | Meaning |
|---|---|
| `public` | In the default `PathWithoutAuth` prefix list or explicitly registered no-auth (`core/config/application_config.go:307-333`) |
| `standard` | Any authenticated principal. **With no auth DB and no static keys the whole middleware passes through** (`core/http/auth/middleware.go:42-48`) |
| `admin` | `adminMiddleware`. **Degrades to `auth.NoopMiddleware()` when there is no auth DB** (`core/http/app.go:463`) — every admin route is open in no-auth mode |
| `feature` | `auth.RequireFeature(...)` on top of `standard` |
| `node token` | Bearer registration token, constant-time compare; **fails open when the token is empty** (`core/http/routes/nodes.go:137-158`) |

LocalAGI and LocalRecall have a single auth state each: **fully open unless `LOCALAGI_API_KEYS` /
`API_KEYS` is set, then every route including static assets requires a key.** Neither exempts a
health path, because neither has one.

---

# LocalAI v4.8.2

## Swagger and discovery

| Method | Path | Purpose | Auth | Notes |
|---|---|---|---|---|
| GET | `/swagger/*` | Swagger UI | `standard` | `core/http/routes/localai.go:36` |
| GET | `/swagger/doc.json` | OpenAPI document | `standard` | **111 paths**, `info.version` `2.0.0` — the spec version, stale against the v4.8.2 product version (`core/http/app.go:129`). Observed 2026-08-17 |
| GET | `/openapi.json`, `/swagger.json` | — | — | **404.** `/swagger/doc.json` is the only spec path. Observed |
| GET | `/version` | Build version + commit | `public` | `localai.go:278` |
| GET | `/.well-known/localai.json` | Agent discovery document | `public` | `localai.go:285` |
| GET | `/api/instructions`, `/api/instructions/:name` | Agent-facing instructions | **explicitly no-auth** | `localai.go:418-419` |
| GET | `/api/features` | Feature flags | `standard` | `localai.go:421` |

Swagger path counts by tag, from the running instance (tested 2026-08-17): monitoring 16, audio 11,
backends 11, agent-jobs 11, models 9, inference 7, face-recognition 6, voice-recognition 6, config 6,
Nodes 5, audio+voice-profiles 4, branding 4, tokenize 4, images 3, 3d 2, p2p 2, pii 2, instructions 2,
embeddings 1, mcp 1, rerank 1, router 1, moderation 1, detection/depth/video 3.

## Health

| Method | Path | Purpose | Auth | Notes |
|---|---|---|---|---|
| GET | `/healthz` | Liveness — always 200, empty body | `public` | `core/http/routes/health.go:23-25`. Independent of model loading by design |
| GET | `/readyz` | Readiness — 200, or 503 `{"status":"starting","reason":"startup preload in progress"}` | `public` | `health.go:31-39` |

Registered **before** the auth middleware (`core/http/app.go:341`). There is no `/health`, `/ready`,
`/v1/healthz` or `/v1/readyz`.

**Trap:** during a long startup preload the listener has not bound yet, so probes get
**connection refused, not 503** (`core/cli/run.go:754,775,807`). The 503 path is reachable only
under systemd socket activation.

## Inference — OpenAI-compatible

Every row is registered twice, with and without the `/v1` prefix, unless noted.

| Method | Path | Purpose | Auth | Notes |
|---|---|---|---|---|
| POST | `/v1/chat/completions`, `/chat/completions` | Chat completions | `standard` | `core/http/routes/openai.go:97-98` |
| POST | `/v1/completions`, `/completions`, `/v1/engines/:model/completions` | Legacy completions | `standard` | `openai.go:140-142` |
| POST | `/v1/edits`, `/edits` | Legacy edits | `standard` | `openai.go:118-119` |
| POST | `/v1/embeddings`, `/embeddings`, `/v1/engines/:model/embeddings` | Embeddings | `standard` | `openai.go:177-179`. **No `usage` object in the response** — observed; `StampUsage(c, model, 0, 0)` at `embeddings.go:112` |
| POST | `/v1/moderations`, `/moderations` | Moderation | `standard` | `openai.go:155-156` |
| GET | `/v1/models`, `/models` | List models | `standard` | `openai.go:277-278`. Pool agents are **not** listed |
| GET | `/v1/models/capabilities`, `/models/capabilities` | Per-model capabilities (LocalAI extension) | `standard` | `openai.go:283-284` |
| POST | `/v1/images/generations`, `/images/generations` | Image generation | `standard` | `openai.go:263-264` |
| POST | `/v1/images/inpainting`, `/images/inpainting` | Inpainting (extension) | `standard` | `openai.go:268-269` |
| POST | `/v1/images/upscale`, `/images/upscale` | Upscale (extension) | `standard` | `openai.go:273-274` |
| POST | `/v1/audio/transcriptions`, `/audio/transcriptions` | Speech to text | `standard` | `openai.go:197-198` |
| POST | `/v1/audio/speech`, `/audio/speech` | Text to speech | `standard` | `openai.go:242-243` |
| POST | `/v1/audio/diarization`, `/audio/diarization` | Speaker diarization (extension) | `standard` | `openai.go:214-215` |
| POST | `/v1/audio/classification`, `/audio/classification` | Sound classification (extension) | `standard` | `openai.go:231-232` |
| GET | `/v1/realtime` | Realtime session (WebSocket / WebRTC) | `standard` | `openai.go:34`. Needs `LOCALAI_WEBRTC_*` under NAT — see [ports](ports.md) |
| POST | `/v1/realtime/sessions` | Create realtime session | `standard` | `openai.go:35` |
| POST | `/v1/realtime/transcription_session` | Create transcription session | `standard` | `openai.go:36` |
| POST | `/v1/realtime/calls` | Realtime calls | `standard` | `openai.go:37` |

Chat carries the full per-route middleware pipeline: `ExposeNodeHeader` → `UsageMiddleware` →
`TraceMiddleware` → default-model filter → `SetModelAndConfig` → `RouteModel` → `AdmissionControl`
→ PII redaction (`openai.go:47-96`).

## Inference — other dialects

| Method | Path | Purpose | Auth | Notes |
|---|---|---|---|---|
| POST | `/v1/messages`, `/messages` | **Anthropic Messages API** | `standard` | `core/http/routes/anthropic.go:74,77`. Requires `max_tokens > 0` (`:135-137`); reads/echoes `x-request-id` as correlation ID |
| POST | `/api/chat` | Ollama chat | `standard` | `core/http/routes/ollama.go:42`. **Always generates a fresh correlation uuid, ignoring the inbound header** (`:109-110`) |
| POST | `/api/generate` | Ollama generate | `standard` | `ollama.go:60` |
| POST | `/api/embed`, `/api/embeddings` | Ollama embeddings | `standard` | `ollama.go:76-77` |
| GET/HEAD | `/api/tags` | Ollama model list | `standard` | `ollama.go:80-81` |
| POST | `/api/show` | Ollama show model | `standard` | `ollama.go:82` |
| GET | `/api/ps` | Ollama running models | `standard` | `ollama.go:83` |
| GET/HEAD | `/api/version` | Ollama version | `standard` | `ollama.go:84-85` |
| GET/HEAD | `/` | Ollama heartbeat | `public` | **Only when `LOCALAI_OLLAMA_API_ROOT_ENDPOINT=true`** — it collides with the web UI (`ollama.go:88-92`) |
| POST | `/v1/rerank` | Jina-compatible reranking | `standard` | `core/http/routes/jina.go:21`. **No un-prefixed alias** |
| POST | `/v1/text-to-speech/:voice-id` | ElevenLabs-compatible TTS | `standard` | `core/http/routes/elevenlabs.go:20` |
| POST | `/v1/sound-generation` | ElevenLabs-compatible sound generation | `standard` | `elevenlabs.go:26` |

## Responses API (Open Responses)

| Method | Path | Purpose | Auth | Notes |
|---|---|---|---|---|
| POST | `/v1/responses`, `/responses` | Create a response | `standard` | `core/http/routes/openresponses.go:56,59`. **Agent entry point** — see below |
| GET | `/v1/responses`, `/responses` | WebSocket mode | `standard` | `openresponses.go:63-64` |
| GET | `/v1/responses/:id`, `/responses/:id` | Retrieve a stored response | `standard` | `openresponses.go:68-69` |
| POST | `/v1/responses/:id/cancel`, `/responses/:id/cancel` | Cancel an in-flight response | `standard` | `openresponses.go:73-74` |

`AgentResponsesInterceptor` is the **first** middleware on the POST routes (`openresponses.go:47`).
If the request's `model` names a registered agent, the request is diverted into the agent runtime and
never reaches model-config resolution (`core/http/endpoints/localai/agent_responses.go:34`). Two
behaviours worth knowing: the agent path **never streams** — a `"stream": true` request still gets one
completed JSON body (`agent_responses.go:148`); and in distributed mode **only the last user message**
is forwarded (`:66-72,129`), whereas local mode passes the whole conversation.

This route group does **not** get `RouteModel`, `AdmissionControl` or the PII middleware that chat and
Anthropic get.

## Model administration and gallery

All `admin`, all skipped when `--disable-gallery-endpoint` (`core/http/routes/localai.go:41`).

| Method | Path | Purpose | Notes |
|---|---|---|---|
| POST | `/models/apply` | Install a model from a gallery | `localai.go:55`. **Asynchronous** — returns `{"uuid","status"}` immediately; jobs run one at a time. Observed |
| GET | `/models/jobs`, `/models/jobs/:uuid` | Install job status | `localai.go:60-61`. **`progress` is unreliable — poll `processed: true`.** Observed defect |
| POST | `/models/delete/:name` | Delete a model | `localai.go:56` |
| GET | `/models/available` | Gallery catalogue | `localai.go:58` |
| GET | `/models/galleries` | Configured galleries | `localai.go:59` |
| POST | `/models/import` | Import a model | `localai.go:79` |
| POST | `/models/import-uri` | Import by URI | `localai.go:82` |
| GET/POST | `/models/edit/:name` | Edit page / apply edit | `localai.go:53,85` |
| PUT | `/models/toggle-state/:name/:action` | Enable/disable | `localai.go:91` |
| PUT | `/models/toggle-pinned/:name/:action` | Pin/unpin (exempt from eviction) | `localai.go:94` |
| POST | `/models/reload` | Reload configs from disk | `localai.go:99` |
| GET | `/api/aliases` | Model alias map | `localai.go:88` |
| GET | `/import-model` | HTML import page | `localai.go:43` |
| GET | `/api/models/:id/load-status` | Live cold-load progress | `localai.go:163` — `standard`, not admin |

## Backend administration

All `admin`.

| Method | Path | Purpose | Notes |
|---|---|---|---|
| GET | `/backends` | Installed backends | `localai.go:70`. Empty on a clean instance — observed |
| GET | `/backends/available` | Installable backends | `localai.go:71` |
| GET | `/backends/known` | Known backend names | `localai.go:72` |
| GET | `/backends/galleries` | Backend galleries | `localai.go:73` |
| POST | `/backends/apply` | Install a backend (OCI artifact) | `localai.go:68` |
| GET | `/backends/jobs/:uuid` | Install job status | `localai.go:74` |
| POST | `/backends/delete/:name` | Uninstall | `localai.go:69` |
| GET | `/backends/upgrades` | Available upgrades | `localai.go:75` |
| POST | `/backends/upgrades/check` | Trigger an upgrade check | `localai.go:76` |
| POST | `/backends/upgrade/:name` | Upgrade one backend | `localai.go:77` |

## Inference primitives outside the OpenAI spec

| Method | Path | Usecase flag | Auth | Notes |
|---|---|---|---|---|
| POST | `/v1/detection` | `FLAG_DETECTION` | `standard` | `localai.go:103` |
| POST | `/v1/depth` | `FLAG_DEPTH` | `standard` | `localai.go:109` |
| POST | `/v1/face/verify`, `/analyze`, `/embed`, `/register`, `/identify` | `FLAG_FACE_RECOGNITION` | `standard` | `localai.go:118-130` |
| POST | `/v1/face/forget` | registry-only | `standard` | `localai.go:134` |
| POST | `/v1/voice/verify`, `/analyze`, `/embed`, `/register`, `/identify` | `FLAG_SPEAKER_RECOGNITION` | `standard` | `localai.go:140-152` |
| POST | `/v1/voice/forget` | registry-only | `standard` | `localai.go:156` |
| POST | `/tts` | `FLAG_TTS` | `standard` | `localai.go:177` |
| POST | `/audio/transformations`, `/audio/transform` | `FLAG_AUDIO_TRANSFORM` | `standard` | `localai.go:189-190` |
| GET | `/audio/transformations/stream` | — | `standard` | WebSocket, `localai.go:194` |
| POST | `/vad`, `/v1/vad` | `FLAG_VAD` | `standard` | `localai.go:200,205` |
| POST | `/video` | `FLAG_VIDEO` | `standard` | `localai.go:222` |
| POST | `/3d/generations` | `FLAG_3D` | `standard` | `localai.go:228`. **Registered un-prefixed** — the v4.8.0 release note claiming `/v1/3d/generations` is wrong |
| POST | `/3d/remesh` | `FLAG_3D` | `standard` | `localai.go:232-234`, 513 MB body limit |
| POST | `/v1/tokenize`, `/v1/detokenize` | `FLAG_TOKENIZE` | `standard` | `localai.go:436,442` |
| POST | `/api/score` | — | `admin` | `localai.go:276` |

## Vector stores (LocalAI's own `/stores` API)

Backed by the in-tree `local-store` backend. This is what LocalRecall's `VECTOR_ENGINE=localai`
talks to.

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `/stores/set` | `standard` | `localai.go:212` |
| POST | `/stores/get` | `standard` | `localai.go:214` |
| POST | `/stores/delete` | `standard` | `localai.go:213` |
| POST | `/stores/find` | `standard` | `localai.go:215` |

## Agents — `/api/agents` group

**Not present in the swagger document.** `GET /api/agents` returns 200 on a stock container
(observed: `{"actions":40,"agentCount":0,"agent_hub_url":"https://agenthub.localai.io","agents":null,"connectors":9,"statuses":{}}`).
The whole registration is a no-op unless `AgentPool.Enabled` (`core/http/routes/agents.go:13-15`);
`poolReadyMw` returns 503 `{"error":"agent pool is starting, please retry shortly"}` while the service
is still nil (`:18-27`). Group middleware: `poolReadyMw` + `auth.RequireFeature(FeatureAgents)`.

| Method | Path | Purpose | Auth | Notes |
|---|---|---|---|---|
| GET | `/api/agents` | List agents, statuses, action/connector counts, `agent_hub_url` | `feature` | `agents.go:31`; handler `:92`. Admins may pass `?all_users=true` |
| POST | `/api/agents` | Create an agent (201) | `feature` | handler `:128` |
| POST | `/api/agents/import` | Import — multipart `file` or raw JSON (201) | `feature` | handler `:364` |
| GET | `/api/agents/config/metadata` | Config-field metadata driving the UI form | `feature` | handler `:343` |
| GET | `/api/agents/:name` | `{"active": bool}`; 404 if not in the caller's list | `feature` | handler `:143` |
| PUT | `/api/agents/:name` | Update | `feature` | handler `:158` |
| DELETE | `/api/agents/:name` | Delete | `feature` | handler `:177` |
| GET | `/api/agents/:name/config` | Full agent config JSON | `feature` | handler `:189` |
| PUT | `/api/agents/:name/pause` | Pause | `feature` | handler `:202` |
| PUT | `/api/agents/:name/resume` | Resume | `feature` | handler `:213` |
| GET | `/api/agents/:name/status` | Reasoning/action/result history, newest first | `feature` | handler `:224` |
| GET | `/api/agents/:name/observables` | Raw observable JSON | `feature` | handler `:257` |
| DELETE | `/api/agents/:name/observables` | Clear observables | `feature` | handler `:277` |
| POST | `/api/agents/:name/chat` | `{"message": "..."}` — **async, returns 202 + `message_id`**; the reply arrives over SSE | `feature` | handler `:289` |
| GET | `/api/agents/:name/sse` | Agent event stream | `feature` | handler `:318`. Local SSE manager first, then distributed bridge, else 404 |
| GET | `/api/agents/:name/sse/distributed` | Distributed-only SSE bridge | `feature` | Registered outside the group at `core/http/app.go:573` |
| GET | `/api/agents/:name/export` | JSON as a `Content-Disposition` attachment | `feature` | handler `:350` |
| GET | `/api/agents/:name/files` | Serve from the agent outputs dir | `feature` | handler `:455`; path is symlink-resolved and confined to `OutputsDir()/<userID>`, else 403 (`:465-481`) |
| GET | `/api/agents/actions` | List built-in actions | `feature` | handler `:405`. A stock v4.8.2 reports **40** — observed |
| POST | `/api/agents/actions/:name/definition` | Parameter schema from `{"config": {...}}` | `feature` | handler `:414` |
| POST | `/api/agents/actions/:name/run` | Out-of-band action run with `{"config","params"}` | `feature` | handler `:434` |

`?user_id=` is honoured **only** for admins or `auth.ProviderAgentWorker` service accounts
(`agents.go:70-90`).

## Agents — `/api/agents/skills` group

Middleware `poolReadyMw` + `RequireFeature(FeatureSkills)` (`core/http/routes/agents.go:56-69`).
Handlers in `core/http/endpoints/localai/agent_skills.go`.

| Method | Path | Purpose | Handler |
|---|---|---|---|
| GET | `/api/agents/skills` | List skills (admin `all_users` aggregation at `:72-97`) | `:58` |
| GET | `/api/agents/skills/config` | Skills service config | `:105` |
| GET | `/api/agents/skills/search` | Search, `?q` | `:115` |
| POST | `/api/agents/skills` | Create (409 on conflict) | `:130` |
| GET | `/api/agents/skills/:name` | Get one | `:159` |
| PUT | `/api/agents/skills/:name` | Update | `:173` |
| DELETE | `/api/agents/skills/:name` | Delete | `:201` |
| GET | `/api/agents/skills/:name/export` | Export archive | `:214` |
| POST | `/api/agents/skills/import` | Import (multipart) | `:231` |
| GET | `/api/agents/skills/:name/resources` | List resources | `:260` |
| GET | `/api/agents/skills/:name/resources/*` | Get a resource | `:300` |
| POST | `/api/agents/skills/:name/resources` | Create a resource (multipart) | `:323` |
| PUT | `/api/agents/skills/:name/resources/*` | Update a resource | `:353` |
| DELETE | `/api/agents/skills/:name/resources/*` | Delete a resource | `:372` |

Skills sourced from git are read-only and cannot be updated
(`core/services/skills/filesystem.go:119-121`).

## Agents — `/api/agents/git-repos` group

Same middleware as skills (`core/http/routes/agents.go:73-77`), same handler file.

| Method | Path | Purpose | Handler |
|---|---|---|---|
| GET | `/api/agents/git-repos` | List configured repos | `:387` |
| POST | `/api/agents/git-repos` | Add a repo | `:401` |
| PUT | `/api/agents/git-repos/:id` | Update | `:421` |
| DELETE | `/api/agents/git-repos/:id` | Remove | `:445` |
| POST | `/api/agents/git-repos/:id/sync` | Sync — 202 `{"status":"syncing"}` | `:461` |
| POST | `/api/agents/git-repos/:id/toggle` | Enable/disable | `:474` |

## Agents — `/api/agents/collections` group

Middleware `poolReadyMw` + `RequireFeature(FeatureCollections)`
(`core/http/routes/agents.go:82-92`). Handlers in
`core/http/endpoints/localai/agent_collections.go`. **All user-scoped.** This is LocalAI's
re-exposure of LocalRecall through LocalAGI's in-process bridge — the paths are close to, but not
identical with, LocalRecall's own (LocalAI adds `?user_id=` scoping and a separate raw-file route).

| Method | Path | Purpose | Handler |
|---|---|---|---|
| GET | `/api/agents/collections` | List collections | `:12` |
| POST | `/api/agents/collections` | Create (201) | `:52` |
| POST | `/api/agents/collections/:name/upload` | Multipart `file`; returns `key`. **409 on embedding-dimension mismatch** (`:88-108`) | `:69` |
| GET | `/api/agents/collections/:name/entries` | List entries | `:115` |
| GET | `/api/agents/collections/:name/entries/:entry` | Extracted text + chunk count | `:133` |
| GET | `/api/agents/collections/:name/entries/:entry/raw` | Original binary | `:261` |
| POST | `/api/agents/collections/:name/search` | `{query, max_results}` | `:156` |
| POST | `/api/agents/collections/:name/reset` | Wipe | `:181` |
| DELETE | `/api/agents/collections/:name/entry/delete` | Delete one entry | `:195` |
| POST | `/api/agents/collections/:name/sources` | Add `{url, update_interval}` | `:219` |
| DELETE | `/api/agents/collections/:name/sources` | Remove a source | `:243` |
| GET | `/api/agents/collections/:name/sources` | List sources | `:281` |

**This group is called by LocalAI itself over loopback HTTP.** The native agent executor's knowledge
lookup does `POST http://127.0.0.1:8080/api/agents/collections/<agent>/search`
(`core/services/agents/knowledge.go:81-86`) — a real network hop into its own listener.

## Agent jobs — the singular `/api/agent/*` namespace

A **different** subsystem from `/api/agents` (note the singular). Cron- and webhook-driven tasks
producing jobs. Gated on `AgentJobService() != nil && !DisableMCP`
(`core/http/routes/localai.go:489`).

| Method | Path | Purpose | Handler |
|---|---|---|---|
| POST | `/api/agent/tasks` | Create a task (201 `{"id"}`) | `agent_jobs.go:42` |
| PUT | `/api/agent/tasks/:id` | Update | `:69` |
| DELETE | `/api/agent/tasks/:id` | Delete | `:96` |
| GET | `/api/agent/tasks` | List (admin `?all_users=true`) | `:117`. Returns `[]` on a clean instance — observed |
| GET | `/api/agent/tasks/:id` | Get one | `:167` |
| POST | `/api/agent/tasks/:name/execute` | Execute by name | `:370` |
| POST | `/api/agent/jobs/execute` | Execute by `TaskID` (201 `{job_id, status, url}`) | `:188` |
| GET | `/api/agent/jobs` | List, filters `task_id`/`status`/`limit` | `:253` |
| GET | `/api/agent/jobs/:id` | Get one | `:231` |
| POST | `/api/agent/jobs/:id/cancel` | Cancel | `:323` |
| DELETE | `/api/agent/jobs/:id` | Delete | `:345` |
| GET | `/api/agent/jobs/:id/progress` | SSE progress — **distributed mode only** | `core/http/app.go:570` |

## MCP

Skipped entirely when `--disable-mcp` (`core/http/routes/localai.go:449`).

| Method | Path | Purpose | Auth | Notes |
|---|---|---|---|---|
| POST | `/v1/mcp/chat/completions`, `/mcp/v1/chat/completions`, `/mcp/chat/completions` | Chat completions with MCP tool execution | `standard` | `localai.go:467-469`. **Streaming here is not OpenAI-compatible** — it emits extra state events (`localai.go:448`) |
| GET | `/v1/mcp/servers/:model` | Servers configured for a model | `standard` | `localai.go:472` |
| GET | `/v1/mcp/prompts/:model` | Prompts | `standard` | `localai.go:475` |
| POST | `/v1/mcp/prompts/:model/:prompt` | Fetch a prompt | `standard` | `localai.go:476` |
| GET | `/v1/mcp/resources/:model` | Resources | `standard` | `localai.go:479` |
| POST | `/v1/mcp/resources/:model/read` | Read a resource | `standard` | `localai.go:480` |
| GET/POST/OPTIONS | `/api/cors-proxy` | CORS proxy for the UI | `standard` | `localai.go:483-485` |

LocalAI also **hosts** an in-process MCP server, the "LocalAI Assistant" — a stock container logs
`tools=36 read_only=false` at startup (observed). Disable with `LOCALAI_DISABLE_ASSISTANT`.

## Monitoring, traces and logs

| Method | Path | Purpose | Auth | Notes |
|---|---|---|---|---|
| GET | `/metrics` | Prometheus text | **`admin`** | `localai.go:218`. Upstream `docs/content/features/authentication.md:185` lists this as user-accessible — **the docs are wrong**. Skipped when `LOCALAI_DISABLE_METRICS_ENDPOINT` |
| GET | `/system` | Loaded models + backends | `admin` | `localai.go:432` |
| GET | `/api/traces` | API exchange traces, `?limit&offset&full` | `admin` | `localai.go:253`. Records nothing unless `LOCALAI_ENABLE_TRACING=true` — observed empty on a stock container |
| GET | `/api/traces/summary` | `?hours` (def 24, max 168) | `admin` | `localai.go:254` |
| GET | `/api/traces/:id` | One trace | `admin` | `localai.go:255` |
| POST | `/api/traces/clear` | Clear | `admin` | `localai.go:257` |
| GET | `/api/backend-traces`, `/api/backend-traces/:id` | Backend-operation traces (24 event kinds) | `admin` | `localai.go:258-259` |
| POST | `/api/backend-traces/clear` | Clear | `admin` | `localai.go:260` |
| GET | `/api/backend-logs` | Models that have been loaded | `admin` | `localai.go:263`. **Standalone mode only.** This, not `/api/traces`, is where to look when a model fails to load |
| GET | `/api/backend-logs/:modelId` | Per-model `run.sh` stdout/stderr with stream separation | `admin` | `localai.go:264` |
| POST | `/api/backend-logs/:modelId/clear` | Clear | `admin` | `localai.go:265` |
| GET | `/ws/backend-logs/:modelId` | WebSocket variant | `admin` | `localai.go:266`. Not tested |
| GET | `/backend/monitor`, `/v1/backend/monitor` | Backend status via gRPC | `admin` | `localai.go:241,248`. **Broken for llama.cpp** — `code = Unimplemented`, then a fallback that looks up a `.gguf.bin` filename that cannot exist. Observed 500 |
| POST | `/backend/shutdown`, `/v1/backend/shutdown` | Stop a backend | `admin` | `localai.go:242,249` |
| POST | `/backend/load`, `/v1/backend/load` | Explicit warm-up | `admin` | `localai.go:246,250` |
| GET | `/api/usage` | Token usage for the caller, `?period=day\|week\|month\|all` | `standard` | `core/http/routes/usage.go:54`. Falls back to a synthetic local user when auth is off |
| GET | `/api/usage/all` | All users, `?period&user_id` | `admin` (403 otherwise) | `usage.go:89` |
| GET | `/api/middleware/status` | Middleware status | `standard` | `core/http/routes/middleware.go:32` |
| GET | `/api/router/status` | Router status | `standard` | `middleware.go:54` |
| GET | `/api/router/decisions` | Recorded routing decisions | `standard` | `middleware.go:77` |
| GET | `/api/router/cache/stats` | Router cache stats | `standard` | `middleware.go:116` |
| POST | `/api/router/decide` | Force a routing decision | `standard` | `middleware.go:148` |
| GET | `/api/middleware/proxy-ca.crt` | MITM proxy CA certificate | `standard` | `middleware.go:60` |

> `--disable-stats` / `LOCALAI_DISABLE_STATS` appears in a 503 error body from the usage routes
> (`usage.go:30-44`) but **no such flag or env var exists**. Do not document it.

## PII

| Method | Path | Purpose | Auth | Notes |
|---|---|---|---|---|
| GET | `/api/pii/events` | Audit log; filters `correlation_id`, `user_id`, `pattern_id`, `kind`, `origin`, `limit` | admin, enforced **in the handler** not by middleware | `core/http/routes/pii.go:46,52-54` |
| POST | `/api/pii/analyze` | Scan text | `standard` + `pii_filter` feature | `pii.go:81` |
| POST | `/api/pii/redact` | Redact text | `standard` + `pii_filter` feature | `pii.go:82` |

## Auth (`LOCALAI_AUTH`)

All under `/api/auth/`, which is **prefix-exempted from the global middleware**
(`core/http/auth/middleware.go:550-575`). Rate limited per IP: 5 attempts/min for auth endpoints,
60/min for OAuth/OIDC callbacks (`core/http/routes/auth.go:181-201`).

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/auth/status` | Whether auth is enabled and how |
| POST | `/api/auth/register` | Register |
| POST | `/api/auth/login` | Password login |
| POST | `/api/auth/token-login` | Token login |
| POST | `/api/auth/logout` | Logout |
| GET | `/api/auth/me` | Current user |
| GET | `/api/auth/quota` | Current quota |
| PUT | `/api/auth/profile` | Update profile |
| PUT | `/api/auth/password` | Change password |
| DELETE | `/api/auth/sessions` | Revoke sessions |
| GET | `/api/auth/github/login`, `/github/callback` | GitHub OAuth (registered only when configured) |
| GET | `/api/auth/oidc/login`, `/oidc/callback` | OIDC (registered only when configured) |
| POST/GET | `/api/auth/api-keys` | Issue / list named API keys |
| DELETE | `/api/auth/api-keys/:id` | Revoke |
| GET | `/api/auth/usage`, `/usage/sources` | Per-user usage |
| GET | `/api/auth/admin/features` | Feature matrix |
| GET | `/api/auth/admin/users` | List users |
| PUT | `/api/auth/admin/users/:id/role`, `/status`, `/password` | User administration |
| DELETE | `/api/auth/admin/users/:id` | Delete user |
| GET/PUT | `/api/auth/admin/users/:id/permissions` | Permissions |
| PUT | `/api/auth/admin/users/:id/models` | Model access |
| GET/PUT | `/api/auth/admin/users/:id/quotas` | Quotas |
| DELETE | `/api/auth/admin/users/:id/quotas/:quota_id` | Remove a quota |
| GET | `/api/auth/admin/usage`, `/usage/sources` | Cluster usage |
| POST/GET | `/api/auth/admin/invites` | Invites |
| DELETE | `/api/auth/admin/invites/:id` | Revoke an invite |

Line numbers: `core/http/routes/auth.go:125-1230`.

## Distributed mode — nodes

Both groups return 503 "distributed mode not enabled" when the registry is nil
(`core/http/routes/nodes.go:18-29`).

**Self-service**, group `/api/node`, auth = `node token`:

| Method | Path | Line |
|---|---|---|
| POST | `/api/node/register` | `:48` |
| POST | `/api/node/:id/heartbeat` | `:49` |
| POST | `/api/node/:id/drain` | `:50` |
| POST | `/api/node/:id/resume` | `:51` |
| POST | `/api/node/:id/deregister` | `:52` |
| GET | `/api/node/:id/models` | `:53` |
| DELETE | `/api/node/:id` | `:54` |

> `core/http/routes/nodes.go:35-38` carries an explicit `TODO(security)`: the shared registration
> token does not bind node identity, so a compromised worker can heartbeat, drain or deregister
> *other* nodes.

**Admin**, group `/api/nodes`, auth = `admin`:

| Method | Path | Line |
|---|---|---|
| GET | `/api/nodes` | `:72` |
| GET | `/api/nodes/models` | `:75` |
| GET/POST | `/api/nodes/scheduling` | `:78,80` |
| GET | `/api/nodes/scheduling/:model` | `:79` |
| DELETE | `/api/nodes/scheduling/:model` | `:81` |
| GET | `/api/nodes/:id` | `:83` |
| GET | `/api/nodes/:id/models` | `:84` |
| DELETE | `/api/nodes/:id` | `:85` |
| POST | `/api/nodes/:id/drain`, `/resume`, `/approve` | `:86-88` |
| GET | `/api/nodes/:id/backends` | `:91` |
| POST | `/api/nodes/:id/backends/install` (202 + jobID), `/upgrade`, `/delete` | `:92,96,97` |
| POST | `/api/nodes/:id/models/unload`, `/models/delete` | `:100-101` |
| GET | `/api/nodes/:id/backend-logs`, `/backend-logs/:modelId` | `:104-105` |
| GET/PUT/PATCH | `/api/nodes/:id/labels` | `:108-110` |
| DELETE | `/api/nodes/:id/labels/:key` | `:111` |
| PUT/DELETE | `/api/nodes/:id/max-replicas-per-model` | `:116-117` |
| PUT/DELETE | `/api/nodes/:id/vram-budget` | `:122-123` |
| GET (WS) | `/ws/nodes/:id/backend-logs/:modelId` | `:126` |

## Fine-tuning and quantization

LocalAI-specific, **not** OpenAI's fine-tuning API shape.

| Method | Path (group `/api/fine-tuning`) | Line |
|---|---|---|
| GET | `/backends` | `finetuning.go:32` |
| POST/GET | `/jobs` | `:33-34` |
| GET | `/jobs/:id` | `:35` |
| POST | `/jobs/:id/stop` | `:36` |
| DELETE | `/jobs/:id` | `:37` |
| GET | `/jobs/:id/progress`, `/checkpoints`, `/download` | `:38,39,41` |
| POST | `/jobs/:id/export` | `:40` |
| POST | `/datasets` | `:42` |

Group `/api/quantization` mirrors it: `GET /backends` (`quantization.go:32`), `POST|GET /jobs`
(`:33-34`), `GET /jobs/:id` (`:35`), `POST /jobs/:id/stop` (`:36`), `DELETE /jobs/:id` (`:37`),
`GET /jobs/:id/progress` (`:38`), `POST /jobs/:id/import` (`:39`), `GET /jobs/:id/download` (`:40`).

## P2P and branding

| Method | Path | Purpose | Auth | Line |
|---|---|---|---|---|
| GET | `/api/p2p` | P2P peer view | `admin` | `localai.go:270` |
| GET | `/api/p2p/token` | Network token | `admin` | `localai.go:271` |
| GET | `/api/branding` | Branding config | `public` (prefix-exempt) | `ui_api.go:1840` |
| GET/POST/DELETE | `/branding/asset/:kind` | Branding assets | route-level `admin` only | `ui_api.go:1841-1843`. **The `/api/branding` prefix exemption also exempts `POST/DELETE /api/branding/asset/:kind` from the global middleware** (`core/config/application_config.go:315-331`) |

## Web UI JSON API and static surface

`RegisterUIAPIRoutes` (`core/http/routes/ui_api.go:123`) is registered only when the web UI is
enabled. It adds roughly 40 further `/api/*` paths driving the React SPA — operations, model and
backend management, settings, VRAM estimates, P2P views, branding. They are UI plumbing rather than
a stable integration surface; the authoritative list is the registration block at
`ui_api.go:126-1843`. The load-bearing one for operators is:

| Method | Path | Purpose | Line |
|---|---|---|---|
| GET/POST | `/api/settings` | Read/write `runtime_settings.json` | `ui_api.go:1832-1833` |
| GET | `/api/resources` | Host resource inventory | `ui_api.go:1804` |
| GET | `/api/operations` | Long-running operation list | `ui_api.go:126` |

Static: `GET /favicon.svg` (`app.go:348`), `/static` (`:362`), `/generated-audio`,
`/generated-images`, `/generated-videos`, `/generated-3d` (`:382-385`), `/app` and `/app/*` React SPA
(`:635-636`), `GET /` → 301 `/app` (`:649`), `/browse` → 301 (`:654,657`), `/assets/*` (1-year
immutable cache, `:691`), `/locales/*` (5-min cache, `:692`).

---

# LocalAGI v2.9.0

45 routes across `webui/routes.go:38-215` and `webui/collections_handlers.go:73-83`. One Fiber app,
no groups, no prefix, **no CORS middleware, no request-ID middleware, no access log**.

> **There is exactly ONE OpenAI-compatible route: `POST /v1/responses`.** A repo-wide grep for `/v1`
> in `*.go` yields only that route, its SDK counterpart, and two unrelated outbound URLs. There is no
> `/v1/chat/completions`, no `/v1/models`, no `/v1/completions`, no `/v1/embeddings`.

> **There is no health, readiness or metrics endpoint.** None of `/health`, `/healthz`, `/readyz`,
> `/ready`, `/ping`, `/api/status`, `/metrics` exists. Use `/app` for liveness and `/api/agents` for
> readiness. LocalAGI's own e2e test probes `/readyz` and asserts only on transport error, so a 404
> passes — the test does not prove the route exists, and it does not
> (`tests/e2e/e2e_test.go:23,51`).

## OpenAI-compatible

| Method | Path | Purpose | Notes |
|---|---|---|---|
| POST | `/v1/responses` | Responses API | `webui/routes.go:83` → `webui/app.go:575`. **`model` is the agent name, not a model id** (`app.go:591,604`). **Streaming is not implemented** — `stream` is parsed and never read. **`usage` is hardcoded to zeros** (`app.go:567-571`). Errors are HTTP 500 with a `ResponseBody{Error}`, not the OpenAI error envelope |

Conversation chaining uses an in-memory `ConversationTracker` with a TTL from
`LOCALAGI_CONVERSATION_DURATION`, defaulting to 1h on a parse error (`webui/options.go:42-50`).
Continuing a thread with `previous_response_id` and no new input returns **400**
(`app.go:598-602`).

## Agents

| Method | Path | Purpose | Registration |
|---|---|---|---|
| GET | `/api/agents` | List agents + counts + statuses | `routes.go:103` |
| POST | `/api/agent/create` | Create | `routes.go:70` |
| GET | `/api/agent/:name` | `{"active": !paused}` | `routes.go:125` |
| DELETE | `/api/agent/:name` | Delete | `routes.go:71` |
| PUT | `/api/agent/:name/pause` | Pause | `routes.go:72` |
| PUT | `/api/agent/:name/start` | Resume | `routes.go:73` |
| GET/PUT | `/api/agent/:name/config` | Get / update config (update triggers `RecreateAgent`) | `routes.go:86-87` |
| GET | `/api/agent/:name/status` | Action history | `routes.go:141` |
| GET | `/api/agent/:name/observables` | Observable trace history (500-entry ring) | `routes.go:166` |
| DELETE | `/api/agent/:name/observables` | Clear | `routes.go:182` |
| POST | `/api/chat/:name` | Send a message — **async, returns 202**, reply over SSE | `routes.go:75` |
| GET | `/api/notify/:name` | Notify — **registered as GET with a form body** | `routes.go:68` |
| POST | `/api/agent/group/generateProfiles` | LLM-generate a set of agent profiles | `routes.go:99` |
| POST | `/api/agent/group/create` | Instantiate a group | `routes.go:100` |
| GET | `/api/agent/config/metadata` | Config-field metadata | `routes.go:90` |
| GET | `/api/meta/agent/config` | **Same handler, alias.** Only this one is in the README | `routes.go:93` |
| POST | `/settings/import` | Import an agent (multipart `file`) | `routes.go:192` |
| GET | `/settings/export/:name` | Export an agent | `routes.go:193` |

## Actions

| Method | Path | Purpose | Registration |
|---|---|---|---|
| GET | `/api/actions` | List registered actions | `routes.go:97` |
| POST | `/api/action/:name/definition` | Parameter schema | `routes.go:95` |
| POST | `/api/action/:name/run` | Execute directly — **200 s timeout** (`app.go:498`) | `routes.go:96` |

## SSE

| Method | Path | Purpose | Registration |
|---|---|---|---|
| GET | `/sse/:name` | Per-agent event stream with history replay | `routes.go:58-66` |

Events: `json_message`, `json_message_status`, `json_error` from `Chat`; `status`, `hud`,
`stream_event` from the pool. The `hud` goroutine pushes **once per second, forever, with no exit
condition** (`core/state/pool.go:692-699`) — a leak on agent restart.

## Skills — 21 routes

Registered unconditionally at `webui/routes.go:196-215`; every one returns **503** via
`skillsUnavailable` when `config.SkillsService == nil` (`skills_handlers.go:69-71`).

| Method | Path | Handler |
|---|---|---|
| GET | `/api/skills/config` | `:89` |
| GET | `/api/skills` | `:97` |
| GET | `/api/skills/search` | `:121` |
| POST | `/api/skills` | `:162` |
| GET | `/api/skills/export/*` | `:335` |
| POST | `/api/skills/import` | `:366` |
| GET | `/api/skills/:name` | `:145` |
| PUT | `/api/skills/:name` | `:238` |
| DELETE | `/api/skills/:name` | `:304` |
| GET | `/api/skills/:name/resources` | `:415` |
| GET | `/api/skills/:name/resources/*` | `:457` |
| POST | `/api/skills/:name/resources` | `:490` |
| PUT | `/api/skills/:name/resources/*` | `:537` |
| DELETE | `/api/skills/:name/resources/*` | `:574` |
| GET | `/api/git-repos` | `:606` |
| POST | `/api/git-repos` | `:634` |
| PUT | `/api/git-repos/:id` | `:698` |
| DELETE | `/api/git-repos/:id` | `:748` |
| POST | `/api/git-repos/:id/sync` | `:788` |
| POST | `/api/git-repos/:id/toggle` | `:835` |

## Collections — 11 routes

`webui/collections_handlers.go:73-83`. **These paths deliberately mirror the LocalRecall HTTP
contract**, so LocalAGI is a drop-in LocalRecall server for collection operations. Same
`{success, message, data, error}` envelope and the same five error codes. The backing store is
chosen at `webui/routes.go:218-226`: HTTP client when `LOCALAGI_LOCALRAG_URL` is set, otherwise the
in-process LocalRecall library.

| Method | Path | Handler |
|---|---|---|
| POST | `/api/collections` | `:99` |
| GET | `/api/collections` | `:117` |
| POST | `/api/collections/:name/upload` | `:130` |
| GET | `/api/collections/:name/entries` | `:162` |
| GET | `/api/collections/:name/entries/*` | `:181` |
| POST | `/api/collections/:name/search` | `:216` |
| POST | `/api/collections/:name/reset` | `:244` |
| DELETE | `/api/collections/:name/entry/delete` | `:260` |
| POST | `/api/collections/:name/sources` | `:286` |
| DELETE | `/api/collections/:name/sources` | `:315` |
| GET | `/api/collections/:name/sources` | `:336` |

Note LocalAGI's entries route is `entries/*` (wildcard) where LocalRecall's is `entries/:entry`.

## Static / UI

| Method | Path | Purpose | Registration |
|---|---|---|---|
| GET | `/` | 302 → `/app` | `routes.go:38` |
| USE | `/app` | Embedded React SPA | `routes.go:42-45` |
| GET | `/app/*` | SPA fallback | `routes.go:48` |
| USE | `/public` | Embedded static assets | `webui/app.go:60-65` |
| GET | `/login` | 401 + redirect `/app` | `routes.go:77` |

## MCP routes

**None.** LocalAGI is an MCP *client* only.

## Auth caveat

The key-auth middleware is installed only when `LOCALAGI_API_KEYS` is non-empty
(`webui/routes.go:30-36`), and its `Next` returns `false` unconditionally (`:260`) — **no path is
exempt**, including `/`, `/app` and `/sse/*`. Any probe must carry `Authorization: Bearer`. Keys are
read from `Authorization` (scheme `Bearer`), `x-api-key`, `xi-api-key`, and the `token` cookie.
Failure renders a **401 with an HTML login page**, not JSON.

---

# LocalRecall v0.6.4

**12 API routes plus 2 static handlers. That is the entire surface.** All under `/api/collections`;
there is no version prefix.

## Response envelope

Every JSON handler returns (`routes.go:36-48`):

```json
{ "success": true, "message": "…", "data": { }, "error": { "code": "…", "message": "…", "details": "…" } }
```

Error codes (`routes.go:51-57`): `NOT_FOUND`, `INVALID_REQUEST`, `INTERNAL_ERROR`, `UNAUTHORIZED`,
`CONFLICT`. **`CONFLICT` is declared and never used.**

Two handlers bypass the envelope: `GET /api/collections/:name/entries/:entry/raw` returns raw file
bytes, and the two static routes return files.

## Routes

| Method | Path | Purpose | Success | Notes |
|---|---|---|---|---|
| POST | `/api/collections` | Create a collection | **201** `{name, created_at}` | `routes.go:192-224`. **502 `"Vector backend unavailable"`** if the engine cannot be constructed. **No name validation at all** — an empty name is accepted and produces `collection-.json` |
| GET | `/api/collections` | List collections | 200 `{collections, count}` | `routes.go:473-480`. Reads the **filesystem** (`ListAllCollections`), so it lists collections whose engine failed to initialise. This is the project's own readiness probe (`Makefile:185`) |
| POST | `/api/collections/:name/upload` | Ingest a file | 200 `{filename, collection, key, created_at}` | `routes.go:405-470`. `multipart/form-data`, field **`file`**. `key` is the `uuid/filename` index key. **No raw-text endpoint exists** despite `README.md:22` |
| GET | `/api/collections/:name/entries` | List entries | 200 `{collection, entries, keys, count}` | `routes.go:320-342`. `keys` are full `uuid/filename`; `entries` are basenames, kept for backward compatibility |
| GET | `/api/collections/:name/entries/:entry` | Extracted text | 200 `{collection, entry, content, chunk_count}` | `routes.go:345-378`. Re-extracts from disk rather than concatenating chunks, to avoid duplicated overlap. **501** when the type is unsupported; **404** when the entry is unknown. Error matching is `strings.Contains` on the message — brittle |
| GET | `/api/collections/:name/entries/:entry/raw` | Original binary | 200, raw bytes | `routes.go:381-402`. Not the JSON envelope |
| POST | `/api/collections/:name/search` | Similarity search | 200 `{query, max_results, results, count}` | `routes.go:279-318`. **`max_results` defaults to 5 if the collection has ≥5 documents, else 1** — counted in *documents*, so an unspecified query against one 500-page PDF returns 1 chunk. No server-side cap. **Result keys are capitalised** (`ID`, `Metadata`, `Embedding`, `Content`, `Similarity`) because `types.Result` has no JSON tags |
| POST | `/api/collections/:name/reset` | Wipe | 200 `{collection, reset_at}` | `routes.go:257-277`. **Reset is effectively delete** — it removes the state JSON and drops the collection from the in-memory map, so it vanishes from `GET /api/collections`. There is no delete-collection endpoint |
| DELETE | `/api/collections/:name/entry/delete` | Remove one entry | 200 `{deleted_entry, remaining_entries, entry_count}` | `routes.go:226-255`. Body on a DELETE: `{"entry": "..."}`. Note the singular `entry/delete` path shape, inconsistent with the plural `entries` above |
| POST | `/api/collections/:name/sources` | Register an external source | 200 `{collection, url, update_interval}` | `routes.go:483-520`. `update_interval` is in **minutes**, defaulting to 60 when `< 1` |
| DELETE | `/api/collections/:name/sources` | Remove an external source | 200 `{collection, url}` | `routes.go:523-546`. **Does not call `lookupCollection`** — an unknown collection returns 500, not 404 |
| GET | `/api/collections/:name/sources` | List external sources | 200 `{collection, sources, count}` | `routes.go:549-577`. Reports only `url`, `update_interval`, `last_update` — a source failing for a week looks healthy apart from a stale timestamp |

## Static handlers

| Method | Path | Purpose | Notes |
|---|---|---|---|
| GET | `/` | Embedded web UI | `static.go:30` |
| GET | `/static/*` | Embedded UI assets | `static.go:31`. The UI loads Alpine.js, SweetAlert2, Tailwind and Font Awesome **from public CDNs** — it does not render offline |

## What LocalRecall does not have

No health endpoint, no `/metrics`, no `/version`, no pagination, no PUT/update on anything, no
delete-collection, and no raw-text ingestion.

## Auth caveat

The bearer middleware is installed globally (`e.Use`) only when `API_KEYS` is non-empty
(`routes.go:158-176`), with **no path skipper** — `/`, `/static/*` and every `/api/*` route are
gated. Keys come from the `Authorization` header **only**; the `Bearer ` prefix is stripped
unconditionally, so **a bare key with no prefix also works**. Failure is a 401 with a JSON error
body.

---

# Un-prefixed aliases and the `/v1` inconsistency

LocalAI registers most OpenAI-compatible inference routes **twice**, with and without `/v1`:

| Prefixed | Un-prefixed | Source |
|---|---|---|
| `/v1/chat/completions` | `/chat/completions` | `core/http/routes/openai.go:97-98` |
| `/v1/embeddings` | `/embeddings` | `openai.go:177-178` |
| `/v1/completions` | `/completions` | `openai.go:140-141` |
| `/v1/edits` | `/edits` | `openai.go:118-119` |
| `/v1/moderations` | `/moderations` | `openai.go:155-156` |
| `/v1/models` | `/models` | `openai.go:277-278` |
| `/v1/responses` | `/responses` | `openresponses.go:56,59` |
| `/v1/messages` | `/messages` | `anthropic.go:74,77` |
| `/v1/audio/*`, `/v1/images/*`, `/v1/vad`, `/v1/backend/*` | `/audio/*`, `/images/*`, `/vad`, `/backend/*` | `openai.go`, `localai.go` |

**Exceptions that have no un-prefixed alias:** `/v1/rerank` (`jina.go:21`),
`/v1/text-to-speech/:voice-id` and `/v1/sound-generation` (`elevenlabs.go:20,26`), and the
`/v1/face/*`, `/v1/voice/*`, `/v1/detection`, `/v1/depth`, `/v1/tokenize`, `/v1/detokenize` family.
Conversely `/3d/generations`, `/3d/remesh`, `/tts`, `/video`, `/stores/*` and `/system` exist
**only** un-prefixed.

## Why this matters: cogito concatenates without a version segment

cogito's LocalAI client stores `strings.TrimRight(baseURL, "/")` and then builds the request URL as
`llm.baseURL + "/chat/completions"` (`cogito/clients/localai_client.go:57-63,305,435`). There is no
`/v1` in the concatenation and no path normalisation. LocalAGI passes its pool API URL through
unchanged (`core/state/pool.go:338-343,401,833`), so the documented
`LOCALAGI_LLM_API_URL=http://localai:8080` produces requests to
**`http://localai:8080/chat/completions`**.

The same pattern appears in LocalRecall: go-openai builds `TrimRight(BaseURL,"/") + "/embeddings"`,
and both `LocalRecall/docker-compose.yml:46` and the README set
`OPENAI_BASE_URL=http://localai:8080` **without** `/v1`, yielding `POST /embeddings`.

Meanwhile LocalAI's own native agent executor **does** append `/v1`
(`core/services/agents/executor.go:92`), and LocalRecall's Postgres migration test sets
`cfg.BaseURL = srv.URL + "/v1"`.

| Consumer | Base URL as configured upstream | Resulting path |
|---|---|---|
| cogito via LocalAGI | `http://localai:8080` | `/chat/completions` |
| LocalRecall standalone | `http://localai:8080` | `/embeddings` |
| LocalAI native executor | derived, `/v1` appended | `/v1/chat/completions` |
| LocalRecall test harness | `<mock>/v1` | `/v1/embeddings` |

**The family works only because LocalAI serves both forms.** Substituting any strict
OpenAI-compatible server — including api.openai.com — requires a base URL that already ends in
`/v1`. Pointing LocalAGI or LocalRecall at a bare host of a non-LocalAI server produces 404s on
every call.

`OPENAI_BASE_URL` carries a second trap: `LocalRecall/main.go:61` overwrites go-openai's default
**unconditionally**, including with the empty string when the variable is unset, producing the bare
relative path `"/embeddings"`. It is effectively mandatory despite being presented as optional. See
[environment variables](environment-variables.md).

---

## Upstream references

- [LocalAI `core/http/app.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/app.go) — route-group registration order, middleware chain, static surface. Validated against v4.8.2 (read at master `c29c99e1`, 2026-08-17).
- [LocalAI `core/http/routes/openai.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/openai.go) — OpenAI-compatible routes and the `/v1` aliases.
- [LocalAI `core/http/routes/localai.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/localai.go) — gallery, backends, monitoring, MCP, agent-jobs routes.
- [LocalAI `core/http/routes/agents.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/agents.go) — the four agent route groups.
- [LocalAI `core/http/routes/openresponses.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/openresponses.go) — Responses API and the agent interceptor.
- [LocalAI `core/http/routes/health.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/health.go) — `/healthz`, `/readyz`.
- [LocalAI `core/http/routes/nodes.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/nodes.go) — distributed node routes and the `TODO(security)`.
- [LocalAI `core/http/auth/middleware.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/auth/middleware.go) — auth resolution order, exempt paths, `isAPIPath`.
- [LocalAGI `webui/routes.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/routes.go) — all 45 routes, auth middleware, `Next: return false`. Validated against v2.9.0.
- [LocalAGI `webui/collections_handlers.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/collections_handlers.go) — the 11 collection routes and the shared envelope.
- [LocalAGI `webui/app.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/app.go) — `POST /v1/responses` handler, zero usage, no streaming.
- [LocalRecall `routes.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/routes.go) — all 12 routes, the envelope, auth middleware. Validated against v0.6.4.
- [LocalRecall `static.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/static.go) — the two static handlers.
- [`github.com/mudler/cogito`](https://github.com/mudler/cogito/tree/6eece18a6bb6caf67cb2ebe02922288858bdf07a) `clients/localai_client.go` — `baseURL + "/chat/completions"`. Commit read 2026-07-21.
- [LocalAI release v4.8.2](https://github.com/mudler/LocalAI/releases/tag/v4.8.2), [LocalAGI v2.9.0](https://github.com/mudler/LocalAGI/releases/tag/v2.9.0), [LocalRecall v0.6.4](https://github.com/mudler/LocalRecall/releases/tag/v0.6.4) — validated 2026-08-17.
- Swagger path count, `/api/agents` presence, `/backend/monitor` failure, empty traces: observed on `localai/localai:latest` (`v4.8.2`, digest `df2919064853`), 2026-08-17.
