# OpenAI compatibility

"OpenAI-compatible" is the property that makes this stack substitutable: point an existing client
at LocalAI and it works. It is also a claim with edges, and the edges are where integrations
break.

This page maps the live surface, states where the shapes diverge, and says which divergences will
break client code.

## The surface, enumerated

LocalAI v4.8.2 serves **111 documented paths**, of which **39 are under `/v1`**. Read from a live
host's `/swagger/doc.json`:

| Group | Paths |
|---|---|
| `/v1/*` | 39 |
| `/api/*` | 39 |
| `/backends/*` | 10 |
| `/models/*` | 6 |
| `/audio/*`, `/backend/*` | 3 each |
| `/3d/*` | 2 |
| `/metrics`, `/system`, `/tts`, `/vad`, `/video`, `/branding`, `/ws`, `/tokenMetrics` | 1 each |

The `/v1` surface splits three ways, and the split is the useful mental model:

### Genuinely OpenAI-shaped

| Path | Note |
|---|---|
| `/v1/chat/completions` | the workhorse; streaming works |
| `/v1/completions` | legacy completions |
| `/v1/embeddings` | 384 dims on the reference model |
| `/v1/models` | the only reliable "is it usable" check |
| `/v1/moderations` | |
| `/v1/edits` | deprecated by OpenAI, still here |
| `/v1/images/generations` | |
| `/v1/audio/speech`, `/v1/audio/transcriptions` | TTS and Whisper |
| `/v1/responses`, `/v1/responses/{id}`, `/v1/responses/{id}/cancel` | see below |

### Another vendor's shape

| Path | Note |
|---|---|
| `/v1/messages` | **Anthropic** Messages API |

So LocalAI is not only OpenAI-compatible. Worth knowing if you have an Anthropic SDK to hand.

### Beyond OpenAI entirely

Twenty-odd paths with no OpenAI equivalent, which is where the "compatible" framing stops being
useful:

| Area | Paths |
|---|---|
| Reranking | `/v1/rerank` |
| Tokenisation | `/v1/tokenize`, `/v1/detokenize`, `/v1/tokenMetrics` |
| Model introspection | `/v1/models/capabilities` |
| Vision | `/v1/depth`, `/v1/detection` |
| Faces | `/v1/face/{register,identify,verify,embed,analyze,forget}` |
| Voices | `/v1/voice/{register,identify,verify,embed,analyze,forget}` |
| Audio | `/v1/audio/classification`, `/v1/audio/diarization`, `/v1/sound-generation` |
| TTS by voice | `/v1/text-to-speech/{voice-id}` |
| Images | `/v1/images/inpainting`, `/v1/images/upscale` |
| MCP-enabled chat | `/v1/mcp/chat/completions` |

A client written against OpenAI will never call these. A client written against LocalAI is no
longer portable. That is the trade, and it is worth making deliberately.

## The un-prefixed aliases, and their limits

LocalAI registers some routes both at `/v1/...` and un-prefixed. This matters because
**cogito builds its inference URL by concatenating the base with `/chat/completions`, never
inserting a version segment** — so a bare base URL works against LocalAI and 404s against most
other servers.

Probed on a live host:

| Path | Un-prefixed alias |
|---|---|
| `/chat/completions` | **yes** |
| `/embeddings` | **yes** |
| `/images/generations` | yes |
| `/audio/transcriptions` | yes |
| `/responses` | yes |
| `/messages` | yes |
| `/completions` | **no — 404** |
| `/rerank` | **no — 404** |
| `/tokenize` | **no — 404** |

**Aliasing is selective, not universal.** The main OpenAI endpoints are aliased; LocalAI's own
extensions generally are not.

!!! note "A method note on how that table was produced"
    Our first probe sent `-d '{}'` and read `/embeddings → 404` as "no alias". It was not: the
    404 was `model "" not found`, the *same* error `/v1/embeddings` gives for a bad model. Only
    re-probing with a named model showed both forms returning identical errors — i.e. both routes
    exist.

    A 404 from a JSON API can mean "no such route" or "no such object". Distinguish them by the
    body before concluding anything.

The practical rule for configuring the stack:

| Target server | Base URL |
|---|---|
| LocalAI | `http://host:8080` **or** `http://host:8080/v1` |
| vLLM, OpenAI, most others | `http://host:port/v1` — **mandatory** |

## Where the shapes diverge

These are the divergences that break client code, in rough order of how often they will.

### Response IDs carry no prefix

Verified on both endpoints:

```text
POST /v1/chat/completions  ->  id: 20f92f49-a575-4220-81e8-d1b7a8769c76   object: chat.completion
POST /v1/responses         ->  id: b9ec1e4d-41c5-42b7-a18a-d12d21040be4   object: response
```

OpenAI returns `chatcmpl-…` and `resp_…`. LocalAI and LocalAGI return **bare UUIDs**. Any client
that pattern-matches on the prefix — or logs on it, or routes on it — fails against both.

The `object` fields are correct, so match on those instead.

### `usage` depends on which layer answered

| Endpoint | `usage` |
|---|---|
| LocalAI `/v1/chat/completions` | **real** — verified `{"prompt_tokens":11,"completion_tokens":1,"total_tokens":12}` |
| LocalAGI `/v1/responses` | **hardcoded zeros** |

So token accounting works at the inference layer and not at the agent layer. Meter at LocalAI,
and remember one agent request produces several calls. See
[observability](../06-deployment/observability.md).

### Streaming is not uniform

| Endpoint | `stream: true` |
|---|---|
| LocalAI `/v1/chat/completions` | **works** — verified SSE, `object: chat.completion.chunk` |
| LocalAGI `/v1/responses` | **accepted and silently ignored** |

Verified streaming frame:

```text
data: {"created":1786987340,"object":"chat.completion.chunk","id":"b473d383-…",
       "model":"qwen3next-80b-moecpu","choices":[{"index":0,"finish_reason":null,
       "delta":{"role":"assistant","content":null}}]}
```

The field exists on LocalAGI's request type and **no handler reads it**, so an SSE client hangs
waiting for events that never arrive.

### `/v1/responses` means different things on the two servers

The same path, implemented twice with different capabilities:

| | LocalAI | LocalAGI |
|---|---|---|
| `POST /v1/responses` | yes | yes |
| `GET /v1/responses/{id}` | **yes** | **no** |
| `POST /v1/responses/{id}/cancel` | **yes** | **no** |
| `model` field | a model **or** an agent name | an **agent name** only |

LocalAI stores responses and can retrieve them. Verified:

```bash
curl -s http://localhost:8080/v1/responses/does-not-exist
```

```json
{"error":{"message":"response not found: does-not-exist","param":"id","type":"not_found"}}
```

An OpenAI-shaped error with `param` and `type` — so this is a real retrieval endpoint, not a stub.
LocalAGI has no equivalent: its conversations live in an in-memory map with a TTL and are not
addressable after the fact.

**Consequence:** a client using `GET /v1/responses/{id}` works against LocalAI and 404s against
standalone LocalAGI. If you are writing against the Responses API, know which server you are
pointed at.

### `model` is overloaded on `/v1/responses`

Covered in full in [Responses vs Chat Completions](responses-vs-chat-completions.md), but it
belongs in any compatibility discussion: on `/v1/responses` the `model` field may name an **agent**
rather than a model, and LocalAI's middleware decides which engine runs based on that string.

A typo does not error. It silently changes which engine handled the request, and therefore whether
tools executed.

### Error bodies are OpenAI-ish, and inconsistent

Three shapes observed on one host:

```json
{"error":{"code":404,"message":"model \"nonexistent-model\" not found. To see available models, call GET /v1/models","type":""}}
```

```json
{"error":{"message":"response not found: does-not-exist","param":"id","type":"not_found"}}
```

```json
{"error":"Agent not found"}
```

The first has `code` and an empty `type`; the second has `param` and a populated `type` but no
`code`; the third — from LocalAGI — is a **bare string**, not an object.

Do not write a single error parser and assume it holds across the stack. The first is genuinely
helpful, though: it tells you which endpoint to call to fix it.

## LocalAI extensions worth knowing

Two are useful enough to justify the portability cost.

### `/v1/models/capabilities`

Answers "what can this model actually do", which plain `/v1/models` does not:

```json
{"object":"list","data":[
  {"id":"qwen3-coder-30b-a3b-instruct","object":"model",
   "capabilities":["chat","vision"],
   "input_modalities":["text","image"],
   "output_modalities":["text"]}]}
```

For any client that has to route by modality, this removes a pile of guesswork.

### `/system`

Answers "which models are resident right now", which no metric exposes:

```json
{"backends":["llama-cpp","cuda12-llama-cpp"],
 "loaded_models":[{"id":"qwen3next-80b-moecpu","backend":"llama-cpp"}]}
```

It also shows the backend **alias** and the resolved variant side by side — the clearest runtime
view of [the model runtime abstraction](model-runtime-abstraction.md). Note it is **admin-gated**.

## What compatibility buys you

The substitutions the protocol actually makes safe:

| Substitution | Works? | Why |
|---|---|---|
| Existing OpenAI SDK → LocalAI | **yes** | that is the point |
| LocalAI → vLLM, as LocalAGI's model server | **yes**, with `/v1` in the base URL | cogito holds a base URL and a model name |
| LocalAI → hosted OpenAI, as LocalRecall's embedder | **yes** | a standard go-openai client |
| LocalAI → another server, keeping LocalAI's extensions | **no** | rerank, capabilities, `/system` are LocalAI-only |
| Anthropic SDK → LocalAI | **yes**, via `/v1/messages` | |

The asymmetry is the thing to internalise: **the further you move from the OpenAI core, the less
substitutable your deployment becomes.** Using `/v1/chat/completions` and `/v1/embeddings` keeps
every component swappable. Using `/v1/rerank` and `/v1/face/identify` does not.

## Compatibility checklist for a client

- [ ] Match on `object`, never on an `id` prefix
- [ ] Read `finish_reason`; `length` can mean **empty content** on a reasoning model
- [ ] Take `usage` from LocalAI, not from an agent response
- [ ] Do not assume `stream` is honoured on `/v1/responses`
- [ ] Do not assume `GET /v1/responses/{id}` exists — it does on LocalAI, not on LocalAGI
- [ ] Parse errors defensively: `error` may be an object or a bare string
- [ ] Put `/v1` in base URLs unless you know the server aliases the path you need
- [ ] Check `GET /v1/models` for readiness, never `/readyz` alone

## Upstream references

- [LocalAI `core/http/routes/openai.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/openai.go) — the `/v1` routes and which un-prefixed aliases are registered. Validated against v4.8.2.
- [LocalAI `core/http/routes/localai.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/localai.go) — LocalAI's own extensions; `GET /system` with `adminMiddleware` at 417.
- [LocalAI `core/http/endpoints/openai/chat.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/endpoints/openai/chat.go) — Chat Completions, including streaming.
- [LocalAI `core/http/endpoints/openai/embeddings.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/endpoints/openai/embeddings.go) — the embeddings handler.
- [LocalAI `core/http/endpoints/localai/agent_responses.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/endpoints/localai/agent_responses.go) — the interceptor that reads `model` as an agent name.
- [LocalAGI `webui/app.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/app.go) — the Responses handler; hardcoded zero `usage` at 567-571. Validated against v2.9.0.
- [LocalAGI `webui/types/openai.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/types/openai.go) — `Stream` at 161, read by nothing.
- [OpenAI API reference](https://platform.openai.com/docs/api-reference) and [Anthropic Messages API](https://docs.anthropic.com/en/api/messages) — the shapes being approximated.
- Path inventory (111 total, 39 under `/v1`), alias probes, response-ID formats, populated `usage`, the streaming frame, `/v1/models/capabilities`, `/system`, and all three error shapes: observed 2026-08-17 on Ubuntu 24.04 amd64, LocalAI v4.8.2 CUDA 12. See [version matrix](../00-overview/version-matrix.md).
