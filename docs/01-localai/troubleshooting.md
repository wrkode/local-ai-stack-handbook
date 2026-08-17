# LocalAI troubleshooting

LocalAI is a leaf in this architecture: nothing in the stack calls *into* it except its
own clients, and it calls nothing except its backend processes. That makes it the layer
you verify **first** and the layer where a fault is least ambiguous.

Every section below is symptom → check → cause → fix. If you are not sure which layer
is at fault, start with
[`verify-stack.sh`](https://github.com/wrkode/local-ai-stack-handbook/blob/main/scripts/verify-stack.sh),
which walks the layers in dependency order and stops at the first failure.

## The four questions, in order

Answer these before reading any further. Most reported faults are resolved by question 2
or 3.

```bash
curl -s -o /dev/null -w 'readyz: %{http_code}\n' http://localhost:8080/readyz
```

```bash
curl -s http://localhost:8080/v1/models | jq -r '.data[].id'
```

```bash
docker exec localai ls /backends
```

```bash
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<model>","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'
```

| Question | If it fails |
|---|---|
| 1. Is the listener up? | [Process will not start](#the-process-will-not-start) |
| 2. Are models resolvable? | [No models installed](#v1models-is-empty) |
| 3. Is a backend installed? | [Backend problems](#backend-errors) |
| 4. Does inference work? | [Inference failures](#inference-fails-or-hangs) |

!!! danger "`/readyz` returning 200 means almost nothing"
    It reports that the HTTP listener is accepting connections. It does **not** report
    that any model is installed, loaded, or working.

    We reproduced the consequence: with `raw.githubusercontent.com` rate-limiting the
    host, **both model installs failed** and LocalAI still logged
    `core/startup process completed!` and `LocalAI is started and running`, answering
    `/readyz` with `200` and holding zero models.

    Never use `/readyz` alone as a health signal, in a readiness probe or in a
    `depends_on` condition. Pair it with `GET /v1/models`.

## The process will not start

**Symptom:** the container exits, restarts, or never answers `/readyz`.

```bash
docker logs localai 2>&1 | head -40
```

| Cause | Signature | Fix |
|---|---|---|
| Port already bound | `address already in use` | change the host port, or stop the other process |
| Volume permissions | permission denied on `/models`, `/backends` | fix ownership on the host path, or use named volumes |
| Insufficient memory | killed during model load, exit 137 | raise the Docker memory limit; use a smaller model |
| Bad configuration file | parse error naming a YAML file | fix or remove the file in `/models` |

Exit code 137 is an OOM kill, not a crash. `docker inspect localai --format '{{.State.ExitCode}}'`
will tell you.

## `/v1/models` is empty

**Symptom:** the process is healthy, `/v1/models` returns `{"data":[],...}`, and every
request fails with a model error.

LocalAI ships with **zero** models and **zero** backends. An empty list means either you
installed nothing or the install failed.

```bash
docker logs localai 2>&1 | grep -i -E 'gallery|installing model|429|503|401'
```

### Cause 1 — the gallery host is rate-limiting you

The most common cause, and the least obvious. LocalAI's model gallery is YAML hosted on
`raw.githubusercontent.com`. When that host throttles you, **no** gallery entry resolves.

```bash
docker exec localai curl -s -o /dev/null -w '%{http_code}\n' \
  https://raw.githubusercontent.com/mudler/LocalAI/master/gallery/qwen3.yaml
```

`429` or `503` confirms it. Observed log lines:

```text
ERROR failed to get gallery config for url error=failed to read url "https://raw.githubusercontent.com/…/qwen3.yaml", invalid status code 429
INFO  installing model model="qwen3-1.7b" license="apache-2.0"
ERROR [startup] failed installing model error=<nil> model="qwen3-1.7b"
```

Note the last line: an error log with a **nil error**. Unhelpful, but a reliable
signature of this failure.

**Fix:** wait for the limit to clear, or install manually. The backend gallery is served
from a container registry and is unaffected:

```bash
curl -s -X POST http://localhost:8080/backends/apply \
  -H 'Content-Type: application/json' -d '{"id":"llama-cpp"}'
```

Then fetch weights from Hugging Face directly and write the model YAML by hand — the
full sequence is in
[Recipe 1's variations](../05-recipes/localai-chat.md#variations).

Do **not** try `POST /models/apply` with an inline `config_file` and no `url` as a
bypass. We tried: it fails with `Get "": unsupported protocol scheme ""`.

### Cause 2 — the individual model's weights are unavailable

```text
ERROR [startup] failed installing model error=… 401 …
```

A gallery entry whose upstream repository rejects anonymous requests.
`LocalAI-functioncall-llama3.2-3b-v0.5` is a verified example — its Hugging Face
repository returns **HTTP 401**. That is an upstream gallery defect; choose a different
model.

### Cause 3 — you never installed one

Positional arguments install at startup:

```bash
docker run -p 8080:8080 -v localai-models:/models -v localai-backends:/backends \
  localai/localai:v4.8.2 qwen3-1.7b granite-embedding-107m-multilingual
```

## `model not found` for a model that is listed

**Symptom:** `/v1/models` shows it; the request rejects it.

```bash
curl -s http://localhost:8080/v1/models | jq -r '.data[].id'
```

Names are case- and hyphen-sensitive, and there is no fuzzy matching. Copy the exact
string.

This is also the most common LocalAGI-side failure: `LOCALAGI_MODEL` must match one of
these strings exactly.

## Backend errors

**Symptom:** the error mentions a backend, gRPC, or a missing binary, rather than the
model.

```bash
docker exec localai ls /backends
```

An empty `/backends` with a populated `/models` means the weights downloaded and the
backend did not. Models and backends are acquired separately — backends as **OCI
artifacts from a container registry**, not as libraries inside the image.

| Cause | Fix |
|---|---|
| `/backends` not persisted | mount a volume at `/backends`; it re-downloads otherwise |
| Backend install failed | `POST /backends/apply` with `{"id":"llama-cpp"}`, then poll the returned `status_url` |
| Wrong backend for the model | check `backend:` in the model YAML against `ls /backends` |

Installing `llama-cpp` produced **both** `llama-cpp` and `cpu-llama-cpp` in our run —
LocalAI selects a hardware-appropriate variant. Seeing two directories is normal.

## Inference fails or hangs

### First request is slow, later ones are fast

Not a fault. The first request loads the model: LocalAI allocates a port on `127.0.0.1`,
fork/execs the backend's `run.sh` as a **child process**, polls it with a gRPC health
call, then sends `LoadModel`.

Observed: **4 s** for `qwen3-1.7b` Q4_K_M on CPU including load; **8 s** for a 3B Q4
model.

```bash
docker logs localai 2>&1 | grep -i -E 'loading model|grpc|127.0.0.1'
```

If you need bounded first-request latency, keep the model resident and raise client
timeouts. A readiness probe cannot help — the process is ready long before the model is.

### Every request hangs

```bash
docker exec localai ps aux | head -20
```

| Cause | Signature | Fix |
|---|---|---|
| Model too large for available RAM | container killed, exit 137 | smaller model or quantisation; raise memory |
| Backend process died | no backend process in `ps`; gRPC errors in the log | check the log for the backend's own output |
| Model eviction thrashing | repeated load/unload lines | limit concurrent models; see [configuration](configuration.md) |

Loading a model may **evict another**, which terminates that backend's OS process. If two
clients alternate between two models on a memory-constrained host, both pay a load on
every request.

### Requests fail with 401 or 403

`LOCALAI_API_KEY` is set. Every client needs the matching token —
`LOCALAGI_LLM_API_KEY` on LocalAGI, `OPENAI_API_KEY` on LocalRecall. Each hop
authenticates independently.

Note that when `LOCALAGI_LLM_API_KEY` is unset, LocalAGI sends the literal string
`sk-xxx`. You will see a **rejected token**, never "no credentials supplied".

### Requests 404 on `/chat/completions`

**Symptom:** LocalAI's access log shows `POST /chat/completions 404` — no `/v1`.

Not a LocalAI fault. cogito builds its URL by concatenating the configured base with
`/chat/completions` and never inserts a version segment. LocalAI tolerates this because
it registers un-prefixed aliases; other OpenAI-compatible servers do not.

```bash
docker logs localai 2>&1 | grep ' 404'
```

See [the `/v1` trap](../04-integration/api-flow.md#the-v1-trap).

## Embeddings-specific failures

**Symptom:** chat works, embeddings do not.

```bash
curl -s http://localhost:8080/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"granite-embedding-107m-multilingual","input":"test"}' \
  | jq '.data[0].embedding | length'
```

Expected `384` for the reference model.

| Cause | Check | Fix |
|---|---|---|
| Model lacks `embeddings: true` | `docker exec localai grep -i embeddings /models/<name>.yaml` | use a real embedding model |
| Wrong model name sent | the `model` field | an LLM name will not work here |
| Unexpected dimension | `.data[0].embedding \| length` | you are using a different model — and it invalidates existing collections |

A chat model with `embeddings: true` will *answer* rather than error. The gallery entry
`bert-embeddings` is exactly this trap: it resolves to Llama-3.2-1B-Instruct with the
flag set. Retrieval quality will be poor and nothing will report an error.

More: [embeddings](embeddings.md).

## Reaching LocalAI from another container

**Symptom:** works from your shell, fails from LocalAGI or LocalRecall.

```bash
docker exec localagi curl -s -o /dev/null -w '%{http_code}\n' http://localai:8080/readyz
```

`localhost` inside a container is that container. Use the Compose service name on a
shared network, or `host.docker.internal` from a container to the host.

If the name does not resolve you will see the failure in the *client's* log, not
LocalAI's:

```text
dial tcp: lookup localrecall on 127.0.0.11:53: no such host
```

That is Docker's embedded DNS reporting an unknown service name — usually a stopped
container or a typo.

## No GPU acceleration

**Symptom:** a GPU is present and inference is CPU-slow.

**On macOS this is expected and unavoidable in Docker.** There is no Metal or Darwin
target anywhere in LocalAI's Dockerfile or image workflows: a containerised LocalAI on
Apple Silicon runs CPU-only inside a Linux VM. GPU acceleration on a Mac requires the
**native install**, which pulls `metal-darwin-arm64-*` backends.

On Linux, check that you used a GPU image tag and passed the device through:

```bash
docker inspect localai --format '{{.Config.Image}}'
```

| Target | Tag suffix |
|---|---|
| CUDA 12 / 13 | `-gpu-nvidia-cuda-12`, `-gpu-nvidia-cuda-13` |
| AMD ROCm | `-gpu-hipblas` |
| Intel SYCL | `-gpu-intel` |
| Vulkan | `-gpu-vulkan` |

More: [GPU](gpu.md).

## Stale image tags

**Symptom:** behaviour that does not match this handbook, or missing features.

**All-in-one (AIO) images were removed in the 4.x line.** Tags such as `latest-aio-*`,
`-extras`, `-ffmpeg`, `-core`, `-cuda-11` and `-intel-f16/f32` still *resolve* but are
frozen builds from 2026-02-21 or earlier. `latest-cpu` has been stale since 2025-06-19
and is still referenced in comments in LocalAI's own compose file.

```bash
docker inspect localai --format '{{index .Config.Labels "org.opencontainers.image.version"}}'
```

Pin an explicit version. Do not trust a tutorial that uses `latest-aio` or
`latest-cpu`.

## Reading the logs

```bash
docker logs localai 2>&1 | grep -i error | tail -20
```

Remember `error=<nil>` is possible and means the real cause is on a nearby line.

```bash
docker logs localai 2>&1 | grep -c 'chat/completions'
```

**Count these when debugging an agent.** One client request to LocalAGI should produce one
call here with no tools, and three or more with tools. A number that keeps climbing is an
agent loop, not a LocalAI problem.

```bash
docker logs localai 2>&1 | tail -20
```

The access log, one line per request with status and latency.

```bash
docker run --rm localai/localai:v4.8.2 --help
```

Every flag and its environment variable — the authoritative list of what is
configurable. See [environment variables](../08-reference/environment-variables.md).

## Verified metrics and traces

```bash
curl -s http://localhost:8080/metrics | head -20
```

```bash
curl -s http://localhost:8080/api/traces/summary | jq
```

Both exist and respond. What they do and do not expose — and the gaps, such as
LocalAGI's `usage` fields being hardcoded to zero — is covered in
[observability](../06-deployment/observability.md).

Note also that `/swagger/doc.json` is **incomplete**: it documents 111 paths and omits
live routes including `/api/agents`. Do not treat it as the API's ground truth; use
[the API map](../08-reference/api-map.md).

## When LocalAI is not the problem

If all four opening questions pass, LocalAI is working. Move up:

| Symptom | Go to |
|---|---|
| Retrieval returns nothing | [LocalRecall troubleshooting](../03-localrecall/troubleshooting.md) |
| Agent never returns, or ignores tools | [LocalAGI troubleshooting](../02-localagi/troubleshooting.md) |
| Agent answers without its knowledge | [Recipe 6](../05-recipes/agent-with-knowledge.md) |
| Unsure which layer | [`verify-stack.sh`](https://github.com/wrkode/local-ai-stack-handbook/blob/main/scripts/verify-stack.sh) |

## Upstream references

- [LocalAI `core/cli/run.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/cli/run.go) — every flag and environment variable; startup ordering. Validated against v4.8.2.
- [LocalAI `pkg/model/initializers.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/pkg/model/initializers.go) — port allocation, backend fork/exec, health polling, `LoadModel`, eviction.
- [LocalAI `core/http/routes/openai.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/openai.go) — un-prefixed route aliases that make a bare base URL work.
- [LocalAI `core/http/endpoints/openai/embeddings.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/endpoints/openai/embeddings.go) — the embeddings handler and its model checks.
- [LocalAI `Dockerfile`](https://github.com/mudler/LocalAI/blob/v4.8.2/Dockerfile) — declared volumes; absence of any Metal/Darwin target.
- [LocalAI container documentation](https://localai.io/basics/container/) — image variants.
- The HTTP 429 gallery failure with a healthy `/readyz`, `error=<nil>`, the failed inline-`config_file` install, backend install producing two directories, latencies, and image-tag staleness: observed 2026-08-17, see [version matrix](../00-overview/version-matrix.md).
