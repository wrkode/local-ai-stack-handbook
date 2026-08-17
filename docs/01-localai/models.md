# Models

A model in LocalAI is a YAML file in the models directory. The weights are an
artifact that file points at. Nothing is registered in a database; the models
directory *is* the registry, scanned at boot by `LoadModelConfigsFromPath` and
re-read when the gallery writes into it.

## What lands in the models directory

Tested 2026-08-17 — installing `granite-embedding-107m-multilingual` from the
gallery into an empty `/models`:

```text
._gallery_granite-embedding-107m-multilingual.yaml    1149 B   gallery metadata
granite-embedding-107m-multilingual-f16.gguf     220974080 B   weights, mode 0600
granite-embedding-107m-multilingual.yaml              179 B   generated model config
localai-functioncall-llama3.2-3b-v0.5-q4_k_m.gguf.partial  0 B  orphan from a failed job
```

Four things follow from that listing:

- The generated config is **179 bytes**. Gallery models carry almost nothing
  locally; the interesting configuration lives in the gallery entry's `overrides`
  and is materialized into this file.
- The `._gallery_*.yaml` sidecar records where the model came from.
- Weights are written mode `0600`.
- **A failed download leaves a `.partial` orphan**, and nothing cleans it up
  during the session. `application.New()` reaps `*.partial` files older than 24 h
  at startup, so it lingers until the next boot after that window.

## The model config schema

`core/config/model_config.go` defines `ModelConfig`. The fields you will actually
write, grouped:

| Group | Keys | Notes |
|---|---|---|
| Identity | `name`, `alias`, `description`, `disabled`, `pinned` | `pinned` exempts the model from watchdog idle eviction |
| Execution | `backend`, `parameters.model`, `f16`, `threads`, `context_size`, `gpu_layers`, `mmap`, `mmlock`, `low_vram`, `flash_attention`, `cache_type_k`/`_v`, `rope_scaling`, `yarn_*` | `parameters` is the inlined `PredictionOptions` block |
| Sampling defaults | `parameters.temperature`, `top_p`, `top_k`, `seed`, `stopwords`, `cutstrings` | Request values override these |
| Prompting | `template.chat`, `template.chat_message`, `template.completion`, `template.edit`, `template.function`, `template.use_tokenizer_template`, `template.multimodal`, `template.reply_prefix` | Presence of a chat template is what makes a model chat-capable |
| Capability declaration | `embeddings`, `known_usecases`, `known_input_modalities`, `known_output_modalities`, `reranking` | See the usecase section |
| Artifacts | `download_files`, `artifacts` | What to fetch and where to put it |
| Backend passthrough | `engine_args`, `options`, `overrides` | `engine_args` is JSON handed to the backend verbatim |
| vLLM-specific | `gpu_memory_utilization`, `trust_remote_code`, `enforce_eager`, `swap_space`, `max_model_len`, `tensor_parallel_size`, `dtype`, `limit_mm_per_prompt` | Explicit fields, not `engine_args` |
| Diffusion | `diffusers.*`, `step`, `cuda` | |
| Speech | `tts.voice`, `tts.audio_path`, `tts.voice_cloning` | |
| Concurrency | `limits.max_concurrent`, `limits.retry_after_seconds`, `concurrency_groups` | See [backends](backends.md) — groups cause cross-model eviction |
| Load behaviour | `grpc.attempts`, `grpc.attempts_sleep_time` | Health-check retry budget for a cold load |
| Composition | `pipeline.{tts,llm,transcription,vad,sound_detection}` | Names *other* models, for audio-to-audio and realtime |
| Agentic | `agent.*`, `mcp.remote`, `mcp.stdio`, `function.*`, `reasoning`, `reasoning_effort`, `chat_template_kwargs` | `agent` is the cogito tool-loop configuration for this model |
| Routing and safety | `router.*`, `proxy.*`, `pii.*`, `pii_detection.*`, `mitm.*` | `proxy` turns the model into a cloud passthrough |
| Misc | `feature_flags`, `usage` | |

A minimal working config is small:

```yaml
name: qwen3-1.7b
backend: llama-cpp
parameters:
  model: Qwen3-1.7B-Q4_K_M.gguf
context_size: 4096
template:
  use_tokenizer_template: true
```

### Aliases

`alias` is a pure redirect. Every request for `name` is served by the target and
**all other fields in an alias config are ignored**. The target must be an
existing non-alias model; this is enforced both at load and at swap time.

```yaml
name: gpt-4
alias: qwen3-1.7b
```

That is the supported way to give a model the name a hard-coded client expects.
`GET /api/aliases` lists the current mapping.

There is a second, unrelated alias namespace: backend name aliases such as
`llama` → `llama-cpp` and `sentencetransformers` → `transformers`. Those live in
`pkg/model/initializers.go`, not in your YAML.

## How a model reaches an endpoint

Every inference route filters candidate models by a **usecase flag**. There are
24 of them (`FLAG_CHAT`, `FLAG_COMPLETION`, `FLAG_EDIT`, `FLAG_EMBEDDINGS`,
`FLAG_RERANK`, `FLAG_IMAGE`, `FLAG_TRANSCRIPT`, `FLAG_TTS`, `FLAG_VISION`,
`FLAG_VAD`, `FLAG_SCORE`, `FLAG_TOKEN_CLASSIFY`, `FLAG_3D`, …) plus the composite
`FLAG_LLM = CHAT|COMPLETION|EDIT`.

A model's flags come from an explicit `known_usecases:` list, or from the
heuristic `GuessUsecases`. The heuristic's gates are worth memorising, because
"my model is not offered on this endpoint" is nearly always one of them
(source-verified, v4.8.2):

| Usecase | Requirement |
|---|---|
| chat | A chat template **or** `use_tokenizer_template: true`, and a backend not on the non-text-generation list (`whisper`, `piper`, `kokoro`, `diffusers`, `stablediffusion*`, `rerankers`, `silero-vad`, `rfdetr`, `insightface`, `speaker-recognition`, `transformers-musicgen`, `ace-step`, `acestep-cpp`) |
| **embeddings** | **`embeddings: true`.** This is the single gate for `/v1/embeddings` |
| image | Backend ∈ {`diffusers`, `stablediffusion`, `stablediffusion-ggml`} |
| video | Backend ∈ {`diffusers`, `stablediffusion`, `vllm-omni`} |
| rerank | Backend `rerankers` **or** `reranking: true` |
| transcript | Backend `whisper` and not the `vad_only` option |
| score, token_classify | **No heuristic at all** — must be declared in `known_usecases` |

Chat and embeddings are mutually exclusive under the heuristic: a config with
`embeddings: true` is deliberately *not* offered for chat. Declare
`known_usecases` explicitly if you need one model on both.

Each usecase also names the gRPC method it drives (`chat` → `Predict`/
`PredictStream`, `embeddings` → `Embedding`, `rerank` → `Rerank`, …). That
mapping is what lets LocalAI reject a model on an endpoint its backend cannot
serve, before spawning anything.

## The gallery

A gallery is a remote YAML index, fetched, cached and parsed into typed elements.
There are two independent kinds with separate defaults:

| Kind | Default URL | Mirror | Element type |
|---|---|---|---|
| Models | `https://index.localai.io/models` | `github:mudler/LocalAI/gallery/index.yaml@master` | `GalleryModel` — metadata + config file + overrides + variants |
| Backends | `https://index.localai.io/backends` | `github:mudler/LocalAI/backend/index.yaml@master` | `GalleryBackend` — see [backends](backends.md) |

The model index carries **1683 entries** (verified 2026-08-17 against both the
in-tree `gallery/index.yaml` and the live index, which returned identical name
sets).

Mirrors are an **availability fallback tried in order, not a load-balancing
pool**. The index fetch has an on-disk cache, a cooldown, and a five-minute
refresh throttle.

Gallery entries can carry a keyless-cosign `verification:` policy (issuer,
identity, `not_before`). Verification is opt-in: a gallery without a policy
installs with no signature check and only warns, unless
`LOCALAI_REQUIRE_BACKEND_INTEGRITY=true` turns the warning into a hard failure.
`not_before` is the revocation lever, because keyless cosign certificates are
ephemeral and have no CA-side revocation.

### Installing from the gallery

```bash
local-ai models list
local-ai models install granite-embedding-107m-multilingual
```

Names are matched against the gallery entry's `name:` key; `<gallery>@<name>`
also works and is what `models list` prints.

Over HTTP, and this is where the operational detail is:

```bash
curl -s -X POST http://localhost:8080/models/apply \
  -H 'Content-Type: application/json' \
  -d '{"id":"localai@granite-embedding-107m-multilingual"}'
# {"uuid":"...","status":"http://localhost:8080/models/jobs/<uuid>"}

curl -s http://localhost:8080/models/jobs/<uuid>
curl -s http://localhost:8080/models/jobs      # all jobs
```

### Job semantics — tested

Observed 2026-08-17 against a running v4.8.2:

| Behaviour | Detail |
|---|---|
| Response | Immediate. `{"uuid", "status"}`, where `status` is the poll URL |
| Concurrency | **Jobs run one at a time.** A second install sat at `"message":"queued"` for minutes while the first ran |
| Fields | `processed`, `progress`, `message`, `error`, `file_name`, `file_size`, `downloaded_size`, `cancelled`, `cancellable`, `gallery_element_name`, `phase` |
| **`progress` is unreliable** | During a backend download the job reported `"progress":100` while `"message"` read `Total: 42.0 MiB. Current: 13.0 MiB` |

**Poll `processed`, not `progress`.** `processed: true` is the completion signal;
check `error` on the same object before declaring success. A client that waits
for `progress == 100` will act on an unfinished download.

Because jobs are serialized, a queued install is not a stuck install. Distinguish
them by whether *any* job in `GET /models/jobs` is advancing.

### Gallery listing does not imply downloadability

Tested 2026-08-17: `localai@LocalAI-functioncall-llama3.2-3b-v0.5` is listed in
the gallery and fails on install:

```text
error: failed to download url
"https://huggingface.co/mudler/LocalAI-functioncall-llama3.2-3b-v0.5-Q4_K_M-GGUF/resolve/main/localai-functioncall-llama3.2-3b-v0.5-q4_k_m.gguf",
invalid status code 401
```

Verified independently: that Hugging Face repository returns 401 to anonymous
requests, on both the resolve URL and the API. The sibling 1B model
`LocalAI-functioncall-llama3.2-1b-v0.4` returns 200. The gallery index and the
artifact host are different systems with no consistency guarantee between them; a
401 here is not a local misconfiguration and no amount of retrying fixes it. See
[troubleshooting](troubleshooting.md).

### Installing a model can install a backend

After installing a model, if the resolved entry declares a `backend:` and
`LOCALAI_AUTOLOAD_BACKEND_GALLERIES` is true (the default), LocalAI installs that
backend from the backend gallery in the same job. This is why a 211 MiB embedding
model produced a 42 MiB OCI pull as well (tested 2026-08-17).

### Other install sources

`local-ai run <uri>` and `POST /models/import-uri` accept more than gallery
names (documented, `README.md`):

| Form | Example |
|---|---|
| Gallery name with quantization | `llama-3.2-1b-instruct:q4_k_m` |
| Hugging Face | `huggingface://TheBloke/Model-GGUF/model.q4_k_m.gguf` |
| Ollama registry | `ollama://qwen3:1.7b` |
| A YAML config URL | `https://example.com/model.yaml` |
| OCI artifact | `oci://registry/repo:tag` |

For a URI with no gallery entry, LocalAI runs **import-time backend detection**:
40 importers each implement `Match(details)`, walked in a fixed order, first
match wins. The order is load-bearing and commented in source — the depth,
DS4 and privacy-filter importers must precede the llama.cpp importer because
their weights are GGUFs the generic importer would otherwise claim.

## Preloading

Three mechanisms, with different costs:

| Mechanism | What it does | When it runs |
|---|---|---|
| `LOCALAI_MODELS` / positional args | Installs model config URLs | Before the listener binds |
| `LOCALAI_PRELOAD_MODELS` (JSON) / `LOCALAI_PRELOAD_MODELS_CONFIG` (file) | Applies gallery installs | Before the listener binds |
| `LOCALAI_LOAD_TO_MEMORY` | **Loads weights into RAM/VRAM**, spawning backend processes | Before the listener binds |

All three delay the port opening. Upstream's Dockerfile cites 31 GB of
HuggingFace artifacts materialized before bind on a live cluster as the reason
for a 60-minute healthcheck start period. For anything latency-sensitive at
startup, prefer warming after boot:

```bash
curl -s -X POST http://localhost:8080/backend/load \
  -H 'Content-Type: application/json' -d '{"model":"qwen3-1.7b"}'
```

`GET /api/models/:id/load-status` reports live cold-load progress and is the one
model-administration route that uses standard auth rather than admin auth.

## Editing and reloading

| Route | Purpose |
|---|---|
| `POST /models/edit/:name` | Rewrite a model config |
| `PATCH /api/models/config-json/:name` | Partial config update (UI) |
| `PUT /models/toggle-state/:name/:action` | Enable/disable without deleting |
| `PUT /models/toggle-pinned/:name/:action` | Exempt from idle eviction |
| `POST /models/reload` | Re-scan the models directory |
| `POST /models/delete/:name` | Remove config and artifacts |

All of these are behind `adminMiddleware`, and all of them vanish under
`--disable-gallery-endpoint`. With no auth database configured, "admin" is
everyone who can reach the port.

## Upstream references

- [`core/config/model_config.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/config/model_config.go) — the YAML schema, usecase flags, `GuessUsecases` gates, alias semantics. Validated against v4.8.2.
- [`core/config/model_config_loader.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/config/model_config_loader.go) — directory scan, alias resolution, preload. Validated against v4.8.2.
- [`core/config/backend_capabilities.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/config/backend_capabilities.go) — usecase → gRPC method map. Validated against v4.8.2.
- [`core/gallery/models.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/gallery/models.go) — `InstallModelFromGallery`, automatic backend install. Validated against v4.8.2.
- [`core/gallery/importers/importers.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/gallery/importers/importers.go) — importer ordering and `DiscoverModelConfig`. Validated against v4.8.2.
- [`core/config/gallery.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/config/gallery.go) — gallery struct, mirrors as fallback, cosign verification policy. Validated against v4.8.2.
- [`core/http/routes/localai.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/localai.go) — `/models/apply`, jobs, edit/delete/reload routes. Validated against v4.8.2.
- [`core/application/startup.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/application/startup.go) — 24 h `*.partial` reaper, preload ordering. Validated against v4.8.2.
- Job field names, serialization, `progress` inaccuracy, installed-file listing, the 401 gallery entry: observed 2026-08-17 on `localai/localai:latest` reporting `v4.8.2 (5ff25d9d)`.
- Gallery entry count (1683) verified against the live index and `gallery/index.yaml`, 2026-08-17.
