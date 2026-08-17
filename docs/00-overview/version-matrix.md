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
| LocalAGI v2.9.0 | `v0.9.5-0.20260315…` | 2026-03-15 |

Roughly four months apart. Capabilities present in the newer cogito — sub-agent
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
| Embedded (in-process) knowledge layer | **not executed** — absent from v2.8.1; v2.9.0 source only |
| LocalAGI's `/api/collections` API | **not executed** — absent from v2.8.1 |
| Standalone LocalRecall with `chromem` engine | **not executed** — only `postgres` was exercised |
| Hybrid search weight tuning, BM25 behaviour | **not executed** — the engine was used, the weights were not varied |
| MCP servers, of any kind | **not executed** |
| Multi-agent delegation (`call_agents`) | **not executed** |
| Long-term memory write-back | **not executed** — observed disabled in the log |
| Any GPU configuration (CUDA, ROCm, Intel, Metal) | **not executed** |
| Kubernetes deployment | **not executed** |
| linux/amd64 anything | **not executed** |
| Distributed mode (NATS + PostgreSQL) | **not executed** |
| Pattern A with agents enabled *and* knowledge | **not executed** |

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
- Image tags, model sizes and failure results: observed 2026-08-17.
