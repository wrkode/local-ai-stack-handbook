# Single containers

One container per project, on one host. This is the layer where tag selection,
path configuration and port allocation are decided; Compose and Kubernetes only
repackage those decisions.

## Images that exist

| Project | Registry path | Current tag |
|---|---|---|
| LocalAI | `quay.io/go-skynet/local-ai`, mirrored at `localai/localai` (Docker Hub) | `v4.8.2` |
| LocalAGI | `quay.io/mudler/localagi` | **`v2.8.1`** — see below |
| LocalRecall | `quay.io/mudler/localrecall` | `v0.6.4`, plus `v0.6.4-postgresql` |

None of the three publishes to `ghcr.io`. Queries against the GitHub packages API
for `mudler/local-ai`, `mudler/localagi` and `mudler/localrecall` all return
`404 Package not found` (observed 2026-08-17).

> **`quay.io/mudler/localagi:v2.9.0` does not exist.** The highest published tag
> on the main LocalAGI image is `v2.8.1`; `latest` was last modified 2026-02-16.
> The main image build has produced nothing since `main-20260415165223`, while
> the separate `localagi-sshbox` image *did* publish a `v2.9.0` tag — which makes
> it easy to conclude the main image exists when it does not (observed
> 2026-08-17 against the Quay tag API). Pin `v2.8.1`, or build from source.

### The eight LocalAI tag suffixes

A substring query for `v4.8.2` against the Quay tag API returned exactly eight
tags (observed 2026-08-17). The same eight names exist in the `latest…` form and
on the Docker Hub mirror.

| Tag suffix | Accelerator | Platforms | Compressed size |
|---|---|---|---|
| *(none)* | CPU | amd64, arm64 | 0.29 GB |
| `-gpu-nvidia-cuda-12` | NVIDIA, CUDA 12.8 | amd64 | 3.73 GB |
| `-gpu-nvidia-cuda-13` | NVIDIA, CUDA 13.0 | amd64 | 2.84 GB |
| `-gpu-hipblas` | AMD ROCm, base `rocm/dev-ubuntu-24.04:7.2.1` | amd64 | 4.25 GB |
| `-gpu-intel` | Intel oneAPI/SYCL, base `intel/oneapi-basekit:2025.3.2-0-devel-ubuntu24.04` | amd64 | 4.63 GB |
| `-gpu-vulkan` | Vulkan, LunarG SDK 1.4.335.0 + mesa | amd64, arm64 | 1.11 GB |
| `-nvidia-l4t-arm64` | Jetson / L4T (JetPack r36), CUDA 12 | arm64 | 6.13 GB |
| `-nvidia-l4t-arm64-cuda-13` | Jetson / DGX Spark, CUDA 13 | arm64 | 4.50 GB |

The image size is a floor. Every v4.8.2 image ships with **no models and no
backends** — a clean instance reports `[]` from both `/v1/models` and `/backends`
(observed 2026-08-17). Backends are pulled as OCI artifacts on first use, pinned
by digest; installing `granite-embedding-107m-multilingual` also fetched
`quay.io/go-skynet/local-ai-backends:latest-cpu-llama-cpp`, 42 MiB (observed
2026-08-17).

### AIO images are gone, and old tags still resolve

There is no `aio/` directory anywhere in the v4.8.2 tree, and the 4.0 release
notes state the removal directly: the images existed to bundle a preset of models
and maintaining them per hardware variant stopped being worthwhile (documented).
The word "AIO" survives only as the name of a nightly end-to-end test suite that
builds the *standard* image.

A `latest%` query returns **31** tags; only the eight above are current (observed
2026-08-17). The other 23 resolve to frozen builds:

| Stale tag family | Frozen at |
|---|---|
| `latest-aio-cpu`, `latest-aio-gpu-{vulkan,nvidia-cuda-12,nvidia-cuda-13,hipblas,intel}` | 2026-02-21 |
| `latest-aio-gpu-nvidia-cuda-11`, `latest-gpu-nvidia-cuda-11` | 2025-12-25 |
| `latest-{aio-,}gpu-intel-f16`, `…-f32` | 2025-07-28 |
| `latest-gpu-nvidia-cuda11`, `latest-gpu-nvidia-cuda12` (no dash) | 2025-07-25 |
| `latest-vulkan` | 2025-07-24 |
| **`latest-cpu`** | **2025-06-19** |
| `*-extras`, `*-ffmpeg-core`, `latest-nvidia-l4t-arm64-core` | 2025-04 / 2025-05 |

`latest-cpu` is the trap that matters, because LocalAI's own compose files still
name it: `docker-compose.yaml` and `docker-compose.distributed.yaml` both offer
`localai/localai:latest-cpu` as a commented-out image alternative (source-verified,
v4.8.2). It has been stale for over a year. The current CPU tag is plain `latest`
or `v4.8.2`. LocalAGI's `docker-compose.nvidia.yaml` has the same problem with
`localai/localai:master-cublas-cuda12-ffmpeg`, a naming scheme that no longer
exists (source-verified, v2.9.0).

Two more dead knobs propagated by upstream compose files: `IMAGE_TYPE=core` is
passed as a build arg by both, and the Dockerfile no longer declares that `ARG`;
there is no `FFMPEG` build arg either, because ffmpeg is now installed
unconditionally (source-verified, v4.8.2). Drop both rather than copying them.

## `${basepath}` is the working directory

LocalAI's storage defaults are kong template expansions of
`${basepath}`, which is `kong.ExpandPath(".")` — the process working directory
(source-verified, v4.8.2, `cmd/local-ai/main.go`).

| Flag | Env | Default |
|---|---|---|
| `--models-path` | `LOCALAI_MODELS_PATH`, `MODELS_PATH` | `${basepath}/models` |
| `--backends-path` | `LOCALAI_BACKENDS_PATH`, `BACKENDS_PATH` | `${basepath}/backends` |
| `--data-path` | `LOCALAI_DATA_PATH` | `${basepath}/data` |
| `--localai-config-dir` | `LOCALAI_CONFIG_DIR` | `${basepath}/configuration` |

Inside the official image this resolves to `/models`, `/backends`, `/data`,
`/configuration`, because the final stage sets `WORKDIR /`. That agreement
between `WORKDIR` and `VOLUME` is the only reason the shorthand recipes work.
It is not a guarantee: run the binary natively from a different directory, or
override `WORKDIR`, and the process silently uses a different tree. Upstream's
`docker-compose.yaml` sets `MODELS_PATH=/models` and leaves the other three to
the coincidence.

Set all four explicitly in anything you intend to keep:

```bash
docker run -d --name localai \
  -p 8080:8080 \
  -e LOCALAI_MODELS_PATH=/models \
  -e LOCALAI_BACKENDS_PATH=/backends \
  -e LOCALAI_DATA_PATH=/data \
  -e LOCALAI_CONFIG_DIR=/configuration \
  -e LOCALAI_GENERATED_CONTENT_PATH=/generated \
  -v localai-models:/models \
  -v localai-backends:/backends \
  -v localai-data:/data \
  -v localai-config:/configuration \
  -v localai-generated:/generated \
  localai/localai:v4.8.2
```

Note `/configuration` is declared as a `VOLUME` but is **not** among the
directories pre-created by the image's `mkdir` (which covers `/models`,
`/backends`, `/data` only) — source-verified, v4.8.2.

> **Use named volumes, not bind mounts from network shares, for `/backends`.**
> Backend OCI artifacts contain symlinks. On CIFS/SMB or any filesystem without
> link support every link is materialized as a full regular file (documented,
> `containers.md`).

## Ports

| Process | Default | Knob | Dockerfile `EXPOSE` |
|---|---|---|---|
| LocalAI (`run`, `federated`, `explorer`) | `:8080` | `LOCALAI_ADDRESS`, `ADDRESS` | 8080 |
| LocalAGI | `:3000` | `LOCALAGI_BASE_URL` | **none** |
| LocalRecall | `:8080` | `LISTENING_ADDRESS` | 8080 |
| LocalRecall PostgreSQL image | 5432 | — | 5432 |

**LocalAI and LocalRecall collide on 8080.** Both bind all interfaces by default.
Upstream resolves this by publishing LocalAI on `8081:8080` in both LocalRecall's
and LocalAGI's compose files; this handbook's reference stack keeps LocalAI on
8080 and moves LocalRecall. Pick one convention and hold it — mixed conventions
across tutorials are the single most common cause of "the embedding call goes to
the wrong service".

LocalAGI's README says the UI is at `http://localhost:8080`. That is the *host*
side of the `8080:3000` publish in its compose file; the container port is 3000,
as its own `curl` examples show (source-verified, v2.9.0).

Auxiliary LocalAI ports, all off by default:

| Port | Purpose | Knob |
|---|---|---|
| ephemeral UDP | WebRTC ICE media for `/v1/realtime` | `LOCALAI_WEBRTC_UDP_PORT`, then publish `-p N:N/udp` |
| 50051 | Distributed worker gRPC base | `LOCALAI_SERVE_ADDR` |
| 50050 | Worker HTTP file transfer, **gRPC base − 1**; also serves the worker's `/healthz` and `/readyz` | `LOCALAI_HTTP_ADDR` |
| dynamic | libp2p, when `--p2p` is on | `LOCALAI_P2P_LISTEN_MADDRS` |

There is no separate metrics listener. `/metrics` is served on the main port.

## LocalAI per hardware family

Every recipe below assumes the five `-e`/`-v` pairs from the explicit-paths
example; they are elided for readability. Driver-level detail, capability
resolution and the VRAM floor are in [gpu](gpu.md).

**CPU** — the plain tag, amd64 and arm64:

```bash
docker run -d --name localai -p 8080:8080 localai/localai:v4.8.2
```

**NVIDIA, CUDA 12 or 13:**

```bash
docker run -d --name localai --gpus all \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
  -p 8080:8080 localai/localai:v4.8.2-gpu-nvidia-cuda-12
```

`utility` is not optional. Without it `nvidia-smi` and NVML are unavailable in
the container, free-VRAM reporting breaks and the nodes UI misreports memory —
upstream says so in its own compose comments. The image already sets
`compute,utility`; preserve it if you override the variable.

**NVIDIA Jetson / DGX Spark:**

```bash
docker run -d --name localai --runtime nvidia --gpus all \
  -p 8080:8080 localai/localai:v4.8.2-nvidia-l4t-arm64-cuda-13
```

Use `-nvidia-l4t-arm64` for CUDA 12 JetPack r36 devices.

**AMD ROCm:**

```bash
docker run -d --name localai \
  --device=/dev/kfd --device=/dev/dri --group-add=video \
  -p 8080:8080 localai/localai:v4.8.2-gpu-hipblas
```

Host requirements are ROCm ≥ 7.0.0 with `amdgpu-dkms`, and upstream asks for at
least 100 GB free on the disk holding the container runtime before installing the
ROCm stack (documented, `GPU-acceleration.md`).

**Intel oneAPI / SYCL:**

```bash
docker run -d --name localai \
  --device /dev/dri -e ZES_ENABLE_SYSMAN=1 \
  -p 8080:8080 localai/localai:v4.8.2-gpu-intel
```

Upstream's README names individual device nodes
(`--device=/dev/dri/card1 --device=/dev/dri/renderD128`); passing the directory
is equivalent and survives renumbering. LocalAGI's Intel overlay hardcodes
`card1` / `renderD129`, which is correct only on a host with both an integrated
GPU and a discrete card.

**Vulkan:**

```bash
docker run -d --name localai \
  --device /dev/dri -p 8080:8080 localai/localai:v4.8.2-gpu-vulkan
```

The only GPU variant that also builds for arm64, and 1.11 GB against 3–6 GB for
the vendor stacks.

**Apple Silicon** gets no GPU in a container at all. Verified: zero
`metal`/`darwin`/`mps`/`apple` matches across the Dockerfile and every image
workflow (source-verified, v4.8.2). See [gpu](gpu.md#apple-silicon).

## LocalRecall

`FROM scratch`, a static `CGO_ENABLED=0` binary, no `WORKDIR` in the final stage
(source-verified, v0.6.4). Unset paths therefore resolve to `/collections` and
`/assets` at the filesystem root, inside an image with no shell — you cannot
`docker exec` your way into diagnosing it. Set both explicitly.

```bash
docker run -d --name localrecall \
  -p 8082:8080 \
  -e LISTENING_ADDRESS=:8080 \
  -e COLLECTION_DB_PATH=/db \
  -e FILE_ASSETS=/assets \
  -e EMBEDDING_MODEL=granite-embedding-107m-multilingual \
  -e OPENAI_BASE_URL=http://host.docker.internal:8080 \
  -e OPENAI_API_KEY=unused \
  -e API_KEYS=change-me \
  -v localrecall-db:/db -v localrecall-assets:/assets \
  quay.io/mudler/localrecall:v0.6.4
```

Four things about that command:

- `OPENAI_BASE_URL` carries **no `/v1`**. That works against LocalAI because it
  registers un-prefixed aliases for `/chat/completions` and `/embeddings`. Against
  a strict OpenAI-compatible server, append `/v1` yourself.
- `OPENAI_BASE_URL` is applied unconditionally. Leaving it unset does not fall
  back to `api.openai.com` — it overwrites the client default with the empty
  string (source-verified, v0.6.4).
- `API_KEYS` is the only thing standing between the network and the whole REST
  surface. Unset means unauthenticated, including the web UI.
- `COLLECTION_DB_PATH` is required even with `VECTOR_ENGINE=postgres`: the
  `collection-<name>.json` manifests are still written there and are what
  collection discovery scans at startup.

`quay.io/mudler/localrecall:latest-postgresql`, which LocalRecall's own README
tells you to pull, **is not a real tag** — the workflow sets `latest=false` for
that build variant, and it is absent from all 218 live tags (observed
2026-08-17). Use `v0.6.4-postgresql`.

## LocalAGI

```bash
docker run -d --name localagi \
  -p 3000:3000 \
  --add-host host.docker.internal:host-gateway \
  -e LOCALAGI_MODEL=qwen3-1.7b \
  -e LOCALAGI_LLM_API_URL=http://host.docker.internal:8080 \
  -e LOCALAGI_STATE_DIR=/pool \
  -e COLLECTION_DB_PATH=/pool/collections \
  -e FILE_ASSETS=/pool/assets \
  -e EMBEDDING_MODEL=granite-embedding-107m-multilingual \
  -e LOCALAGI_API_KEYS=change-me \
  -v localagi-pool:/pool \
  quay.io/mudler/localagi:v2.8.1
```

`LOCALAGI_MODEL` and `LOCALAGI_LLM_API_URL` are both required — an empty value
prints help and exits. The image declares no `EXPOSE` and no `VOLUME`, and the
final stage has no `WORKDIR`, so the state directory fallback
`filepath.Join(cwd, "pool")` resolves to `/pool` (source-verified, v2.9.0).

Once `LOCALAGI_API_KEYS` is set, **every** route requires the key, including `/`
and `/app`: the auth middleware is registered with a `Next` function that returns
`false` for all paths, so nothing is exempt (source-verified, v2.9.0). Any
`HEALTHCHECK` or probe must carry an `Authorization: Bearer` header.

Note the pinned tag. Running v2.9.0 from a published image is not possible; the
source tag exists and the container does not.

## Health checks

LocalAI ships one. `HEALTHCHECK --start-period=60m --interval=1m --timeout=10s
--retries=3 CMD /healthcheck.sh`, and the script is mode-aware — it reads argv
and probes `/readyz` on `:8080` for `run`, `/readyz` on the gRPC base port minus
one for `worker`, and exits 0 for the subcommands with no HTTP surface
(source-verified, v4.8.2). The 60-minute start period exists because a startup
preload has been observed materializing 31 GB of artifacts before the socket
binds; failures inside the start period leave the container `starting` rather
than burning retries, and the period ends early on the first success.

Neither LocalAGI nor LocalRecall ships a healthcheck, and neither has a health
endpoint. Hand-write one:

```bash
# LocalRecall — the project's own convention, used in its Makefile
--health-cmd 'curl -fsS -H "Authorization: Bearer $API_KEYS" http://localhost:8080/api/collections || exit 1'

# LocalAGI — /app is the cheapest 200
--health-cmd 'curl -fsS -H "Authorization: Bearer $LOCALAGI_API_KEYS" http://localhost:3000/app || exit 1'
```

Do not copy `/readyz` for either. LocalAGI's own end-to-end test calls
`/readyz` against LocalAGI and asserts only that the HTTP call did not error — a
404 passes it (source-verified, v2.9.0). The route does not exist.

## Verifying a container

```bash
docker logs --tail 40 localai
curl -fsS http://localhost:8080/readyz && echo ready
curl -fsS http://localhost:8080/v1/models | jq .
curl -fsS http://localhost:8080/system | jq .
curl -fsS http://localhost:8082/api/collections -H 'Authorization: Bearer change-me'
curl -fsS http://localhost:3000/api/agents -H 'Authorization: Bearer change-me' | jq .
```

On a clean LocalAI, `/v1/models` returns `{"object":"list","data":[]}` and
`/system` returns `{"backends":[],"loaded_models":[]}` (observed 2026-08-17).
Empty is the correct answer, not a failure.

## Upstream references

- [`.github/workflows/image.yml`](https://github.com/mudler/LocalAI/blob/v4.8.2/.github/workflows/image.yml) — the eight-suffix build matrix. Source-verified against v4.8.2, validated 2026-08-17.
- [`Dockerfile`](https://github.com/mudler/LocalAI/blob/v4.8.2/Dockerfile) — `WORKDIR /`, `VOLUME`, `EXPOSE 8080`, `HEALTHCHECK`, absent `IMAGE_TYPE`/`FFMPEG` args. Source-verified against v4.8.2, validated 2026-08-17.
- [`scripts/build/healthcheck.sh`](https://github.com/mudler/LocalAI/blob/v4.8.2/scripts/build/healthcheck.sh) — mode-aware probe selection. Source-verified against v4.8.2, validated 2026-08-17.
- [`docker-compose.yaml`](https://github.com/mudler/LocalAI/blob/v4.8.2/docker-compose.yaml) — `latest-cpu` and `IMAGE_TYPE=core` in comments and build args. Source-verified against v4.8.2, validated 2026-08-17.
- [`website/content/blog/what-landed-in-localai-4-0.md`](https://github.com/mudler/LocalAI/blob/v4.8.2/website/content/blog/what-landed-in-localai-4-0.md) — AIO images dropped in 4.x. Documented, validated 2026-08-17.
- [`docs/content/getting-started/containers.md`](https://github.com/mudler/LocalAI/blob/v4.8.2/docs/content/getting-started/containers.md) — no preconfigured models; symlink caveat for `/backends`. Documented, validated 2026-08-17.
- [LocalAGI `cmd/env.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/cmd/env.go) — `:3000` default, required variables. Source-verified against v2.9.0, validated 2026-08-17.
- [LocalAGI `webui/routes.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/routes.go) — auth middleware with no exempt paths; the 45-route list with no health endpoint. Source-verified against v2.9.0, validated 2026-08-17.
- [LocalAGI `Dockerfile.webui`](https://github.com/mudler/LocalAGI/blob/v2.9.0/Dockerfile.webui) — no `EXPOSE`, no `VOLUME`, no final-stage `WORKDIR`. Source-verified against v2.9.0, validated 2026-08-17.
- [LocalRecall `Dockerfile`](https://github.com/mudler/LocalRecall/blob/v0.6.4/Dockerfile) — `FROM scratch`, `EXPOSE 8080`. Source-verified against v0.6.4, validated 2026-08-17.
- [LocalRecall `main.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/main.go) — env surface, unconditional `OPENAI_BASE_URL` assignment. Source-verified against v0.6.4, validated 2026-08-17.
- [LocalRecall `.github/workflows/image.yml`](https://github.com/mudler/LocalRecall/blob/v0.6.4/.github/workflows/image.yml) — `latest=false` for the PostgreSQL variant. Source-verified against v0.6.4, validated 2026-08-17.
- Registry tag counts, tag timestamps, image sizes, ghcr 404s: observed 2026-08-17 against the Quay, Docker Hub and GitHub packages APIs.
- Clean-instance `/v1/models`, `/system`, `/backends` responses and the backend artifact pull: observed 2026-08-17 on `localai/localai:latest` reporting `v4.8.2 (5ff25d9d)`.
