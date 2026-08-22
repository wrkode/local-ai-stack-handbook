# Version matrix

This is **our** validation record, not an upstream compatibility statement. No
upstream project publishes a cross-project compatibility matrix; this page exists
because one is needed and none is available.

A row here means we ran it and observed the result. Nothing is marked tested that
was not executed.

## Versions this handbook was written against

| Project | Version | Released | How we read it |
|---|---|---|---|
| LocalAI | **v4.8.2** | 2026-08-07 | source at tag; container reporting `v4.8.2 (5ff25d9d145e0a03a5b9a3559c620f1e1204ca6d)` |
| LocalAGI | **v2.9.0** | 2026-05-08 | source at tag |
| LocalRecall | **v0.6.4** | 2026-07-19 | source at tag |
| cogito | see below | — | source |

Validated: **2026-08-17**.

## What is actually inside LocalAI v4.8.2

The versions you get when you run LocalAI are **not** the standalone releases
above. They are pinned commits.

| Embedded component | Pinned as | Underlying commit | Commit date |
|---|---|---|---|
| LocalAGI | `v0.0.0-20260606071251-14aed1ae4336` | `14aed1ae4336` | 2026-06-06 |
| LocalRecall | `v0.6.3` (release tag) | — | 2026-06-26 |
| cogito | `v0.11.1-0.20260721122412-6eece18a6bb6` | `6eece18a6bb6` | 2026-07-21 |

Two consequences worth internalising:

**LocalAI does not embed LocalAGI v2.9.0.** LocalAGI's Go module path has no
`/v2` suffix, so Go cannot consume its `v2.x` tags at all. LocalAI can only pin
raw commits from `main`. The embedded agent platform tracks an untagged commit,
not a release.

**LocalAI links a newer LocalRecall than standalone LocalAGI does.** LocalAGI
v2.9.0 requires a pseudo-version built on a commit after v0.6.2; LocalAI requires
plain `v0.6.3`. Go's minimal version selection resolves to `v0.6.3`.

And the cogito split, which is the one that changes behaviour:

| Runs | cogito version | Date |
|---|---|---|
| LocalAI v4.8.2 | `v0.11.1-0.20260721…` | 2026-07-21 |
| LocalAGI v2.9.0 (source) | `v0.9.5-0.20260315…` | 2026-03-15 |
| LocalAGI v2.8.1 (**the only image**) | `v0.9.1-0.20260216…` | 2026-02-16 |

Roughly five months between the extremes. Capabilities present in the newer cogito — sub-agent
spawning, KV-cache prefill, self-editing system prompts, park/resume — are not
reachable from standalone LocalAGI. "Agent behaviour" therefore differs between
Pattern A and Pattern B deployments of nominally the same feature.

## Container images — verified to exist

Published registries, verified 2026-08-17:

| Project | Registry path | Note |
|---|---|---|
| LocalAI | `quay.io/go-skynet/local-ai`, mirror `localai/localai` | |
| LocalAGI | `quay.io/mudler/localagi` | see warning below |
| LocalRecall | `quay.io/mudler/localrecall` | |

None of the three publish to `ghcr.io`.

### LocalAI v4.8.2 tag suffixes

Eight, verified present:

| Tag suffix | Target |
|---|---|
| *(none)* | CPU, amd64 + arm64, 0.29 GB |
| `-gpu-nvidia-cuda-12` | CUDA 12 |
| `-gpu-nvidia-cuda-13` | CUDA 13 |
| `-gpu-hipblas` | AMD ROCm |
| `-gpu-intel` | Intel SYCL |
| `-gpu-vulkan` | Vulkan |
| `-nvidia-l4t-arm64` | Jetson |
| `-nvidia-l4t-arm64-cuda-13` | Jetson, CUDA 13 |

**All-in-one (AIO) images were removed in the 4.x line.** Older tags such as
`latest-aio-*`, `-extras`, `-ffmpeg`, `-core`, `-cuda-11` and `-intel-f16/f32`
still *resolve*, but they are frozen builds from 2026-02-21 or earlier.
`latest-cpu` is stale since 2025-06-19 and is still referenced in comments in
LocalAI's own compose file. Do not use them and do not trust a tutorial that
does.

!!! danger "The published LocalAGI image is architecturally different from v2.9.0 source"
    This is the most consequential version fact in the handbook, and it is easy to
    miss because both are called "LocalAGI".

    **LocalAGI v2.8.1 — the newest published image — does not contain LocalRecall
    at all.** Verified: zero files import `github.com/mudler/localrecall`, and it
    is absent from `go.mod`. Two capabilities that v2.9.0's source has therefore do
    not exist in any runnable LocalAGI container:

    | Capability | v2.9.0 source | v2.8.1 image |
    |---|---|---|
    | Embedded, in-process knowledge layer | yes, and it is the **default** | **absent** — retrieval is always HTTP |
    | Collections management API (`/api/collections`) | yes, 11 routes | **absent** — returns `Cannot GET /api/collections` |
    | cogito version | `v0.9.5-0.20260315…` | `v0.9.1-0.20260216…` |

    Consequences for anything you actually deploy:

    - `LOCALAGI_LOCALRAG_URL` is not an opt-in on v2.8.1; it is **required** for
      knowledge, because there is no in-process alternative to fall back to.
    - You cannot create or inspect collections through LocalAGI. Talk to
      LocalRecall directly, or use LocalAI's `/api/agents/collections`.
    - A separately deployed LocalRecall is mandatory, not a design choice.

    Observed 2026-08-17 against the running v2.8.1 image and its source tag. Pages
    describing the embedded path are marked as v2.9.0-source-only; see
    [LocalAGI ← LocalRecall](../04-integration/localagi-localrecall.md).

!!! warning "`quay.io/mudler/localagi:v2.9.0` does not exist"
    The highest published LocalAGI image tag is **`v2.8.1`**. The main image
    build has been failing since 2026-04-15 on a self-hosted runner, while the
    `localagi-sshbox:v2.9.0` image *did* publish — which makes it easy to
    conclude the main image exists when it does not. Pin `v2.8.1`.

    Consequence: **you cannot run LocalAGI v2.9.0 from a published image.** The
    source tag exists; the container does not. Build from source or accept
    v2.8.1.

## Reference models

The same two models are used throughout the beginner material, so that a failure
is attributable to your configuration rather than to a model swap.

| Role | Gallery name | Size | Dims / context | Licence |
|---|---|---|---|---|
| LLM | `qwen3-1.7b` | 1.19 GiB (Q4_K_M) | **8,192 ctx** | apache-2.0 |
| Embeddings | `granite-embedding-107m-multilingual` | 211 MiB (F16) | 384 dims | apache-2.0 |

!!! note "The context window is 8,192, not the model's native 32,768"
    Qwen3-1.7B supports 32,768 tokens natively, and that figure is what most
    write-ups quote. LocalAI's gallery entry does not use it: the shared `qwen3`
    `config_file` sets `context_size: 8192`, and the `qwen3-1.7b` entry overrides
    only `parameters.model`. The effective window on a stock install is therefore
    **8,192**. Raise `context_size` in `/models/qwen3-1.7b.yaml` if you need more.

    Sizes confirmed on disk: 1,282,439,296 bytes and 220,974,080 bytes
    respectively, observed 2026-08-17.

**Why `qwen3-1.7b`:** small enough for a CPU-only laptop, permissively licensed,
and its gallery configuration is explicitly wired for native tool calling
(`use_jinja: true`, `use_tokenizer_template: true`, function grammar disabled) —
with upstream comments citing the specific bugs that configuration avoids. Tool
calling is what makes the agent recipes work, and most small models need exactly
this treatment to do it reliably. Step up to `qwen3-4b` (2.33 GiB) if quality is
insufficient; the configuration is identical.

**Why `granite-embedding-107m-multilingual`:** it is upstream's own default in
three independent places — LocalAI's CLI default, LocalAGI's default, and both
projects' shipped compose files. Choosing anything else means diverging from
every default in the ecosystem for no benefit.

Total tutorial download: about **1.40 GiB of models**, plus the 0.29 GB CPU image
and the `llama-cpp` backend, which is pulled separately on first model install.

### Models to avoid

| Gallery name | Problem |
|---|---|
| `LocalAI-functioncall-llama3.2-3b-v0.5` | The Hugging Face repository returns **HTTP 401** to anonymous requests. The gallery entry is broken; the install fails at download. Verified 2026-08-17. |
| `bert-embeddings` | Not a BERT model. The entry resolves to Llama-3.2-1B-Instruct Q4_K_M with `embeddings: true`. A legacy alias that misleads. |

## Our validation matrix

Two passes are recorded. Pass 1 exercised LocalAI alone; pass 2 brought up the
full separated reference environment.

```yaml
tested:
  - pass: 1
    date: 2026-08-17
    versions:
      localai: "v4.8.2 (5ff25d9d145e0a03a5b9a3559c620f1e1204ca6d)"
      localagi: "not executed"
      localrecall: "not executed"
    environment:
      architecture: arm64 (Apple Silicon)
      host: macOS 26.5.1
      runtime: Docker Desktop 29.5.2
      gpu: none

  - pass: 2
    date: 2026-08-17
    versions:
      localai: "v4.8.2"
      localagi: "v2.8.1 (image)"
      localrecall: "v0.6.4 + v0.6.4-postgresql"
    environment:
      architecture: arm64 (Apple Silicon)
      host: macOS 26.5.1
      runtime: Docker Desktop 29.7.2
      deployment: compose/ reference environment, Pattern B
      vector_engine: postgres
      gpu: none

  - pass: 3
    date: 2026-08-17
    versions:
      localai: "v4.8.2 (5ff25d9d145e0a03a5b9a3559c620f1e1204ca6d), image tag v4.8.2-gpu-nvidia-cuda-12"
      localagi: "not present"
      localrecall: "not present"
    environment:
      architecture: amd64
      host: Ubuntu 24.04.3 LTS, kernel 6.8.0-88-generic
      runtime: Docker 29.7.2
      gpu: NVIDIA Quadro RTX 6000, 24576 MiB, driver 590.44.01
      backend: cuda12-llama-cpp
      note: >-
        A third-party host running LocalAI for real work. Read-only inspection
        plus lightweight inference against an already-resident model; we did not
        install, remove or restart anything.

  - pass: 4
    date: 2026-08-17
    versions:
      localai: "v4.8.2"
      localagi: "v2.8.1"
      localrecall: "v0.6.4 + v0.6.4-postgresql"
    environment:
      platform: kubernetes
      distribution: k0s v1.34.3
      nodes: 4 — 1 bare-metal amd64 + 3 VMs, Ubuntu 24.04.3
      storage: Longhorn (default StorageClass), ReadWriteOnce
      ingress: Traefik
      gpu_device_plugin: none installed
      vector_engine: postgres
    result: >-
      All four workloads Ready and all 7 verify-stack layers pass, after fixing
      three defects the Compose environment could not have revealed.

  - pass: 5
    date: 2026-08-17
    versions:
      localai: "v4.8.2-gpu-nvidia-cuda-12"
      device_plugin: "nvcr.io/nvidia/k8s-device-plugin:v0.19.3"
    environment:
      platform: kubernetes
      distribution: k0s v1.34.3
      node: gpu-node — bare metal amd64, NVIDIA Quadro RTX 6000 24 GB, driver 590.44.01
      container_runtime: containerd + nvidia-container-toolkit 1.18.1, RuntimeClass nvidia
      backend: cuda12-llama-cpp (1.8 GiB, installed on first run)
    result: >-
      GPU inference in Kubernetes. 200-token completion 6.7 s CPU -> 1.4 s GPU
      (~4.5x); agent with knowledge and a tool 23.7 s -> 2.12 s (~11x);
      2194 MiB VRAM attributed to the pod.

  - pass: 6
    date: 2026-08-17
    versions:
      localai: "v4.8.2-gpu-nvidia-cuda-12"
      localagi: "v2.8.1 (image)"
      mcp_proxy: "0.12.0"
      mcp_server_time: "2026.8.18"
      mcp_go_sdk: "v1.2.0 (pinned by LocalAGI)"
    environment:
      platform: kubernetes, k0s v1.34.3
      transport: SSE (Streamable HTTP attempted first, fell back)
    result: >-
      MCP over HTTP validated end to end with the time server. Both tools called
      correctly; boundary confirmed from the LocalAGI pod IP in the server's
      access log.

  - pass: 7
    date: 2026-08-17
    versions:
      localai: "v4.8.2-gpu-nvidia-cuda-12"
      localagi: "v2.8.1 (image)"
    environment:
      platform: kubernetes, k0s v1.34.3
      models: qwen3-1.7b and qwen3-4b, both resident
    result: >-
      Multi-agent delegation validated, same-model and cross-model. Whitelist
      demonstrated narrowing the offered agent enum from 4 to 1. This completes
      all nine recipes.
```

| # | Configuration | Deployment | Result | Notes |
|---|---|---|---|---|
| 1 | LocalAI v4.8.2, no models | Docker, CPU, darwin/arm64 | **pass** | Healthy in ~20 s. Agent pool auto-starts. |
| 2 | Model gallery listing | Docker, CPU, darwin/arm64 | **pass** | 1683 entries from `index.localai.io` |
| 3 | Install `granite-embedding-107m-multilingual` | Docker, CPU, darwin/arm64 | **pass** | Also pulled the `cpu-llama-cpp` backend |
| 4 | Install `LocalAI-functioncall-llama3.2-3b-v0.5` | Docker, CPU, darwin/arm64 | **fail** | HTTP 401 from Hugging Face. Upstream gallery defect, not a local problem. |
| 5 | `/v1/embeddings`, single input | Docker, CPU, darwin/arm64 | **pass** | 384 dims, L2-normalized, cold 3.34 s / warm 0.06–0.09 s |
| 6 | `/v1/embeddings`, batch of 3 | Docker, CPU, darwin/arm64 | **pass** | 3 vectors, correct `index` ordering |
| 7 | `/swagger/doc.json` | Docker, CPU, darwin/arm64 | **pass** | 111 paths; incomplete (`/api/agents` absent but live) |
| 8 | `/metrics`, `/api/traces/summary` | Docker, CPU, darwin/arm64 | **pass** | See [observability](../06-deployment/observability.md) for what is and is not exposed |
| 9 | Gallery model install, both reference models | Compose, CPU, darwin/arm64 | **fail** | `raw.githubusercontent.com` returned **HTTP 429**, then 503. Every gallery config fetch failed and both installs failed — while LocalAI still logged "started and running" and `/readyz` returned 200 with zero models. See [failure modes](#a-reproduced-failure-worth-knowing). |
| 10 | Backend install via `/backends/apply` | Compose, CPU, darwin/arm64 | **pass** | `llama-cpp` requested; produced both `llama-cpp` and `cpu-llama-cpp`. The backend gallery is OCI-based and unaffected by the GitHub outage. |
| 11 | `/models/apply` with inline `config_file` and no `url` | Compose, CPU, darwin/arm64 | **fail** | `Get "": unsupported protocol scheme ""`. The documented no-URL base-config form did not work as a gallery-bypass. |
| 12 | Manual install: HF weights + hand-written model YAML | Compose, CPU, darwin/arm64 | **pass** | Both models resolvable in `/v1/models` after restart. `/readyz` returned 200 ~60 s after restart. |
| 13 | `/v1/chat/completions`, `qwen3-1.7b` | Compose, CPU, darwin/arm64 | **pass** | 4 s including model load, `max_tokens: 16` |
| 14 | Full LocalRecall round trip: create, upload, search | Compose, CPU, darwin/arm64, **postgres** | **pass** | ingest 34.9 ms, search 30.4 ms, `chunk_count=1`, `chunk_overlap=80` honoured |
| 15 | LocalAGI agent, no tools, no knowledge | Compose, CPU, darwin/arm64 | **pass** | 2–3 s. `usage` returned as all zeros. |
| 16 | `previous_response_id` conversation chaining | Compose, CPU, darwin/arm64 | **pass** | History carried; each reply returns a **new** UUID |
| 17 | Unknown `previous_response_id` | Compose, CPU, darwin/arm64 | **pass (surprising)** | **No error.** Silently treated as an empty conversation. |
| 18 | Agent with a built-in tool (`counter`) | Compose, CPU, darwin/arm64 | **pass, with caveat** | 38.7 s. Two correct tool calls; the model's *narration* of the result was arithmetically wrong. |
| 19 | Agent with knowledge, all three projects | Compose, CPU, darwin/arm64, **postgres** | **pass** | 2.27 s total, retrieval hop 37.19 ms. Verified by answering an invented fact. |
| 20 | LocalAGI v2.8.1 `/api/collections` | Compose, CPU, darwin/arm64 | **fail — absent** | `Cannot GET /api/collections`. The route does not exist in v2.8.1. |
| 21 | `scripts/verify-stack.sh`, all 7 layers | Compose, CPU, darwin/arm64 | **pass** | with `--agent` |
| 22 | Compose healthchecks | Compose, CPU, darwin/arm64 | **pass** | `localai`, `postgres`, `localagi` report healthy. `localrecall` cannot have one — `FROM scratch`, no shell. |
| 23 | `qwen3-1.7b` with `max_tokens: 128` | Compose, CPU, darwin/arm64 | **fail — empty answer** | `finish_reason: length`, `content: ''`. The reasoning consumed all 128 tokens. `reasoning_content` absent. |
| 24 | `qwen3-1.7b` with `max_tokens: 600` | Compose, CPU, darwin/arm64 | **pass** | `finish_reason: stop`, correct one-sentence answer, **371 completion tokens** |
| 25 | Agent with knowledge **and** a tool | Compose, CPU, darwin/arm64, postgres | **pass** | 24.1 s; retrieved 4200, computed 42, set the counter. **2 model calls, 1 retrieval call.** |
| 26 | Knowledge layer stopped mid-flight | Compose, CPU, darwin/arm64 | **pass — and this is the warning** | HTTP 200, `status: completed`, `error: null`, and a **hallucinated** "10 seconds". Logged at INFO. |
| 27 | `examples/*/run.sh`, seven of eight | Compose, CPU, darwin/arm64, postgres | **pass** | `07-mcp` not run — no MCP server available |
| 28 | `mkdocs build --strict` | local, Python 3.9 | **pass** | 2.22 s, no warnings — **after** correcting an impossible version pin |
| 29 | `shellcheck -S warning`, all scripts | local | **pass** | |
| 30 | `pymdown-extensions==11.0.1` from `requirements-docs.txt` | local | **fail — version does not exist** | Our own defect. Highest available is `10.21.3`. Corrected. |
| 31 | LocalAI v4.8.2 on **linux/amd64** | Docker, Ubuntu 24.04, amd64 | **pass** | Same build commit as pass 1/2. First amd64 validation. |
| 32 | **CUDA 12 backend installed and used** | Docker, amd64, Quadro RTX 6000 | **pass** | `/backends` holds `cuda12-llama-cpp`; `nvidia-smi` attributes **3136 MiB** to the backend PID |
| 33 | Backend as an OCI artifact | Docker, amd64 | **pass** | `metadata.json` names `quay.io/go-skynet/local-ai-backends:latest-gpu-nvidia-cuda-12-llama-cpp` with a pinned digest, and `alias: llama-cpp` |
| 34 | Backend process and ephemeral gRPC port | Docker, amd64 | **pass** | `lib/ld.so … llama-cpp-cpu-all --addr 127.0.0.1:45479` |
| 35 | Hardware auto-tuning | Docker, amd64, GPU | **pass** | `effective runtime tuning … n_gpu_layers=99999999 n_batch=512 parallel=4 flash_attention=auto`; disabled by `LOCALAI_DISABLE_HARDWARE_DEFAULTS=true` |
| 36 | Auto-tuned load of a 30B MoE on 24 GB | Docker, amd64, GPU | **fail — CUDA OOM** | `cudaMalloc failed` allocating **17,524 MiB**. An 80B model asked for **46,297 MiB**. Caused by `n_gpu_layers=all`. |
| 37 | MoE expert offload via `tensor_buft_overrides` | Docker, amd64, GPU | **pass** | 80B MoE resident on a 24 GB card: **3136 MiB VRAM + ~46 GB RSS**. Opaque `options:` passthrough — the string appears nowhere in LocalAI's Go source. |
| 38 | `/v1/chat/completions` streaming | Docker, amd64, GPU | **pass** | SSE, `object: chat.completion.chunk` |
| 39 | Chat Completions `usage` | Docker, amd64, GPU | **pass** | **real** values — `{"prompt_tokens":11,"completion_tokens":1,"total_tokens":12}`, unlike the agent path |
| 40 | Response `id` format | Docker, amd64, GPU | **pass, surprising** | a **bare UUID**, not `chatcmpl-…`. **Corrected an earlier claim** that this was LocalAGI-specific. |
| 41 | Un-prefixed route aliases | Docker, amd64 | **pass, partial** | `/chat/completions`, `/embeddings`, `/images/generations`, `/audio/transcriptions`, `/responses`, `/messages` aliased; `/completions`, `/rerank`, `/tokenize` **not**. Aliasing is selective. |
| 42 | `GET /system` | Docker, amd64 | **pass** | reports resident models and backend aliases — **corrected** an earlier claim that residency was unavailable |
| 43 | `GET /v1/models/capabilities` | Docker, amd64 | **pass** | per-model `capabilities` and `input_modalities`/`output_modalities` |
| 44 | `GET /v1/responses/{id}` | Docker, amd64 | **pass** | OpenAI-shaped 404 with `param`/`type` — LocalAI stores responses; **standalone LocalAGI has no such route** |
| 45 | `/v1/messages` (Anthropic shape) | Docker, amd64 | **route present** | responds 400 to an empty body; the shape itself was not exercised |
| 46 | Full stack on **Kubernetes** | k0s v1.34.3, amd64, Longhorn, Traefik | **pass** | all four workloads Ready; `verify-stack.sh --agent` passes all 7 layers |
| 47 | PostgreSQL StatefulSet, first attempt | k0s, Longhorn RWO | **fail** | `initdb: could not create directory … Permission denied`, CrashLoopBackOff. Longhorn volume is root-owned; image runs uid 999 / **gid 104**. Fixed with `fsGroup: 104`. |
| 48 | Probes with authentication enabled | k0s | **fail** | LocalAI stuck `0/1` forever; LocalRecall **liveness-killed in a loop**. Both logged 401 from `kube-probe/1.34`. `httpGet` probes cannot read a Secret. |
| 49 | LocalRecall probe with a token | k0s | **impossible** | `FROM scratch` → no `exec` probe; `httpGet` → cannot read a Secret. Must hardcode, drop probes, or leave `API_KEYS` empty. |
| 50 | First inference request on a 50-pod node | k0s, amd64 | **fail** | `FATAL -- failed to create Watcher` (`hpcloud/tail`), pod exit 1 mid-request. Cause: `fs.inotify.max_user_instances = 128` exhausted. |
| 51 | Same, after freeing 5 pods on the node | k0s, amd64 | **pass** | inference succeeded, zero restarts. Fragile — the durable fix is raising the sysctl. |
| 52 | Model persistence across pod recreation | k0s, Longhorn | **pass** | LocalAI Ready in **~20 s**; models survived in the PVC |
| 53 | Retrieval across a **pod** boundary | k0s | **pass** | **55.7 ms**; LocalRecall logged `remote_ip 10.244.172.216`, exactly the LocalAGI pod IP |
| 54 | Agent with knowledge **and** a tool | k0s, postgres | **pass** | **23.7 s**; retrieved 4200, computed 42, set the counter — matching the 24.1 s Compose result |
| 55 | Pod requesting `nvidia.com/gpu: 1` with no device plugin | k0s | **pass (as documented)** | stays **`Pending`**: `0/4 nodes are available: 4 Insufficient nvidia.com/gpu` — never `CrashLoopBackOff` |
| 56 | nginx ingress annotations on Traefik | k0s, Traefik | **silently ignored** | Traefik has **no per-Ingress read-timeout annotation**; needs static config or a `ServersTransport` CRD |
| 57 | Device plugin on a stock k0s worker | k0s v1.34.3 | **fail** | `no runtime for "nvidia" is configured`. `/etc/k0s/containerd.d/` is **empty by default**; Docker's toolkit config does not touch k0s's containerd. |
| 58 | containerd drop-in with `SystemdCgroup = true` | k0s | **fail** | runtime lookup succeeded, then runc: `expected cgroupsPath to be of format "slice:prefix:name" … got "/kubepods/besteffort/…"`. **k0s uses cgroupfs** — must be `false`. |
| 59 | Device plugin v0.19.3 after both fixes | k0s, gpu-node | **pass** | `1/1 Running`; `nvidia.com/gpu` capacity=1 allocatable=1; logs `Registered device plugin for 'nvidia.com/gpu' with Kubelet` |
| 60 | First GPU deployment with liveness probe only | k0s | **fail** | CUDA backend is **1.8 GiB** and downloads **before** the HTTP listener starts, so `/readyz` refuses connections and liveness killed it at ~120 s — **5 restarts**, download restarting from zero each time. |
| 61 | Same, with a `startupProbe` added | k0s | **pass** | Ready in ~3 min, **zero restarts**. The CPU backend fits inside the liveness window, so this defect appears **only** on first GPU deployment. |
| 62 | CUDA backend auto-selected in Kubernetes | k0s, gpu-node | **pass** | `/backends` → `cuda12-llama-cpp`; log `capability="nvidia-cuda-12"` |
| 63 | VRAM attributed to the pod's backend process | k0s, gpu-node | **pass** | **2194 MiB** against `/backends/cuda12-llama-cpp/lib/ld.so`; reads 0 MiB until the first request (lazy backend start) |
| 64 | GPU vs CPU, 200-token completion, same node/model/prompt | k0s, gpu-node | **pass** | CPU **6.67 / 6.78 s** (~30 tok/s) → GPU **1.41 / 1.50 s** (~142 tok/s) = **~4.5x** |
| 65 | GPU vs CPU, agent with knowledge and a tool | k0s, gpu-node | **pass** | **23.7 s → 2.12 s ≈ 11x.** Corrected an earlier claim that a GPU helps agent latency "only partly". |
| 66 | All 7 verify-stack layers on GPU | k0s, gpu-node | **pass** | agent request 4 s |
| 67 | LocalAGI image runtimes for stdio MCP | k0s | **fail — none present** | `node`, `npx`, `python3`, `uvx` all MISSING in v2.8.1. The `npx`/`uvx` reference-server ecosystem cannot run as a stdio child as shipped. |
| 68 | `ghcr.io/sparfenyuk/mcp-proxy:v0.12.0` wrapping `uvx mcp-server-time` | k0s | **fail** | `FileNotFoundError: [Errno 2] No such file or directory: 'uvx'` — that image does not bundle `uv` either |
| 69 | `mcp-proxy` + `mcp-server-time` on a `python:3.13-slim` base | k0s | **pass** | serves SSE at `/sse`; resolved mcp-proxy 0.12.0, mcp-server-time 2026.8.18 |
| 70 | MCP discovery with the server not yet serving | k0s | **fail, silently** | `Failed to connect to MCP server via SSEClientTransport … connection refused`, then `Done populating actions` and `Agent started`. Agent runs with **no MCP tools**; not retried later. |
| 71 | MCP discovery after the server is up | k0s | **pass** | no connect error; tools populated |
| 72 | `get_current_time` via MCP | k0s, GPU | **pass** | `{"timezone":"Asia/Tokyo"}` → `2026-08-22T08:26:14+09:00`, Saturday, `is_dst false`. **2.6 s** |
| 73 | `convert_time` via MCP | k0s, GPU | **pass** | Europe/Rome 09:00 → America/New_York 03:00, −6.0h — correct for August |
| 74 | MCP boundary crossing confirmed | k0s | **pass** | server logged `POST /messages/?session_id=…` from `10.244.172.216`, exactly the LocalAGI pod IP |
| 75 | Streamable HTTP → SSE fallback | k0s | **pass (as documented)** | `mcp.go:158-166`; the `/sse` endpoint took the SSE path |
| 76 | `call_agents` tool schema | k0s | **pass** | action key is `call_agents`, tool name is **`call_agent`**; `agent_name` is an **enum**, so an agent name cannot be hallucinated |
| 77 | `call_agents` with **no** whitelist | k0s | **pass — and this is the risk** | enum listed **all 4** pool agents, including the coordinator itself |
| 78 | `whitelist` filtering | k0s | **pass** | 4 agents → `["unit-converter"]` |
| 79 | `blacklist` filtering | k0s | **pass** | `blacklist=k8s-probe,mcp-probe` → the other two remained |
| 80 | Same-model delegation | k0s, GPU | **pass** | 12 km → 7.456 miles. **10.6 s cold, 7.5 s warm**; the specialist's own loop was ~9 s of it |
| 81 | Specialist `History` after delegation | k0s | **empty — not a failure** | `History` records **action** results; a tool-less specialist has none. The log is the proof it ran |
| 82 | Delegated message content | k0s | **rewritten** | the coordinator composed `"Calculate 47 requests/second * (3*3600 + 25*60) seconds."` rather than forwarding the user's prose |
| 83 | Cross-model delegation | k0s, GPU | **pass** | log confirmed `agent=router model=qwen3-1.7b` → `agent=deep-thinker model=qwen3-4b`; **37.5 s cold, 7.8 s warm** |
| 84 | Whether the cross-model split improved the answer | k0s, GPU | **no difference on this test** | qwen3-1.7b answered 578,100 correctly unaided, so the routing mechanism was validated but no quality gap was demonstrated |
| 85 | Three models resident simultaneously | k0s, GPU | **pass** | qwen3-1.7b 2202 MiB + granite 234 MiB + qwen3-4b 4850 MiB = **7294 MiB**, no eviction |
| 86 | Shipped `07-ingress.yaml` as written | k0s, Traefik | **unusable** | host was the placeholder `agents.example.com` and every annotation was `nginx.ingress.kubernetes.io/*`; the object still reported an address |
| 87 | Ingress via `*.<ip>.sslip.io` host | k0s, Traefik | **pass** | resolves through public DNS with no zone edit; makes an ingress testable the moment it is applied |
| 88 | Dual-host Ingress via a YAML anchor | k0s, Traefik | **pass** | one backend definition serving both `<svc>.example.com` and the sslip.io host |
| 89 | LocalAI through the ingress | k0s, Traefik | **pass** | `/readyz` 200, `/v1/models` → 3 models, `/system` → 3 backends loaded |
| 90 | LocalAGI through the ingress | k0s, Traefik | **pass** | `/api/agents` → 6 agents; `/v1/responses` answered |
| 91 | LocalRecall through the ingress | k0s, Traefik | **pass** | `/api/collections` → `["k8s-probe"]` |
| 92 | `verify-stack.sh` with all URLs on the ingress | k0s, Traefik, GPU | **pass — all 7 layers** | first run with **no port-forward**; included the full ingest → embed → search round trip and a 2 s agent request |
| 93 | Longest request achievable, through the ingress | k0s, Traefik, GPU | **36 s** | 4000-token essay, `finish_reason: stop`. 7000-token forced output was 24 s (~290 tok/s); a delegated cross-model request 18 s |
| 94 | Whether Traefik cuts off a slow agent request | k0s, Traefik | **it does not** | `writeTimeout` — the setting that governs a slow response — defaults to **`0`, unlimited**. `readTimeout` 60 s covers reading the request only. **Documented, not tested past 36 s** |
| 95 | `nginx.ingress.kubernetes.io/*` annotations on Traefik | k0s, Traefik | **silently ignored** | no warning, no event; an ignored annotation is indistinguishable from a working one |
| 96 | `basicAuth` Traefik `Middleware` manifest | k0s, Traefik | **schema valid, not enabled** | `middlewares.traefik.io` CRD present, `--dry-run=client` passed; never put in front of a live route |
| 97 | LocalAI agent pool enabled (`LOCALAI_DISABLE_AGENTS=false`) | k0s, GPU | **pass** | `/api/agents` 200 where it was 404; `actions: 40`, `connectors: 9` |
| 98 | Agent-pool route prefix | k0s | **`/api/agents/collections`** | **not** `/api/collections` — collides with neither LocalRecall's nor LocalAGI's API |
| 99 | Agent-pool routes in `/swagger/doc.json` | k0s | **absent** | swagger documents only `/api/agent/tasks` and `/api/agent/jobs`; pool CRUD is undocumented |
| 100 | `GET /api/agents` response shape | k0s | **summary, not a list** | `{"agentCount":1,"agents":[...],"actions":40,"connectors":9}` — LocalAGI returns an array |
| 101 | Collection create / upload / search in LocalAI | k0s, GPU | **pass** | create 201; multipart upload 200; search returned similarity **0.693** |
| 102 | LocalAI vs LocalRecall response envelope | k0s | **not wire-compatible** | `{"collections":[..],"count":1}` vs `{"success":true,"data":{...}}` |
| 103 | `DELETE` a LocalAI collection | k0s | **query param only** | `?name=X` → 200; `/collections/X` → 404 |
| 104 | How an agent selects its collection | k0s | **by agent name** | no collection field in the 57-field config; agent `handbook` reads collection `handbook` |
| 105 | Agent answering from LocalAI's own knowledge | k0s, GPU | **pass** | correct retrieval of a synthetic sentinel, **53 s cold** including embedding-backend load |
| 106 | `local_rag_url` on a LocalAI agent | k0s, GPU | **accepted and SILENTLY IGNORED** | value persists; LocalAI logs `Chromem collection ... dbPath="/data/collections"` anyway; target LocalRecall logged **zero** requests; seeding LocalAI's own collection fixed the answer |
| 107 | `kb_results` > document count on `chromem` | k0s | **hard error, logged at INFO** | `nResults must be <= the number of documents in the collection` → `No similar strings found in KB` → a confident "I do not know" with nothing at ERROR |
| 108 | `/data` unmounted in the base manifest | k0s | **defect found and fixed** | `--data-path` holds `collectiondb`, agent state, tasks, jobs; it was the container's writable layer, so ingestion was discarded on every rollout |
| 109 | Strategic-merge patch over a `configMapKeyRef` | k0s | **rejected without an explicit null** | `env[0].valueFrom: Invalid value: "": may not be specified when 'value' is not empty`; `valueFrom: null` in the same patch fixes it |
| 110 | `POST /api/agents/import` | k0s | **pass — 201** | body is the `GET /api/agents/{name}/export` object; empty body returns 400, which proves the route exists |
| 111 | Imported agent's knowledge | k0s, GPU | **empty — by design, and it looks broken** | collections bind by agent **name**, so an import under a new name auto-creates an empty collection and then denies all knowledge via the `nResults` path |
| 112 | Import control in the WebUI | k0s | **present, not feature-gated** | a `<label class="btn btn-secondary">` wrapping a hidden `<input type=file>` on `/app/agents`; only the Agent Hub link is conditional |
| 113 | Import control in the zero-agents empty state | k0s | **UI defect** | `agents-import-input` is on the `<input>`, but the rule is `.agents-import-input input[type=file]{display:none}` — needs the class on an ancestor, so the raw native file picker renders |
| 114 | Deep-linking to import mode | k0s | **not possible** | "Import Agent" is gated on router state `importedConfig`; `/app/agents/new` shows "Create Agent" |
| 115 | `DELETE /api/agents/collections?name=X` | k0s | **silent no-op** | returns `200 {"status":"ok"}`; collection stays listed, keeps its entries and still returns them from `/search`. Agent deletion does work |

### A reproduced failure worth knowing

Row 9 is the most useful failure in this table, because it will happen to readers
and it does not look like a failure.

When `raw.githubusercontent.com` rate-limits you — HTTP 429 — LocalAI's model
gallery cannot resolve any entry, so **model installation fails at startup**.
LocalAI nonetheless logs:

```text
INFO  core/startup process completed!
INFO  LocalAI is started and running address=":8080"
```

and `/readyz` returns `200` with zero models installed. One of the error lines is
itself defective:

```text
ERROR [startup] failed installing model error=<nil> model="qwen3-1.7b"
```

An error log with a nil error. Practical lessons: **`/readyz` is not a readiness
signal for anything except the listener**, and the only reliable check is
`GET /v1/models`. This is precisely why
[`verify-stack.sh`](https://github.com/wrkode/local-ai-stack-handbook/blob/main/scripts/verify-stack.sh)
treats "models resolvable" as a distinct layer from "process reachable".

The backend gallery was unaffected, because backends are OCI artifacts from a
container registry rather than YAML on GitHub.

### Not yet validated

Recorded honestly, because the gaps matter:

| Configuration | Status |
|---|---|
| LocalAGI **v2.9.0** in any form | **not executed** — no published image; not built from source |
| Embedded (in-process) knowledge layer | **tested on LocalAI v4.8.2** (rows 97-107). Still not executed on *LocalAGI*, where it is absent from v2.8.1 |
| LocalAGI's `/api/collections` API | **not executed** — absent from v2.8.1 |
| Standalone LocalRecall with `chromem` engine | **not executed** — only `postgres` was exercised |
| Hybrid search weight tuning, BM25 behaviour | **not executed** — the engine was used, the weights were not varied |
| Long-term memory write-back | **not executed** — observed disabled in the log |
| ROCm, Intel SYCL, Vulkan, Metal | **not executed** — only CUDA 12 was available |
| GPU for LocalAGI or LocalRecall | **n/a** — neither ever uses a device |
| Distributed llama.cpp (`LLAMACPP_GRPC_SERVERS`) | **not executed** — the binary is present in the bundle |
| `/v1/messages`, `/v1/rerank`, and the face/voice/vision endpoints | **not exercised** — routes confirmed present only |
| Distributed mode (NATS + PostgreSQL) | **not executed** |
| Pattern A with agents enabled *and* knowledge | **tested** — rows 97-107, [`kubernetes/pattern-a/`](https://github.com/wrkode/local-ai-stack-handbook/tree/main/kubernetes/pattern-a) |
| LocalAI's agent pool on the `postgres` vector engine | **not executed** — only `chromem` was exercised |
| One PostgreSQL database shared by LocalAI's pool and a standalone LocalRecall | **not executed** — risks a schema migration running under the other process |
| TLS on the ingress | **not executed** — HTTP only; no certificate issuer in the cluster |
| The basic-auth middleware actually in front of a route | **not executed** — manifest validated, never enabled |
| A request longer than 60 s through an ingress | **not achievable here** — the GPU answers too fast; 36 s was the maximum |

Every page describing the above is **source-verified**, not tested. The
distinction is maintained in the prose.

## Platform notes

**Docker on macOS has no Metal access.** Verified: there is no Metal or Darwin
target anywhere in LocalAI's Dockerfile or image workflows. A containerised
LocalAI on Apple Silicon runs CPU-only inside a Linux VM. GPU acceleration on a
Mac requires the native install (DMG or install script), which pulls
`metal-darwin-arm64-*` backends.

The practical arrangement on a Mac: run LocalAI natively, run LocalAGI and
LocalRecall in containers pointed at `host.docker.internal:8080`.

**No Intel-Mac binary is published.** Release assets cover
`linux-amd64`, `linux-arm64`, `darwin-arm64` and a DMG.

**Homebrew is not a distribution channel** for LocalAI. Every `brew` reference in
upstream material is a build dependency, not an install path.

## Keeping this page honest

When you validate a configuration, add a row with the date and the observed
version strings, and update the "not yet validated" table. When you *cannot*
validate something, leave it in the second table. An empty result is information;
a fabricated one destroys the point of the handbook.

See [Contributing](https://github.com/wrkode/local-ai-stack-handbook/blob/main/CONTRIBUTING.md)
for the evidence rules.

## Upstream references

- [LocalAI releases](https://github.com/mudler/LocalAI/releases/tag/v4.8.2) — v4.8.2, 2026-08-07.
- [LocalAI `go.mod`](https://github.com/mudler/LocalAI/blob/v4.8.2/go.mod) — pinned LocalAGI, LocalRecall and cogito versions.
- [LocalAGI releases](https://github.com/mudler/LocalAGI/releases/tag/v2.9.0) — v2.9.0, 2026-05-08.
- [LocalRecall releases](https://github.com/mudler/LocalRecall/releases/tag/v0.6.4) — v0.6.4, 2026-07-19.
- [LocalAI `gallery/qwen3.yaml`](https://github.com/mudler/LocalAI/blob/v4.8.2/gallery/qwen3.yaml) — `qwen3-1.7b` tool-calling configuration.
- [LocalAI `core/cli/run.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/cli/run.go) — default embedding model.
- [Traefik responding timeouts](https://doc.traefik.io/traefik/reference/install-configuration/entrypoints/#respondingtimeouts) — `readTimeout` 60 s, `writeTimeout` 0, `idleTimeout` 180 s. Read 2026-08-22.
- Image tags, model sizes and failure results: observed 2026-08-17.
- Ingress results: observed 2026-08-22, Traefik v3.6.6, k0s v1.34.3.
