# 006 — Validation log

What was actually executed on 2026-08-17, including everything that failed. This is the note
that backs the `tested:` blocks throughout `docs/`.

Two of the handbook's most useful findings came from things going wrong rather than from
reading code, which is the argument for keeping this log rather than only recording successes.

## Environment

```yaml
date: 2026-08-17
host: macOS 26.5.1, arm64 (Apple Silicon)
runtime: Docker Desktop 29.7.2
gpu: none — Docker on macOS has no Metal access
deployment: compose/ reference environment, Pattern B
versions:
  localai: v4.8.2 (5ff25d9d145e0a03a5b9a3559c620f1e1204ca6d)
  localagi: v2.8.1 (image)  # v2.9.0 has no published image
  localrecall: v0.6.4 + v0.6.4-postgresql
vector_engine: postgres
models:
  llm: qwen3-1.7b (Q4_K_M, 1,282,439,296 bytes)
  embeddings: granite-embedding-107m-multilingual (F16, 220,974,080 bytes)
```

## Failure 1 — the model gallery was unreachable

**The most valuable failure of the run**, because it produces a state that looks healthy.

`raw.githubusercontent.com` returned **HTTP 429** to this host, later 503. LocalAI's model
gallery is YAML hosted there, so **no** gallery entry resolved and both model installs failed.

Observed:

```text
ERROR failed to get gallery config for url error=failed to read url "https://raw.githubusercontent.com/mudler/LocalAI/master/gallery/qwen3.yaml", invalid status code 429
INFO  installing model model="qwen3-1.7b" license="apache-2.0"
ERROR [startup] failed installing model error=<nil> model="qwen3-1.7b"
ERROR error installing models error=…
INFO  core/startup process completed!
INFO  LocalAI is started and running address=":8080"
```

Three findings:

1. **`/readyz` returned 200 with zero models installed.** The process reported itself started
   and running. This is why `verify-stack.sh` treats "models resolvable" as a layer distinct
   from "process reachable", and why the handbook repeatedly says `/readyz` is not a readiness
   signal.
2. **`error=<nil>`** — a real error log line with an empty error. An upstream logging defect,
   and a recognisable signature of this failure.
3. **The backend gallery was unaffected.** `/backends/available` returned data throughout,
   because backends are OCI artifacts from a container registry rather than YAML on GitHub.

Confirmed from inside the container:

```text
raw.githubusercontent: 429
huggingface:           200
```

## Dead end — `/models/apply` with an inline `config_file`

`GalleryModel` has a `ConfigFile` field documented as "read in the situation where URL is
blank", so an inline base config looked like the natural gallery bypass.

Attempted: `POST /models/apply` with `name`, a full `config_file`, and a `files` array
carrying the `huggingface://` URI. Result:

```json
{"error":"Get \"\": unsupported protocol scheme \"\"","processed":true}
```

Something on that path still fetches the URL even when `config_file` is supplied. **Not
pursued further** — a working alternative existed. Recorded so nobody else spends the attempt.

*(Unverified whether this is a defect or a misuse of the field.)*

## What worked instead — manual installation

1. Install the backend through the API, which was unaffected:

    ```text
    POST /backends/apply {"id":"llama-cpp"}  ->  completed
    ```

    Produced **two** directories: `llama-cpp` and `cpu-llama-cpp`. LocalAI selects a
    hardware-appropriate variant, so seeing two is normal.

2. Download the GGUFs from Hugging Face directly, using the URIs from the local clone's
   `gallery/index.yaml`, rewritten as `resolve/main` URLs.

3. Write model YAMLs by hand, copying the gallery's own `config_file` for the `qwen3` family.

4. Restart. `/readyz` returned 200 after **~60 s**; `/v1/models` then listed both models.

This is the sequence documented in
[Recipe 1's variations](../docs/05-recipes/localai-chat.md#variations).

### A correction it produced

The gallery's shared `qwen3` `config_file` sets **`context_size: 8192`**, and the
`qwen3-1.7b` entry overrides only `parameters.model`. The effective context window on a stock
install is therefore **8,192**, not the model's native 32,768.

`docs/00-overview/version-matrix.md` said 32,768 and was **corrected**.

## Failure 2: LocalAGI v2.8.1 differs from v2.9.0

Discovered by accident: `GET /api/collections` on LocalAGI returned

```text
Cannot GET /api/collections
```

The routes exist in the v2.9.0 source that had been read. Cloning the **v2.8.1** tag settled
it:

| Check | v2.9.0 | v2.8.1 |
|---|---|---|
| Files importing `mudler/localrecall` | several | **0** |
| `localrecall` in `go.mod` | yes | **absent** |
| `webui/collections*.go` | present | **absent** |
| `/api/collections` routes | 11 | **none** |
| cogito | `v0.9.5-0.20260315…` | `v0.9.1-0.20260216…` |

So the in-process knowledge layer and the collections management API are **v2.9.0-source-only
features that have never shipped as an image** — `quay.io/mudler/localagi:v2.9.0` does not
exist, independently re-verified against the quay tag list (highest tag: `v2.8.1`).

Consequences, now documented across the handbook:

- On any runnable LocalAGI, retrieval is **always** HTTP to a separate LocalRecall.
- `LOCALAGI_LOCALRAG_URL` is **required**, not an opt-in.
- Collections must be managed against LocalRecall directly.

`docs/04-integration/localagi-localrecall.md` originally described the in-process path as "the
default" and was **corrected** with a prominent version warning.

## Failure 3 — an invalid test that looked like a result

Worth recording because the wrong conclusion was briefly reached.

To test agent behaviour with the knowledge layer down, `docker compose stop localrecall` was
run **from the repository root**, where there is no compose file, with stderr redirected. It
silently did nothing. The agent then answered correctly, and the first reading was "the agent
somehow still has knowledge".

`docker ps` showed LocalRecall still running. Re-run from `compose/`, the real result was very
different — see below.

**Method note:** always assert the precondition of a negative test. A test that cannot fail is
not evidence.

## Finding — knowledge fails open, and loudly enough to alert on

With LocalRecall genuinely stopped, an agent that had answered "4200 milliseconds" from a
document instead answered:

```text
The Zeppelin-7 telemetry bus uses a heartbeat interval of **10 seconds**
to maintain communication reliability.
```

HTTP 200, `status: completed`, `error: null`. **Availability preserved, correctness destroyed.**

The log did report it, at **INFO**:

```text
INFO Error finding similar strings inside KB: error="Post \"http://localrecall:8080/api/collections/full-stack-probe/search\": dial tcp: lookup localrecall on 127.0.0.11:53: no such host"
INFO [Knowledge Base Lookup] No similar strings found in KB
ERROR Observable completed without any progress id=6 name=job
```

This **corrected** an earlier claim in `docs/04-integration/deployment-patterns.md` that the
failure was "logged at debug only". The distinction is now documented precisely:

| Failure | Log level | Visible by default |
|---|---|---|
| Knowledge service unreachable | **INFO** | yes |
| Knowledge disabled by config (three guards) | **DEBUG** | no |

Both return 200 with an unreliable answer; only the first leaves a default-level trace.

## The retrieval trace

The measurement that turned the architecture diagram into evidence. Agent `kb-probe`,
`enable_kb` and `kb_auto_search` on, asked about a fact existing only in its collection.

LocalAGI:

```text
15:42:53.667 INFO [Knowledge Base Lookup] Last user message agent=kb-probe
15:42:53.705 INFO [Knowledge Base Lookup] Found similar strings in KB agent=kb-probe
  results="- The Zeppelin-7 telemetry bus uses a heartbeat interval of 4200 milliseconds. …
    (map[created_at:2026-08-17T15:42:42Z file_name:kb-fact.txt source:e040fb16-…/kb-fact.txt
     title:e040fb16-…/kb-fact.txt type:file]) \n"
```

LocalRecall, same instant:

```json
{"time":"2026-08-17T15:42:53.705Z","remote_ip":"172.18.0.5","method":"POST",
 "uri":"/api/collections/kb-probe/search","user_agent":"Go-http-client/1.1",
 "status":200,"latency_human":"37.190542ms"}
```

Confirmed empirically rather than by reading code:

- The collection **is** the lowercased agent name.
- The query **is** the latest user message, verbatim.
- The result format **is** `fmt.Sprintf("%s (%+v)")` — **Go map syntax reaches the model**.
- The hop is real: `172.18.0.5` is the LocalAGI container.
- Cost: **37.19 ms** of a 2.27 s request.

## Finding — a correct tool call, narrated incorrectly

Prompt: *"Increase the counter named apples by 7, then tell me its value."*

Agent history, newest first:

```text
Action taken: counter  Parameters: {"adjustment":0,"name":"apples"}  Result: Current value of counter 'apples' is 7
Action taken: counter  Parameters: {"adjustment":7,"name":"apples"}  Result: Created counter 'apples' with initial value 7
```

Reply: *"The counter 'apples' was increased by 7 to **14**. Its current value is 14."*

| Layer | Correct? |
|---|---|
| Tool selection, arguments, execution, results | yes |
| The model's prose about the results | **no** |

The agent behaved correctly; the 1.7B model's summary did not. Hence the handbook's rule:
`/api/agent/:name/status` is ground truth, the reply is a summary written by the weakest
component.

Related, **not traced**: a direct `POST /api/action/counter/run` for the same counter name
reported `initial value 0`, so a direct action run does not share state with the agent's
invocations. The scoping mechanism was not established.

## Finding — an unknown `previous_response_id` does not error

```text
previous_response_id: "does-not-exist-at-all"
-> 200, "I don't have access to personal information such as favorite colors."
```

No error, no warning. Consistent with the source: `GetConversation` returns an empty
conversation for unknown or expired keys. So valid-but-new, expired, and never-existed are
**indistinguishable** to a client.

Also confirmed: chaining works, and each reply returns a **new** UUID
(`b9ec1e4d-…` → `00c6abcf-…`). The response `id` is a **bare UUID**, not `resp_…`, and
`previous_response_id` is echoed back as `null` even when sent.

## Finding — observability is thinner than expected

| Probe | Result |
|---|---|
| LocalAI `/metrics` | 200, **44 metric families** |
| …of which application-specific | **1** (`api_call`) — the other 43 are Go runtime and process |
| LocalAGI `/metrics` | **404** |
| LocalRecall `/metrics` | **404** |
| LocalAI `/api/traces/summary` | 200, but `total: 0` after dozens of requests |
| LocalRecall access log `id` field | present and **empty** — no request-ID propagation |
| Agent `usage` | all zeros, matching `// TODO: calculate actual usage` |

`/api/traces/summary` is therefore **not** an HTTP request tracer. What populates it was not
established; likely agent jobs in the distributed path, which this environment does not use.

## Finding — LocalAI's MCP server is narrower than assumed

```text
INFO LocalAI Assistant in-memory MCP server initialised tools=36 read_only=false
```

Probed `/mcp`, `/api/mcp`, `/mcp/sse` — **all 404**. So it is in-memory, backing LocalAI's own
Assistant, with no default external HTTP path.

This **corrected** wording in `docs/00-overview/architecture.md` and
`docs/04-integration/overview.md`, both of which had said it exposed an administration surface
"to any MCP client". `read_only=false` remains significant: the Assistant is a model-driven
agent with 36 writable tools over the runtime.

## Measurements

| Operation | Result |
|---|---|
| Embedding dimensions | **384** |
| Embedding magnitude | **0.9999999536** — L2-normalized to float32 precision |
| Similarity: paraphrases | **0.868** |
| Similarity: unrelated | **0.540** — the floor is not zero |
| Chat completion, incl. model load | 4 s |
| LocalRecall ingest (207 bytes, 1 chunk) | 34.9 ms |
| LocalRecall search, direct | 30.4 ms |
| Retrieval inside an agent request | 29–37 ms |
| Agent, no tools | 2–3 s |
| Agent, knowledge only | 2.27 s |
| Agent, knowledge + 1 tool, 2 model calls | 24.1 s |
| Agent, 1 tool, 3 model calls | **38.7 s** |
| LocalAGI action / connector counts | **40 / 9** |
| PostgreSQL extensions | `plpgsql`, `pg_textsearch`, `vector`, `vectorscale` |
| Volume: agent state | **6.1 kB** |
| Volume: models | 1.503 GB |
| Volume: postgres | 66.23 MB for one document — a baseline, not data |

The similarity floor of 0.54 is the number that most changed how the handbook describes
retrieval: combined with the absence of any relevance threshold, it means top-*k* always
returns *k* results, however irrelevant.

## Finding: `max_tokens` too low returns an *empty* answer

Found while writing `examples/01-localai/run.sh`, which originally used
`max_tokens: 128`.

| `max_tokens` | `finish_reason` | `content` | completion tokens |
|---|---|---|---|
| 128 | `length` | **`''` — empty** | 128 |
| 600 | `stop` | one correct sentence | **371** |

`qwen3-1.7b` is reasoning-tuned and the thinking counts against the budget, so a low
`max_tokens` is not a short answer — it is **no answer**. It needed **371 completion tokens to
produce one sentence**.

`reasoning_content` was **absent** from the response in both cases, so those tokens are consumed
without being exposed — despite the gallery config's `use_jinja: true` comment describing native
classification of `<think>` blocks into `reasoning_content`. *(Why it is absent was not
established.)*

Documented in [Recipe 1](../docs/05-recipes/localai-chat.md#run-the-request).

## Correction: search results *do* carry a `Similarity` field

An early draft said no similarity score is returned. Running
`examples/03-localrecall/run.sh` showed the field exists:

```json
{"ID":"1","Metadata":{…},"Embedding":null,"Similarity":0,"Content":"The Zeppelin-7 …"}
```

Present, and **observed as `0`** on the PostgreSQL engine. The practical conclusion is unchanged
— you still cannot tell how good a match was — but the claim was imprecise and was corrected in
Recipe 3, the storage map and the glossary. *(Whether other engines populate it was not
tested.)*

## Defect in our own toolchain: an impossible pin

`requirements-docs.txt` pinned `pymdown-extensions==11.0.1` with a comment claiming it had been
verified against PyPI. **That version does not exist** — the highest is `10.21.3`. The documented
install sequence would have failed for every reader.

Corrected to `10.21.3`, after which `mkdocs build --strict` completed in 2.22 s with no
warnings. The other three pins were genuine.

A pin is a testable claim. This one had not been tested, and the comment asserting otherwise made
it worse.

## What the examples validated

Every script under `examples/` was executed against the live stack, which is what promotes the
recipes' commands from "derived" to "run":

| Example | Result |
|---|---|
| `01-localai` | pass — and surfaced the `max_tokens` finding above |
| `02-embeddings` | pass — 384 dims, magnitude 0.9999999536, 0.868 vs 0.540 |
| `03-localrecall` | pass — full round trip; surfaced the `Similarity` correction |
| `04-agent` | pass — chaining works; unknown id returns 200 with no history |
| `05-agent-tools` | pass — two correct tool calls; **this run the narration was also correct**, unlike the earlier one |
| `06-agent-memory` | pass — retrieval hop 32.18 ms, timestamps matched on both sides |
| `07-mcp` | **not run** — no MCP server; templates only, and the README says so |
| `08-full-stack` | pass — `adjustment: 42`, **2 model calls**, **1 retrieval call** |

Example 05 is worth noting: the same prompt that earlier produced *"increased by 7 to 14"*
produced a correct summary this time. **The narration error is non-deterministic**, which makes
it worse to rely on, not better.

Example 08 confirmed the boundary arithmetic directly: one client request, two model calls, one
retrieval call — so **retrieval happens once per request, not once per iteration.**

## Bugs found in our own tooling by running it

Recorded because they are the reason `verify-stack.sh` can be trusted.

| Bug | Fix |
|---|---|
| macOS bash 3.2 + `set -u` + `"${empty_array[@]}"` → `unbound variable` | `${arr[@]+"${arr[@]}"}` |
| `wc -l` undercounts a final line with no trailing newline | `grep -c '.'` |
| Greedy `sed` on `"id":"…"` captures the **last** id (`msg_…`), not the response id | `jq -r '.id'` |
| `check-links.py`: `[*_]` emphasis regex ate intra-word underscores | word-boundary-only underscore emphasis |
| `check-links.py`: underscores collapsed to hyphens in slugs | only whitespace collapses |
| `check-links.py`: inline code parsed as links | strip code spans before link extraction |

The third bug is instructive: it briefly produced what looked like a real finding
("`previous_response_id` doesn't work") that was purely an extraction error.

## Not executed

Recorded so the gaps are explicit. Every page describing these is source-verified, not tested.

| Configuration | Status |
|---|---|
| LocalAGI v2.9.0 in any form | no published image; not built from source |
| Embedded in-process knowledge layer | absent from v2.8.1 |
| LocalAGI `/api/collections` | absent from v2.8.1 |
| `chromem` engine | only `postgres` was exercised |
| Hybrid search weight tuning | engine used; weights not varied |
| MCP servers, any kind | not executed |
| Multi-agent delegation | not executed |
| Long-term memory write-back | observed disabled |
| Any GPU configuration | none available under Docker on macOS |
| Kubernetes | not executed |
| linux/amd64 | not executed |
| Distributed mode (NATS) | not executed |
| Multiple replicas of anything | not executed |

## Pass 3: linux/amd64 with a CUDA GPU

A second host became available: **Ubuntu 24.04.3 amd64, NVIDIA Quadro RTX 6000 (24 GB, driver
590.44.01), Docker 29.7.2**, running `localai/localai:v4.8.2-gpu-nvidia-cuda-12` — the same build
commit as passes 1 and 2.

It was **someone's working host**, with their own large MoE models resident. Scope was therefore
deliberately limited: read-only inspection, plus lightweight inference against an
**already-resident** model. Nothing was installed, removed or restarted. That constraint is worth
recording because it shaped what could be learned — no cold-start or eviction measurements.

This pass closed two of the biggest gaps in the matrix (`linux/amd64 anything` and
`any GPU configuration`) and produced most of the material for
[the model runtime abstraction](../docs/07-deep-dives/model-runtime-abstraction.md).

### Backends really are OCI artifacts

`/backends/cuda12-llama-cpp/metadata.json`:

```json
{"alias":"llama-cpp","name":"cuda12-llama-cpp",
 "uri":"quay.io/go-skynet/local-ai-backends:latest-gpu-nvidia-cuda-12-llama-cpp",
 "digest":"sha256:a7524ea57df8d085b603db428c5f5cc62d0c5dfceff38a4195de0fa18ffcbe50",
 "installed_at":"2026-08-15T18:32:35Z"}
```

`alias: llama-cpp` is the mechanism that makes `backend: llama-cpp` in a model YAML portable across
hardware. The `uri` is a container image, pinned by digest.

### The naming trap: `llama-cpp-cpu-all` on a GPU

The resident process was:

```text
/backends/cuda12-llama-cpp/lib/ld.so \
  /backends/cuda12-llama-cpp/llama-cpp-cpu-all --addr 127.0.0.1:45479
```

…and `nvidia-smi` attributed **3136 MiB of VRAM to that PID**.

`run.sh` explains it: `cpu-all` means "**all CPU microarchitecture variants in one binary**" —
ggml's registry `dlopen`s the best `libggml-cpu-*.so` — not "CPU-only". The bundle's `lib/` holds 67
libraries: 13 `libggml-cpu-*.so` variants *and* `libcublas`/`libcudart` 12.8.

This refined a claim in both GPU pages. "A `cpu-llama-cpp` directory means CPU" is still right; "a
`cpu-all` **binary** means CPU" would have been wrong, and is exactly the mistake a reader doing
`ps aux` would make. Both pages now say to judge by the directory.

### Hardware auto-tuning, and the OOM it causes

An undocumented-by-us variable surfaced in the log:

```text
INFO effective runtime tuning (override in the model YAML;
     LOCALAI_DISABLE_HARDWARE_DEFAULTS=true disables hardware auto-tuning)
     modelID="qwen3-coder-30b-a3b-instruct" context=8192 n_batch=512
     n_gpu_layers=99999999 parallel="4" flash_attention="auto" f16=false
```

`n_gpu_layers=99999999` means "offload everything", and on a 24 GB card that fails loudly:

```text
ggml_backend_cuda_buffer_type_alloc_buffer: allocating 17524.43 MiB on device 0:
cudaMalloc failed: out of memory
```

An 80B model asked for **46,297 MiB**. Both failures were recurring in this host's log — a real
operator hitting a real limit, not a contrived test.

`core/config/hardware_defaults.go` documents the mechanism, including a specific heuristic
(`BlackwellPhysicalBatch = 2048` for sm_12x, measured upstream on a GB10) and the fact that the
tuner is parameterised on a GPU *descriptor* so the distributed router can pass a remote node's GPU.

### The operator's own workaround: MoE expert offload

The host's working configurations solve the OOM by placing expert tensors in system RAM:

```yaml
# 80B MoE: all experts on CPU
gpu_layers: 999
options: [use_jinja:true, "tensor_buft_overrides:exps=CPU"]
```

```yaml
# 30B MoE: experts from block 16 up on CPU, plus a quantised KV cache
gpu_layers: 999
flash_attention: true
cache_type_k: q8_0
cache_type_v: q8_0
options: [use_jinja:true, "tensor_buft_overrides:blk\\.(1[6-9]|[2-9][0-9])\\.ffn_.*_exps\\.=CPU"]
```

Result: an 80B MoE model **resident on a 24 GB card** — 3136 MiB VRAM, ~46 GB RSS.

`tensor_buft_overrides` has **zero matches in LocalAI's Go tree**, yet it works. So `options:` is
opaque passthrough to the backend — the abstraction's escape hatch, and also unvalidated: a typo is
silently ineffective.

### Two corrections to earlier claims

**Response IDs.** LocalAI's Chat Completions returns a **bare UUID**
(`20f92f49-a575-4220-81e8-d1b7a8769c76`, `object: chat.completion`), not `chatcmpl-…`. An earlier
draft presented the bare-UUID divergence as LocalAGI-specific; it is ecosystem-wide. Corrected in
[Responses vs Chat Completions](../docs/07-deep-dives/responses-vs-chat-completions.md).

**Resident models are observable.** `observability.md` listed "which models are resident" as
unavailable. `GET /system` provides exactly that:

```json
{"backends":["llama-cpp","cuda12-llama-cpp"],
 "loaded_models":[{"id":"qwen3next-80b-moecpu","backend":"llama-cpp"}]}
```

It is admin-gated, and it also shows the alias beside the resolved variant.

### A near-miss worth recording

Probing un-prefixed aliases with `-d '{}'`, `/embeddings` returned 404 and was briefly recorded as
"not aliased". It **is** aliased: the 404 was `model "" not found` — the same error `/v1/embeddings`
gives. Only re-probing with a named model showed both forms returning identical bodies.

**A 404 from a JSON API can mean "no such route" or "no such object".** Read the body before
concluding. The corrected finding is that aliasing is *selective*: `/chat/completions`,
`/embeddings`, `/images/generations`, `/audio/transcriptions`, `/responses` and `/messages` are
aliased; `/completions`, `/rerank` and `/tokenize` are not.

### Also confirmed

| Claim | Result |
|---|---|
| `/v1/chat/completions` streaming | **works** — SSE, `object: chat.completion.chunk` |
| Chat Completions `usage` | **real** — `{"prompt_tokens":11,"completion_tokens":1,"total_tokens":12}` |
| `GET /v1/models/capabilities` | per-model capabilities and modalities |
| `GET /v1/responses/{id}` | exists on LocalAI, OpenAI-shaped 404; **absent** on standalone LocalAGI |
| `/v1/messages` | route present (Anthropic shape); not exercised |
| Ephemeral loopback gRPC port | `--addr 127.0.0.1:45479` |
| cogito runs inside LocalAI | `ERROR Error executing cogito error=failed to get relevant guidelines` |
| Swagger path count on amd64 | 111, matching arm64 |

### Still not validated after pass 3

| Configuration | Status |
|---|---|
| ROCm, Intel SYCL, Vulkan, Metal | only CUDA 12 was available |
| Cold start / model install on GPU | deliberately not attempted on someone's working host |
| Eviction under GPU memory pressure | same |
| LocalAGI or LocalRecall on amd64 | neither is deployed there |
| Distributed llama.cpp (`LLAMACPP_GRPC_SERVERS`) | binary present in the bundle, not exercised |
| Kubernetes | still not executed |

## Pass 4: Kubernetes

A k0s v1.34.3 cluster became available: 4 nodes (one bare-metal amd64 with the GPU, three VMs),
Ubuntu 24.04.3, **Longhorn** as the default StorageClass, **Traefik** as the ingress controller,
and **no GPU device plugin installed**.

This pass moved `kubernetes/` from "not yet validated" to tested — and found **three defects that
the Compose environment could not have revealed**, which is the most useful thing this pass
produced.

### Defect 1: PostgreSQL cannot create its data directory

First deployment, immediate `CrashLoopBackOff`:

```text
initdb: error: could not create directory "/var/lib/postgresql/data/pgdata": Permission denied
```

A dynamically provisioned Longhorn volume arrives root-owned; the image runs unprivileged. Probing
the image with a `sleep` pod:

```text
uid=999(postgres) gid=104(postgres) groups=104(postgres),102(ssl-cert)
```

**gid 104, not 999.** Assuming uid == gid would have produced a wrong `fsGroup` and the same
failure. Fixed with `runAsUser: 999`, `runAsGroup: 104`, `fsGroup: 104`.

Compose never hits this because the entrypoint starts as root and chowns the volume itself.

### Defect 2: our own documented trap, applied to only one of three services

`security.md` already warned that enabling `LOCALAGI_API_KEYS` breaks LocalAGI's healthcheck. We
applied that lesson to LocalAGI's probe and **not** to the other two. With placeholder keys set:

| Service | Result |
|---|---|
| LocalAI | `0/1 Running` **forever** |
| LocalRecall | **liveness-killed**, 5 restarts |
| LocalAGI | fine — its probe carried a header |

```json
{"uri":"/api/collections","user_agent":"kube-probe/1.34","status":401}
```

The structural cause is worth stating: **a Kubernetes `httpGet` probe cannot read a Secret.** And
for LocalRecall there is *no* solution — `FROM scratch` rules out `exec` probes, and `httpGet`
cannot carry a secret token. Options are hardcode, drop the probes, or leave inbound auth off.

Two changes followed: the shipped Secret now defaults to **empty keys** with the enabling
procedure documented, and LocalRecall has **readiness only** — because a 401 liveness probe is a
permanent restart loop where a 401 readiness probe merely degrades.

Writing a warning is not the same as applying it. This one cost two deployment cycles.

### Defect 3: node inotify exhaustion kills LocalAI mid-request

The subtlest, and the one with the least helpful error message. Every workload Ready,
`/v1/models` correct, and then the **first inference request** returned an empty body while the
pod exited 1:

```text
2026/08/17 18:15:32 FATAL -- failed to create Watcher
github.com/hpcloud/tail/util.Fatal(…)
github.com/hpcloud/tail/watch.(*InotifyTracker).run(…)
```

LocalAI tails its backend's log via `hpcloud/tail`, which needs an inotify **instance**; when the
node has none, `util.Fatal` kills the process. The startup log had already hinted at it:

```text
ERROR failed creating watcher error=couldn't initialize inotify: too many open files
```

"too many open files" is a red herring — file descriptors were fine. The exhausted resource is
`fs.inotify.max_user_instances`, counted **per UID**, and it was at the Linux default of **128**
on a node running **50 pods**.

Diagnosis method that isolated it: pin LocalAI to a less loaded node (14 pods) with a
`nodeSelector`. Inference worked immediately there. Moving it back to the 50-pod node after an
unrelated workload was removed (50 → 45 pods) also worked, with zero restarts.

So the finding is real but marginal — the deployment sat a few pods away from failure. The durable
fix is `sysctl fs.inotify.max_user_instances=8192`, which needs root on the node and was therefore
left to the operator.

### What then worked

After the three fixes, all four workloads Ready and `verify-stack.sh --agent` passed all seven
layers.

| Operation | Compose (arm64) | Kubernetes (amd64) |
|---|---|---|
| Chat completion, warm | ~1 s | 1 s |
| Retrieval hop | 29–37 ms | **55.7 ms**, cross-pod |
| Agent + knowledge + tool | 24.1 s | **23.7 s** |
| LocalAI restart, models in PVC | — | ~20 s to Ready |

The cross-pod boundary was proven the same way as under Compose — by matching identities rather
than assuming them. LocalRecall logged `remote_ip 10.244.172.216`; the LocalAGI pod's IP was
`10.244.172.216`.

### Two documented claims confirmed

**GPU-requesting pods stay `Pending`.** With no device plugin installed:

```text
0/4 nodes are available: 4 Insufficient nvidia.com/gpu.
preemption: 0/4 nodes are available: 4 Preemption is not helpful for scheduling.
```

`Pending`, never `CrashLoopBackOff` — exactly as `kubernetes.md` said.

**Models persist in the PVC.** LocalAI went Ready in ~20 s after pod recreation, versus roughly 15
minutes on first deployment while it downloaded.

### One claim corrected

`07-ingress.yaml` shipped `nginx.ingress.kubernetes.io/proxy-read-timeout`. The cluster runs
**Traefik**, which ignores those annotations and has **no per-Ingress read-timeout equivalent** —
its forwarding timeouts are static configuration or a `ServersTransport` CRD.

Since that timeout is load-bearing for agent requests, an ignored annotation is worse than none:
it looks correct until a request runs long. Now documented on the page.

### The general lesson

**Compose validates the application; Kubernetes validates the deployment.** Everything at the
application layer transferred unchanged — service URLs, environment variables, retrieval
behaviour, latencies. Every one of the three defects was at the platform layer: volume ownership,
probe credentials, node resource ceilings.

### Still not validated after pass 4

| Configuration | Status |
|---|---|
| GPU **in Kubernetes** | no device plugin installed on the cluster |
| Multiple replicas of anything | not attempted; LocalAGI is a singleton by design |
| Ingress actually exercised | port-forward was used throughout; Traefik routing untested |
| Backup and restore procedure | documented, never executed |
| ROCm, Intel SYCL, Vulkan, Metal | still only CUDA 12 available |

## Pass 5: GPU in Kubernetes

The operator installed the NVIDIA device plugin path with us. This closed the last major gap and
produced **three more prerequisite failures**, each with a distinct and initially misleading error.

Node: `gpu-node`, bare metal amd64, Quadro RTX 6000 24 GB, driver 590.44.01, k0s v1.34.3.

### Four prerequisites, not two

Driver and `nvidia-container-toolkit` were already present — Docker on that host ran `--gpus all`
fine. That turned out to be irrelevant: **Docker's toolkit configuration does not touch k0s's own
containerd.**

```text
Failed to create pod sandbox: failed to get sandbox runtime:
no runtime for "nvidia" is configured
```

`/etc/k0s/containerd.d/` was **empty**. A stock k0s worker has no nvidia runtime.

### Failure: the drop-in silently did nothing

First attempt put the *RuntimeClass YAML* into `/etc/k0s/containerd.d/` — my fault for shipping two
similarly named files (`00-runtimeclass.yaml` and `containerd-nvidia.toml`) without saying which
goes where. k0s ignored it, and `k0sworker` had not been restarted either
(`ActiveEnterTimestamp` was three months old).

Two independent silent-failure modes, now documented together:

- a drop-in **missing `version = 2`** is discarded with no error
- containerd reads drop-ins **only at startup**

The check that settles it: `grep -c nvidia /run/k0s/containerd-cri.toml` must be non-zero.

### Failure: cgroup driver mismatch

With the correct TOML in place, the runtime resolved and the failure moved one layer deeper:

```text
OCI runtime create failed: runc create failed: expected cgroupsPath to be of format
"slice:prefix:name" for systemd cgroups, got "/kubepods/besteffort/pod<uid>/<id>" instead
```

I had written `SystemdCgroup = true`, carrying over the kubeadm-typical default. **k0s uses
cgroupfs.** The error itself contains the proof: the path it *received* is cgroupfs format.

Set `false`, restart, and the plugin came up:

```text
Detected platform: nvml
Registered device plugin for 'nvidia.com/gpu' with Kubelet
```

`nvidia.com/gpu` capacity=1, allocatable=1.

### Failure: liveness probe kills the 1.8 GiB backend download

The most valuable of the three, because it is latent on CPU and only bites on first GPU deployment.

After switching to the CUDA image and discarding the backends PVC, the pod ran but never became
Ready — and restarted repeatedly:

```text
Downloading … quay.io/go-skynet/local-ai-backends:latest-gpu-nvidia-cuda-12-llama-cpp
  current="1.5 GiB" total="1.8 GiB" percentage=85.25
…
Liveness probe failed: Get "http://10.244.172.235:8080/readyz": connect: connection refused
```

**5 restarts**, each discarding an 85%-complete 1.8 GiB download.

The mechanism: model and backend installation happens **before** the HTTP listener starts, so
`/readyz` refuses connections for the duration. My liveness probe (30 s delay, 6 × 15 s) killed the
container at ~120 s. The CPU backend is small enough to finish inside that window — which is
exactly why this never appeared in passes 1–4.

Fix is the textbook one: a **`startupProbe`**, which suspends liveness and readiness until the app
starts once.

```yaml
startupProbe:
  httpGet: { path: /readyz, port: 8080 }
  periodSeconds: 15
  failureThreshold: 120      # 30 minutes
```

Result: Ready in ~3 minutes, **zero restarts**.

### The GPU was then genuinely in use

Three independent confirmations, because the image tag alone proves nothing:

```text
/backends            →  cuda12-llama-cpp
log                  →  capability="nvidia-cuda-12"
nvidia-smi           →  1223419, /backends/cuda12-llama-cpp/lib/ld.so, 2194 MiB
```

Note VRAM read **0 MiB** until the first inference request — LocalAI starts the backend process
lazily, so an idle GPU is not evidence of a broken setup. That briefly looked like a failure.

### Measured, and one claim corrected

Same node, same model, same prompt, same 200-token cap, warm:

| Workload | CPU | GPU | Speed-up |
|---|---|---|---|
| 200-token completion | 6.67 / 6.78 s | **1.41 / 1.50 s** | ~4.5x |
| Throughput | ~30 tok/s | ~142 tok/s | ~4.7x |
| Agent: knowledge + tool | 23.7 s | **2.12 s** | **~11x** |

Both GPU pages previously said a GPU helps agent wall-clock **"only partly"**, reasoning that it
cannot reduce the number of model calls. That reasoning is sound and the conclusion was wrong: 11x
is not "partly". Corrected in `docs/01-localai/gpu.md` and `docs/06-deployment/gpu.md`.

The advice to *count model calls* before buying hardware still stands — six calls where two would
do is a prompt problem no device fixes — but it should not have been used to downplay the device.

### Still not validated after pass 5

| Configuration | Status |
|---|---|
| ROCm, Intel SYCL, Vulkan, Metal | only CUDA 12 hardware available |
| Multi-GPU, or more than one GPU pod | one device in the cluster |
| GPU under memory pressure / eviction | not attempted |
| Ingress actually exercised | port-forward used throughout |
| Backup and restore | documented, never executed |

## Pass 6: MCP over HTTP

Closed one of the two remaining unvalidated recipes. The `time` server was chosen deliberately as
the MCP equivalent of Recipe 5's `counter`: deterministic, no credentials, no side effects, and
verifiable arithmetic — so the recipe tests *the boundary* rather than an interesting tool.

### The finding that shaped the whole recipe

Before writing anything, I checked what runtimes exist inside the LocalAGI image:

```text
node MISSING    npx MISSING    python3 MISSING    uvx MISSING
bash /usr/bin/bash   curl /usr/bin/curl   docker /usr/bin/docker   git /usr/bin/git
```

stdio MCP servers are **child processes of LocalAGI** (`exec.Command`, `mcp.go:193-198`). So the
entire `npx @modelcontextprotocol/server-*` and `uvx mcp-server-*` ecosystem — which is most
reference servers — **cannot run as stdio children as shipped.**

That is a significant, undocumented constraint on MCP with LocalAGI, and it inverted the plan: HTTP
transport is not merely nicer architecture here, it is the practical default.

Reading the transport code also settled what LocalAGI speaks
(`core/agent/mcp.go:158-166`, go-sdk v1.2.0): `StreamableClientTransport` first, falling back to
`SSEClientTransport`. Either works.

And a third thing surfaced that I had documented as a field but not understood:
`mcp_prepare_script` runs `/bin/bash -c <script>` **before** MCP setup (`mcp.go:184`) — which is
exactly the hook for installing a runtime or fetching a static binary. That is the escape hatch for
stdio.

### Dead end: mcp-proxy's own image has no uvx

`mcp-server-time` is stdio-only — documented as `docker run -i`, no `--transport` flag. So a bridge
was needed. First attempt used the obvious image with the documented invocation:

```text
args: ["--host=0.0.0.0", "--port=8080", "--", "uvx", "mcp-server-time"]
->  FileNotFoundError: [Errno 2] No such file or directory: 'uvx'
```

`ghcr.io/sparfenyuk/mcp-proxy:v0.12.0` does not bundle `uv` either, despite its README's examples
using `uvx`. Fixed by using `python:3.13-slim` and pip-installing both packages, then pinning the
resolved versions: **mcp-proxy 0.12.0, mcp-server-time 2026.8.18**.

Worth noting the resulting pod installs packages at startup, so it needs network at boot. Fine for
a documented lab recipe; bake an image for anything long-lived, and the manifest says so.

### Failure: discovery ordering, caught live

The first agent creation raced the server rollout by four seconds:

```text
23:24:51  ERROR Failed to connect to MCP server via SSEClientTransport
                error="dial tcp 10.96.16.69:8080: connect: connection refused"
23:24:51  INFO  Done populating actions from MCP Servers
23:24:51  INFO  Agent started name=mcp-probe
23:24:55  [mcp-time] Serving MCP Servers via SSE: http://0.0.0.0:8080/sse
```

The agent **started successfully with no MCP tools** and answered requests normally without them.
Tools are not re-discovered later; deleting and recreating the agent fixed it.

This confirms a claim the recipe had made from source before this pass — "a missing MCP server is a
startup problem" — and upgrades it from inference to observation. It also has a real operational
consequence in Kubernetes, where pod start order is not guaranteed.

### Both tools worked

```text
get_current_time {"timezone":"Asia/Tokyo"}
  -> {"timezone":"Asia/Tokyo","datetime":"2026-08-22T08:26:14+09:00",
      "day_of_week":"Saturday","is_dst":false}
  agent: "The current time in Asia/Tokyo is 08:26 AM (Saturday, 22 August 2026)."   2.6 s

convert_time {"source_timezone":"Europe/Rome","target_timezone":"America/New_York","time":"09:00"}
  agent: "03:00 ... -6.0h"
```

The conversion is correct: in August Rome is UTC+2 and New York UTC−4, so six hours. Checking that
mattered — a plausible-looking wrong answer from a 1.7B model is exactly the failure mode Recipe 5
found, and here the arithmetic came from the tool rather than the model.

### The boundary, proven not assumed

Same technique as every other hop in this handbook — match identities rather than trust the story:

```text
[mcp-time] INFO: 10.244.172.216:53246 - "POST /messages/?session_id=9337da7bba…" 202 Accepted
$ kubectl get pod -l app=localagi -o jsonpath='{...podIP}'  ->  10.244.172.216
```

Also a useful transport detail for anyone reading a server's access log: on SSE, client→server
messages arrive as `POST /messages/?session_id=<id>` while responses go back on the open stream. So
you look for POSTs, not GETs.

### Confirmed: History does not distinguish MCP from built-in

The `get_current_time` entry in `/api/agent/<name>/status` has the same shape as `counter`'s in
Recipe 5 — no marker that one crossed a process boundary. That is the design, and it is precisely
why MCP is a **trust** boundary rather than a **permission** boundary.

### A method note

`kubectl exec … curl --max-time 5 <sse-url>` exits **28 (timeout)** on success, because an SSE
endpoint holds the connection open. I nearly recorded that as a failure. The failure you are
actually looking for is `connection refused`.

### Still not validated after pass 6

| Configuration | Status |
|---|---|
| stdio MCP transport | not executed — needs a runtime in the image or a static binary |
| An MCP server with side effects (filesystem, fetch) | not executed; recommended as the next step |
| MCP with a bearer token | not executed — the server was unauthenticated |
| Multi-agent delegation (Recipe 9) | **the last unvalidated recipe** |
| ROCm, Intel SYCL, Vulkan, Metal | only CUDA 12 hardware |

## Pass 7: multi-agent delegation

The last unvalidated recipe. Two things were tested: the safe coordinator/specialist pattern, and
cross-model routing.

### Reading the schema first was the highest-value step

```json
{"Name": "call_agent",
 "Properties": {"agent_name": {"enum": ["k8s-probe","mcp-probe","unit-converter","coordinator"]},
                "message": {"type": "string"}},
 "Description": "Use this tool to call another agent. Available agents and their roles are:\n\t- k8s-probe: …"}
```

Four findings in one response:

1. The action key is `call_agents`; the **tool** is `call_agent` (singular). You configure one name
   and read the other in `History`.
2. `agent_name` is an **`enum`** — so an agent name **cannot be hallucinated**, the same
   constrained-choice trick cogito uses for tool names. The `message` is unconstrained text.
3. **With no config, all four pool agents were offered — including the coordinator itself.** This
   is the concrete confirmation of the security claim that an unconfigured `call_agents` grants the
   whole pool.
4. The `Description` embeds each agent's `description` field, which was empty for the older test
   agents. Setting `description` is how the coordinator knows what to pick — a practical detail
   the source alone did not make obvious.

Passing config straight to the definition endpoint demonstrated the control cleanly:

```text
{}                                        -> ["k8s-probe","mcp-probe","unit-converter","coordinator"]
{"whitelist":"unit-converter"}            -> ["unit-converter"]
{"blacklist":"k8s-probe,mcp-probe"}       -> ["unit-converter","coordinator"]
```

### Delegation worked, and a draft claim was wrong

`coordinator` (only tool: `call_agents`, whitelisted) delegating to `unit-converter` (no tools):

```text
Action taken: call_agent
Parameters: {"agent_name":"unit-converter","message":"Convert 12 kilometres to miles."}
Result: 7.456 miles
```

Correct, and **10.6 s cold / 7.5 s warm**.

The draft recipe said to verify delegation by checking "the specialist's own `History`". **That is
empty** — because `History` records *action* results and this specialist has no actions.
`History` is "what tools the agent called", not "what the agent did". The proof lives in the log:

```text
23:39:40 DEBUG Agent Ask()        agent=unit-converter model=qwen3-1.7b
23:39:49 DEBUG Agent has finished agent=unit-converter
23:39:50 DEBUG Agent has finished agent=coordinator
```

Also visible there: the specialist's own loop took ~9 s of the 10.6 s. **Most of a delegated
request is the specialist's work, not the routing.**

### The coordinator rewrites the question

Not something the source made obvious. Given a prose question about requests per second, the
coordinator delegated:

```text
{"agent_name":"deep-thinker","message":"Calculate 47 requests/second * (3*3600 + 25*60) seconds."}
```

So delegation passes a **message the coordinator composed**, not the user's text. Useful to know
before relying on exact wording reaching a specialist.

### Cross-model routing works — and did not help here

`router` on qwen3-1.7b delegating to `deep-thinker` on qwen3-4b, confirmed by the `model=` field on
each agent's `Ask()` line. **37.5 s cold, 7.8 s warm** — so the cold figure was almost entirely the
qwen3-4b load, and cross-model overhead once resident is negligible (7.8 s vs 7.5 s same-model).

The honest part: the test question (47 req/s over 3 h 25 min = **578,100**) was chosen expecting
the 1.7B model to get it wrong. **It got it right.** So the routing *mechanism* is validated and no
quality gap was demonstrated. Recorded as such in the recipe rather than quietly swapping in a
question that would have failed — the pattern's value depends on a workload we did not have.

### Three models resident, no eviction

```text
qwen3-1.7b 2202 MiB + granite 234 MiB + qwen3-4b 4850 MiB = 7294 MiB of 24576
```

Three backend processes coexisting. Useful counterweight to the eviction discussion in
`scaling.md`: eviction is a **memory-pressure** behaviour, not an every-second-model rule.

### Not verified

Whether an **A→B→A delegation cycle** is refused. The source records the calling agent's own name,
and the definition endpoint has no agent context so it cannot show that filtering. Testing it
properly means risking a runaway loop on a shared GPU, which was not worth the marginal value — the
structural answer (only one agent gets `call_agents`) makes it moot.

### Still not validated after pass 7

All nine recipes are now tested. What remains is environmental:

| Configuration | Status |
|---|---|
| ROCm, Intel SYCL, Vulkan, Metal | only CUDA 12 hardware available |
| Multi-GPU, or more than one GPU pod | one device in the cluster |
| stdio MCP transport | needs a runtime in the image or a static binary |
| MCP with a bearer token, or a side-effecting MCP server | not executed |
| Delegation cycles | not tested, deliberately |
| Ingress actually exercised | port-forward used throughout |
| Backup and restore | documented, never executed |
| Multiple replicas of anything | LocalAGI is a singleton by design |

## Pass 8: Ingress

Date: 2026-08-22. The last item on the "not validated" list that the environment could actually
close. Everything up to here had used `kubectl port-forward`, which bypasses the ingress
controller entirely — so nothing about routing, hostnames or proxy timeouts had ever been
exercised.

### The shipped manifest had never been usable

Reading `kubernetes/07-ingress.yaml` before applying it found two things that made it a
non-starter, and both are the kind of defect that only surfaces when you try to use the file:

1. Every annotation was `nginx.ingress.kubernetes.io/*`. The cluster runs **Traefik**. Traefik
   does not read them and does not complain about them.
2. The host was `agents.example.com` — a placeholder. Applying the file produced a valid Ingress
   object that could never be reached.

An Ingress with a wrong host and ignored annotations reports `Ready` and shows an address. There
is no error to find. This is the failure mode the handbook keeps returning to: **the object being
accepted is not evidence the thing works.**

### sslip.io removes the DNS prerequisite

The cluster's internal zone uses **per-host** records, not a wildcard — hosts already in it
resolved, a newly chosen `localai.<zone>` did not. So testing the ingress required either
editing a DNS zone or editing `/etc/hosts`, neither of which belongs in a handbook manifest.

The fix was to give every Ingress **two** hostnames:

```yaml
  rules:
    - host: localai.example.com
      http: &localai_backend
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: localai
                port:
                  number: 8080
    - host: localai.192.0.2.10.sslip.io
      http: *localai_backend
```

`sslip.io` answers any `<anything>.<ip>.sslip.io` with that IP, so the second host works through
public DNS with zero configuration. The YAML anchor means the backend is written once — a copy of
the block would be a place for the two hosts to silently diverge.

Verified through the ingress, no port-forward anywhere:

```text
localai.<ip>.sslip.io      /readyz        -> 200
                           /v1/models     -> granite, qwen3-1.7b, qwen3-4b
                           /system        -> 3 backends loaded
localagi.<ip>.sslip.io     /api/agents    -> 6 agents
localrecall.<ip>.sslip.io  /api/collections -> ["k8s-probe"]
```

Then the real check — `scripts/verify-stack.sh --agent coordinator` with all three `*_URL`
variables pointed at the ingress hostnames. **All seven layers passed**, including the full
ingest → chunk → embed → store → search round trip and a 2 s agent request. That is the first
time the stack has been exercised the way a user outside the cluster would reach it.

### A claim in the handbook was too strong

`docs/06-deployment/kubernetes.md` framed the ingress read timeout as a general hazard: agent
requests take longer than 60 s, ingress controllers default to 60 s, so requests get cut off and
look like agent failures. Correct for ingress-nginx. **Wrong as a universal claim.**

Trying to demonstrate it failed to produce the symptom:

| Attempt | Result |
|---|---|
| 4000-token essay | 36 s, `finish_reason: stop` |
| 7000-token forced output | 24 s (~290 tok/s) |
| Cross-model delegated agent request | 18 s |

Nothing on this hardware would run past 60 s — the GPU is too fast, which is a good problem to
have and a bad one for testing a timeout. So the question moved from measurement to Traefik's
documented defaults:

| Setting | Default | What it actually covers |
|---|---|---|
| `respondingTimeouts.readTimeout` | 60 s | reading the **request** — irrelevant for a small JSON body |
| `respondingTimeouts.writeTimeout` | **0 — unlimited** | writing the **response**; this is the one that would cut off a slow backend |
| `respondingTimeouts.idleTimeout` | 180 s | idle keep-alive connections |

So **Traefik does not cut off a slow agent request by default**, and the "raise the timeout" advice
is ingress-nginx-specific. The page now carries a two-row table naming which controller needs the
change and which does not, and states plainly that beyond 60 s rests on the documented default
rather than on our measurement.

The generalisable lesson is smaller than the timeout: `readTimeout` and `writeTimeout` sound
interchangeable and are not. A reader tuning `readTimeout` to fix a truncated response would
change nothing and conclude the setting was ignored.

### Publishing all three is a security decision, not a convenience

Applying the file exposes, unauthenticated:

| Service | What the ingress grants |
|---|---|
| LocalAI | model install and **delete** via `/models/apply`, `/models/delete` |
| LocalRecall | collection read **and write** — knowledge-base poisoning, which the agent then reads as fact |
| LocalAGI | agent creation — **remote code execution** if `shell-command` is available |

The narrow choice is LocalAGI only; the other two are reachable in-cluster by service name and do
not need to be published. The file publishes all three because that is what was asked for and what
was tested, with the trade-off stated in a header block.

Enabling the services' own API keys is **not** the mitigation here — pass 4 established that it
breaks every probe. So `kubernetes/07-ingress-basic-auth.yaml` adds a Traefik `Middleware` with
`basicAuth` instead, which sits in front of the ingress and leaves probes untouched. It contains
no credential; the secret is generated with `htpasswd -nbB`. The middleware reference is commented
out in the Ingress, because an annotation naming a middleware that does not exist would 404 every
request.

One trap worth stating: the annotation value needs the provider suffix,
`localai-stack-basic-auth@kubernetescrd`. Get the namespace or the suffix wrong and Traefik does
not error — it ignores the middleware and serves the route unauthenticated. Which is the same
shape as defect 2 from pass 4 and as the `agents.example.com` host above: **the security control
that was silently not applied looks exactly like the one that was.**

### Still not validated after pass 8

| Configuration | Status |
|---|---|
| ROCm, Intel SYCL, Vulkan, Metal | only CUDA 12 hardware available |
| Multi-GPU, or more than one GPU pod | one device in the cluster |
| stdio MCP transport | needs a runtime in the image or a static binary |
| MCP with a bearer token, or a side-effecting MCP server | not executed |
| Delegation cycles | not tested, deliberately |
| A request longer than 60 s through an ingress | GPU too fast to produce one; 36 s is the maximum reached |
| TLS on the ingress | HTTP only; no certificate issuer in the cluster |
| The basic-auth middleware in use | manifest validated with `--dry-run`, never enabled |
| Backup and restore | documented, never executed |
| Multiple replicas of anything | LocalAGI is a singleton by design |

## Pass 9: Pattern A — retrieval inside LocalAI

Date: 2026-08-22. Prompted by a direct question: chat in LocalAI and have it use the
collections already in LocalRecall. The answer turned out to be no, for a reason worth the
whole pass.

### Reading `--help` first settled the architecture

Before touching anything, `local-ai run --help` on the running v4.8.2 container. The `agents`
flag group is the answer:

```text
--agent-pool-vector-engine="chromem"
--agent-pool-embedding-model="granite-embedding-107m-multilingual"
--agent-pool-database-url=STRING
--agent-pool-collection-db-path=STRING
--agent-pool-max-chunking-size=400
--agent-pool-chunk-overlap=0
```

Every one of those is a LocalRecall configuration knob with a prefix. LocalAI links
LocalRecall as a library; it does not call it. Grepping the full help for `localrag`,
`recall`, `rag-url` and `remote` returned nothing.

So the initial answer was: not possible, choose a pattern. That answer was right, but I
nearly abandoned it for the wrong reason — see below.

### The per-agent field that reopened and then closed the question

With the pool enabled, `GET /api/agents/{name}/config` returns 57 fields, two of which are
`local_rag_url` and `local_rag_api_key`. That looks like exactly the missing capability, at
agent scope rather than server scope.

It is not. Setting it to the live LocalRecall service returned `201`, and reading the config
back showed the value stored. Three observations killed it:

```text
INFO Starting agent name="k8s-probe" config=&{... http://localrecall:8080 ...}
INFO Chromem collection collectionName="k8s-probe" dbPath="/data/collections"
```

A **local** chromem store, initialised with the remote URL present in the very same config
dump. Then the standalone LocalRecall's access log across the entire window — every entry
`curl/8.7.1` or a browser, none from the agent. Not a failed request; no request.

The confirming test was the one that made it certain. The question
*"What heartbeat interval does the Zeppelin-7 telemetry bus use?"* — a synthetic fact present
only in LocalRecall's `k8s-probe` collection — got:

```text
I do not have access to specific information about the heartbeat interval used by the
Zeppelin-7 telemetry bus.
```

Uploading the identical sentence into **LocalAI's own** `k8s-probe` collection, changing
nothing else, produced:

```text
The Zeppelin-7 telemetry bus uses a heartbeat interval of 4200 milliseconds.
```

The field is inherited from the shared LocalAGI agent config struct, where it is honoured.
Same shape as the LocalAGI defect where embeddings do not follow `api_url`.

The lesson generalises past this field: **in this codebase a URL that is accepted and stored
is not evidence that anything reads it.** Two of the three checks above were cheap — read the
log at agent start, read the *target's* access log. Neither requires understanding the code.
Checking the callee's log for the absence of a call is the highest-value verification here,
because a silently-ignored config produces no error anywhere on the caller's side.

An absent option would have been better. An absent option makes you find another way.

### The empty-KB failure is invisible

Before seeding the collection, every answer was a confident denial. The cause:

```text
INFO Error finding similar strings inside KB: error=nResults must be <= the number of
     documents in the collection
INFO [Knowledge Base Lookup] No similar strings found in KB agent="k8s-probe"
```

`chromem` errors rather than clamping when `kb_results` exceeds the document count — and an
empty collection has zero documents, so *any* `kb_results` fails. Both lines are **INFO**.
Nothing at ERROR, HTTP 200 throughout, and the model denies knowledge fluently.

This is the third time in this project that a retrieval failure has been logged at INFO. It
is a consistent property of the stack, not an accident, and it is why
`verify-stack.sh` asserts on a sentinel string rather than on a status code.

### Two defects in my own manifests

**`/data` was never mounted.** `--data-path` defaults to `/data` and holds `collectiondb`,
agent state, tasks and jobs. The base manifest mounted `/models` and `/backends` only, so
every collection ingested into LocalAI would have been discarded on the next rollout — with
no error, and only after someone had done the ingestion work. Added `localai-data` as a PVC.
Note this was latent in Pattern B too; enabling agents merely made it reachable.

**The overlay patch did not apply.** First attempt:

```text
The Deployment "localai" is invalid: spec.template.spec.containers[0].env[0].valueFrom:
Invalid value: "": may not be specified when `value` is not empty
```

`LOCALAI_DISABLE_AGENTS` comes from a ConfigMap in the base. A strategic-merge patch merges
`env` by name, so it keeps `valueFrom` and adds `value` beside it. `valueFrom: null` in the
same patch deletes the reference. Generalisable: you cannot override a `configMapKeyRef` with
a literal by merging over it.

### The API is its own thing

Established by probing, because `/swagger/doc.json` documents only `/api/agent/tasks` and
`/api/agent/jobs` — the pool CRUD is entirely undocumented.

```text
GET    /api/agents                            summary object, NOT a list
POST   /api/agents                            create -> 201
PUT    /api/agents/{name}                     update
GET    /api/agents/{name}/config              57 fields
GET    /api/agents/collections
POST   /api/agents/collections
DELETE /api/agents/collections?name=X         query param; path form is 404
POST   /api/agents/collections/{c}/upload     multipart
GET    /api/agents/collections/{c}/entries    GET only; POST is 404
POST   /api/agents/collections/{c}/search
```

The prefix is `/api/agents/collections`, so it collides with neither LocalRecall's
`/api/collections` nor LocalAGI's routes. And the envelopes differ from LocalRecall's
`{"success":..,"data":{..}}` — the two are **not** wire-compatible, which matters to anyone
expecting to repoint a client when migrating patterns.

Attempting agent creation by guessing cost several rounds. Reading the config of an
already-created agent was what actually worked, and `POST /api/agents` → 201 with
`PUT /api/agents/{name}` for update was found by testing the two obvious REST shapes rather
than by reading the SPA bundle, which turned out to serve the index fallback for its own
asset paths.

### Working result

Agent named for its collection, `enable_kb` + `kb_auto_search` + `kb_results: 1`, answering
from LocalAI's own store in **53 s cold** including the embedding backend load. No LocalAGI
and no LocalRecall in the request path. Procedure in `kubernetes/pattern-a/README.md`.

### Still not validated after pass 9

| Configuration | Status |
|---|---|
| ROCm, Intel SYCL, Vulkan, Metal | only CUDA 12 hardware available |
| Multi-GPU, or more than one GPU pod | one device in the cluster |
| stdio MCP transport | needs a runtime in the image or a static binary |
| MCP with a bearer token, or a side-effecting MCP server | not executed |
| LocalAI's agent pool on the `postgres` vector engine | only `chromem` exercised |
| One database shared by LocalAI's pool and a standalone LocalRecall | not executed — risks a schema migration under the other process |
| LocalRecall wrapped as an MCP server | proposed, not built |
| `kb_as_tools` instead of `kb_auto_search` | not executed |
| Embedded knowledge layer on **LocalAGI** | still absent from v2.8.1 |
| Delegation cycles | not tested, deliberately |
| A request longer than 60 s through an ingress | GPU too fast; 36 s is the maximum reached |
| TLS on the ingress, and the basic-auth middleware in use | not executed |
| Backup and restore | documented, never executed |
| Multiple replicas of anything | LocalAGI is a singleton by design |

## Open questions

1. What populates `/api/traces/summary`? It stayed at zero throughout.
2. Why does `/models/apply` with an inline `config_file` and no `url` still fetch a URL?
3. Where is `counter` state scoped, and why does a direct action run not share it with the
   agent's invocations?
4. Is an A→B→A delegation cycle prevented? Self-calls are excluded; cycles were not tested.
5. What does `LOCALAI_AUTH` / `LOCALAI_AUTH_DATABASE_URL` / `LOCALAI_AUTH_HMAC_SECRET`
   actually provide? It suggests more than a shared bearer key and is undocumented in the
   material reviewed.
6. Does `vectorscale`'s presence mean DiskANN indexes are used, or merely available?
7. Is `local_rag_url` dead everywhere in LocalAI, or honoured on some path not exercised
   here — a connector, a task, the skills service? Only the agent conversation path was
   tested.
8. Does `LOCALAI_AGENT_POOL_DATABASE_URL` produce a schema compatible with standalone
   LocalRecall v0.6.4, or does one migrate the other's tables?
