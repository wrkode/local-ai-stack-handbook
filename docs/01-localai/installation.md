# Installing LocalAI

Pick the install method by where the accelerator is, not by taste. On Linux with
an NVIDIA, AMD or Intel GPU, containers are the shortest path. On Apple Silicon,
containers cost you the GPU entirely — see [Apple Silicon](#apple-silicon-containers-have-no-metal).

## Container images

Two registries publish the same manifests (source-verified, v4.8.2 workflows):

| Registry path | Role |
|---|---|
| `quay.io/go-skynet/local-ai` | Primary |
| `localai/localai` (Docker Hub) | Mirror |
| `quay.io/go-skynet/local-ai-backends` / `localai/localai-backends` | **Backend artifacts**, not the server image |

There is no `ghcr.io/mudler/local-ai`. The package does not exist (verified
2026-08-17 against the GitHub packages API and the ghcr token endpoint).

### The tag matrix — exactly eight suffixes

Every release builds these and no others. Verified live against the Quay tag API
on 2026-08-17: a substring query for `v4.8.2` returned exactly eight tags.

| Tag suffix | Accelerator | Platforms | Compressed size |
|---|---|---|---|
| *(none)* | CPU | amd64, arm64 | 0.29 GB |
| `-gpu-nvidia-cuda-12` | NVIDIA CUDA 12.8 | amd64 | 3.73 GB |
| `-gpu-nvidia-cuda-13` | NVIDIA CUDA 13.0 | amd64 | 2.84 GB |
| `-gpu-hipblas` | AMD ROCm (base `rocm/dev-ubuntu-24.04:7.2.1`) | amd64 | 4.25 GB |
| `-gpu-intel` | Intel oneAPI/SYCL (base `intel/oneapi-basekit:2025.3.2-0-devel-ubuntu24.04`) | amd64 | 4.63 GB |
| `-gpu-vulkan` | Vulkan (LunarG SDK 1.4.335.0 + mesa) | amd64, arm64 | 1.11 GB |
| `-nvidia-l4t-arm64` | Jetson / L4T, CUDA 12 | arm64 | 6.13 GB |
| `-nvidia-l4t-arm64-cuda-13` | Jetson / DGX Spark, CUDA 13 | arm64 | 4.50 GB |

Both `latest…` and `v4.8.2…` forms exist for all eight.

> **Stale tags still resolve.** A `latest%` query returns **31** tags; only the
> eight above are current. The other 23 are historical and pulling one silently
> gets you a build months or years old:
>
> | Family | Frozen at |
> |---|---|
> | `latest-aio-*` (all six) | 2026-02-21 |
> | `latest-gpu-nvidia-cuda-11`, `latest-aio-gpu-nvidia-cuda-11` | 2025-12-25 |
> | `latest-gpu-intel-f16`, `-f32` and their `aio` twins | 2025-07-28 |
> | `latest-gpu-nvidia-cuda11`, `latest-gpu-nvidia-cuda12` (no dash) | 2025-07-25 |
> | `latest-vulkan` | 2025-07-24 |
> | **`latest-cpu`** | **2025-06-19** |
> | `*-extras`, `*-ffmpeg-core`, `latest-nvidia-l4t-arm64-core` | 2025-04 / 2025-05 |
>
> `latest-cpu` matters because LocalAI's own compose files still name it in
> comments. The current CPU tag is plain `latest` (verified 2026-08-17).

There are no AIO images in the 4.x line, no `-ffmpeg` suffix (ffmpeg is installed
unconditionally), and no CUDA 11 build. `IMAGE_TYPE=core`, which both upstream
compose files pass as a build arg, is a **no-op** — the Dockerfile no longer
declares that ARG.

### Volumes

The image declares four (`Dockerfile`, source-verified v4.8.2):

```text
VOLUME /models /backends /configuration /data
```

| Mount | What it holds | Lost if unmounted |
|---|---|---|
| `/models` | GGUF/safetensors weights, per-model YAML, gallery metadata files | Every model re-downloads. Gigabytes |
| `/backends` | Installed backend artifacts, each with its `run.sh` and `metadata.json` | Every backend re-downloads on the next cold load. Tens to hundreds of MB per backend |
| `/configuration` | `api_keys.json`, `external_backends.json`, `runtime_settings.json` | Dynamically issued API keys, external backend registrations, and every setting saved through the web UI |
| `/data` | Agent state, tasks and jobs, the agent vector store, the SQLite auth DB, `.hmac_secret`, persisted traces, the MITM CA | **All user accounts, all issued API keys, all agents and all agent knowledge.** Existing API keys stop validating because the HMAC secret is regenerated |

Mounting only `/models` — what most quickstarts show — silently discards every
agent, account and key on container replacement.

Three paths are **not** covered by `VOLUME` and are worth mounting explicitly:

| Path | Env | Default |
|---|---|---|
| generated images/audio/video | `LOCALAI_GENERATED_CONTENT_PATH` | `$TMPDIR/localai-<uid>/generated/content` |
| Files API uploads | `LOCALAI_UPLOAD_PATH` | `$TMPDIR/localai-<uid>/upload` |
| system backends (read-only) | `LOCALAI_BACKENDS_SYSTEM_PATH` | `/var/lib/local-ai/backends` |

Upstream's `docker-compose.yaml` mounts `/tmp/generated/images/`, which no longer
matches the code default after the move to a per-UID temp directory. Set
`LOCALAI_GENERATED_CONTENT_PATH` explicitly rather than relying on the old path.

> **Filesystem caveat for `/backends`.** Backend OCI artifacts contain symlinks.
> On CIFS/SMB or any filesystem without link support each link is materialized as
> a full regular file, multiplying disk use. Prefer a Docker named volume over a
> bind mount from a network share (documented, `containers.md`).

### Docker run — CPU

```bash
docker run -d --name localai \
  -p 8080:8080 \
  -v localai-models:/models \
  -v localai-backends:/backends \
  -v localai-config:/configuration \
  -v localai-data:/data \
  localai/localai:v4.8.2
```

The container's `command:` is the argv to `local-ai`, because `entrypoint.sh`
ends in `exec ./local-ai "$@"` and `run` is the default subcommand. Appending a
model name installs and serves it:

```bash
docker run -d --name localai -p 8080:8080 \
  -v localai-models:/models -v localai-backends:/backends \
  -v localai-config:/configuration -v localai-data:/data \
  localai/localai:v4.8.2 granite-embedding-107m-multilingual
```

That download happens *before* the port opens. See
[architecture](architecture.md) for why probes get `connection refused` during it.

### Docker run — NVIDIA (CUDA 12 or 13)

```bash
docker run -d --name localai \
  --gpus all \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
  -p 8080:8080 \
  -v localai-models:/models -v localai-backends:/backends \
  -v localai-config:/configuration -v localai-data:/data \
  localai/localai:v4.8.2-gpu-nvidia-cuda-12
```

`utility` in `NVIDIA_DRIVER_CAPABILITIES` is not optional. Without it `nvidia-smi`
and NVML are unavailable inside the container, free-VRAM reporting breaks, and
the nodes UI misreports memory (documented in upstream's own compose comments).
The image sets `compute,utility` by default; keep it if you override the variable.

### Docker run — NVIDIA Jetson / DGX Spark

```bash
docker run -d --name localai \
  --runtime nvidia --gpus all \
  -p 8080:8080 \
  -v localai-models:/models -v localai-backends:/backends \
  -v localai-config:/configuration -v localai-data:/data \
  localai/localai:v4.8.2-nvidia-l4t-arm64-cuda-13
```

Use `-nvidia-l4t-arm64` (CUDA 12) for JetPack r36 devices and
`-nvidia-l4t-arm64-cuda-13` for CUDA 13 / DGX Spark.

### Docker run — AMD ROCm

```bash
docker run -d --name localai \
  --device=/dev/kfd --device=/dev/dri --group-add=video \
  -p 8080:8080 \
  -v localai-models:/models -v localai-backends:/backends \
  -v localai-config:/configuration -v localai-data:/data \
  localai/localai:v4.8.2-gpu-hipblas
```

The host needs `amdgpu-dkms` and ROCm ≥ 7.0.0. Upstream asks for at least 100 GB
free on the disk holding the container runtime and images before installing the
ROCm stack (documented, `GPU-acceleration.md`).

### Docker run — Intel oneAPI / SYCL

```bash
docker run -d --name localai \
  --device /dev/dri \
  -e ZES_ENABLE_SYSMAN=1 \
  -p 8080:8080 \
  -v localai-models:/models -v localai-backends:/backends \
  -v localai-config:/configuration -v localai-data:/data \
  localai/localai:v4.8.2-gpu-intel
```

Upstream's README passes the specific nodes (`--device=/dev/dri/card1
--device=/dev/dri/renderD128`); passing the whole `/dev/dri` directory is
equivalent and survives renumbering. `ZES_ENABLE_SYSMAN=1` is needed to read
integrated-GPU free memory.

### Docker run — Vulkan

```bash
docker run -d --name localai \
  --device /dev/dri \
  -p 8080:8080 \
  -v localai-models:/models -v localai-backends:/backends \
  -v localai-config:/configuration -v localai-data:/data \
  localai/localai:v4.8.2-gpu-vulkan
```

The Vulkan image is the only GPU variant that also builds for arm64, and it is
1.11 GB against 3–6 GB for the vendor stacks.

### Ports

| Port | Purpose | Knob |
|---|---|---|
| 8080 | HTTP API, web UI, `/metrics` (same port, no separate listener) | `LOCALAI_ADDRESS` |
| ephemeral UDP | WebRTC ICE for `/v1/realtime` only | `LOCALAI_WEBRTC_UDP_PORT`, then publish `-p N:N/udp` |
| 50051 / 50050 | Distributed **worker** gRPC base and its HTTP file server (base − 1) | `LOCALAI_SERVE_ADDR` |
| dynamic | libp2p, when `--p2p` is on | `LOCALAI_P2P_LISTEN_MADDRS` |

LocalAI and LocalRecall both default to 8080. In a combined stack, publish one of
them elsewhere.

## Native install

### Install script

```bash
curl -sSL https://localai.io/install.sh | sh
```

It downloads a prebuilt release binary, verifies its SHA256 against the published
checksum file, and installs it. Nothing is compiled. Running it twice is a no-op.

| Env | Effect |
|---|---|
| `LOCALAI_VERSION` | Pin a release, e.g. `v4.8.2` (the `v` is added if missing) |
| `INSTALL_DIR` | Default `/usr/local/bin`, falls back to `~/.local/bin` |
| `LOCALAI_FORCE=1` | Reinstall even when identical |
| `LOCALAI_NO_SUDO=1` | Never escalate; installs to `~/.local/bin` |
| `GITHUB_TOKEN` | Avoids GitHub API rate limits |

Platform gating is strict: Linux and Darwin only (Windows is told to use WSL2 or
the container image), amd64 and arm64 only, and **darwin/amd64 is a hard error**
because no Intel-Mac binary is published.

The script is served from the website, not referenced in the README, and not
listed on upstream's own install page — which enumerates containers, the macOS
DMG, Linux binaries, Kubernetes and source (documented, `install.md`).

### Release binaries

`v4.8.2` publishes (verified 2026-08-17):

| Asset | Kind |
|---|---|
| `local-ai-v4.8.2-linux-amd64` | server binary, raw (not tarred) |
| `local-ai-v4.8.2-linux-arm64` | server binary |
| `local-ai-v4.8.2-darwin-arm64` | server binary, **Apple Silicon only** |
| `LocalAI.dmg` | macOS launcher app |
| `local-ai-launcher-linux.tar.xz` | Linux launcher (Fyne GUI) |
| `LocalAI-v4.8.2-checksums.txt` | SHA256 list |
| `LocalAI-v4.8.2-source.tar.gz` | source archive |

```bash
curl -fsSLO https://github.com/mudler/LocalAI/releases/download/v4.8.2/local-ai-v4.8.2-linux-amd64
curl -fsSLO https://github.com/mudler/LocalAI/releases/download/v4.8.2/LocalAI-v4.8.2-checksums.txt
grep local-ai-v4.8.2-linux-amd64 LocalAI-v4.8.2-checksums.txt | sha256sum -c -
chmod +x local-ai-v4.8.2-linux-amd64
sudo mv local-ai-v4.8.2-linux-amd64 /usr/local/bin/local-ai
```

Set the path variables before running outside a container — kong's `${basepath}`
is the working directory, so `local-ai run` writes `./models`, `./backends`,
`./data` and `./configuration` wherever you happened to be:

```bash
export LOCALAI_MODELS_PATH=/var/lib/local-ai/models
export LOCALAI_BACKENDS_PATH=/var/lib/local-ai/backends
export LOCALAI_DATA_PATH=/var/lib/local-ai/data
export LOCALAI_CONFIG_DIR=/etc/local-ai/configuration
local-ai run
```

### macOS DMG

```bash
curl -fsSLO https://github.com/mudler/LocalAI/releases/latest/download/LocalAI.dmg
```

> **Upstream contradicts itself on signing, and the fix is cheap either way.**
> `README.md` states the DMG is not signed by Apple and instructs
> `sudo xattr -d com.apple.quarantine /Applications/LocalAI.app`.
> `docs/content/getting-started/macos.md` states the DMG, the app inside it and
> the `local-ai` binary are all Developer-ID signed and Apple-notarized and
> launch with no quarantine prompt. The release pipeline
> (`.github/workflows/release.yaml`, `Makefile`) notarizes and staples the `.app`
> **before** packaging the DMG, which supports the docs version; the README note
> reads as stale. Treat quarantine removal as a fallback, not a step:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/LocalAI.app
spctl --assess --type execute --verbose /Applications/LocalAI.app
# only if the checks above fail:
sudo xattr -d com.apple.quarantine /Applications/LocalAI.app
```

The DMG installs the **launcher**, a Fyne/systray app that supervises a server —
not the server binary alone. For a headless macOS host, use the install script or
the `darwin-arm64` release binary.

### Homebrew — not a distribution channel

There is no formula and no tap. Every `brew` reference in the repository is a
*build* dependency (`brew install go protobuf grpc cmake …`), not an install
path. `brew install localai` installs something else.

### Nix flake

`flake.nix` exists but is narrower than it looks:

| Aspect | Value |
|---|---|
| Systems | **`x86_64-linux` only** — no darwin, no aarch64 |
| CGO | disabled |
| Scope | `subPackages = ["cmd/local-ai"]`, checks off |
| Output binary name | **`localai`**, not `local-ai` |
| Default package | a `buildFHSEnv` wrapper around the unwrapped binary |
| nixpkgs | pinned to `nixos-unstable` |

```bash
nix run github:mudler/LocalAI
nix develop github:mudler/LocalAI   # dev shell: go, protoc, grpc, Vulkan toolchain, node, bun
```

Treat it as a Linux/x86_64 development environment. It is not referenced from
upstream's install documentation.

### From source

```bash
git clone https://github.com/mudler/LocalAI.git
cd LocalAI
git checkout v4.8.2
make build          # produces ./local-ai
```

Toolchain versions the CI actually uses (`Dockerfile`, authoritative over the
docs prose): Go 1.26.0, CMake 3.31.10, protoc 27.1, `protoc-gen-go` v1.34.2,
`protoc-gen-go-grpc` pinned to a commit, Node 26 for the React UI. The docs page
asks for Go ≥ 1.21, GCC and gRPC, which is a floor rather than what is tested.

A source build reports an empty version string, because `Version`/`Commit` are
link-time variables.

### systemd

LocalAI accepts a single pre-bound TCP listener via the systemd socket-activation
protocol (`LISTEN_FDS`, `LISTEN_PID`, `LISTEN_FDNAMES`). This is the only
configuration in which `/readyz` answers **503 during preload** instead of
refusing the connection, because systemd owns the socket.

## Apple Silicon: containers have no Metal

A grep for `metal|darwin|mps|apple` across `Dockerfile`, every image workflow and
the compose files returns **zero matches** (verified against v4.8.2 sources).
Every image builds on an Ubuntu, ROCm, Intel or L4T *Linux* base, and Docker
Desktop on macOS runs a Linux VM with no Metal passthrough.

Consequence: a containerised LocalAI on an M-series Mac runs **CPU only inside a
VM**. Our own observed instance confirms the shape of it — the container reported
`CPU: no AVX found`, `capability="default"`, and no GPU (tested 2026-08-17).

Metal is exclusively native, and it is real: the backend registry carries 62 tags
matching `v4.8.2-metal%`, including `metal-darwin-arm64-llama-cpp`, `-mlx`,
`-mlx-vlm`, `-mlx-audio`, `-whisper` and `-diffusers` (verified 2026-08-17).

Recommended shape on Apple Silicon:

```bash
curl -sSL https://localai.io/install.sh | sh
local-ai backends install llama-cpp      # resolves to metal-llama-cpp
local-ai run
```

and run anything else that needs to reach it from a container against
`http://host.docker.internal:8080`.

## Resource expectations

Upstream documents no minimum RAM, deliberately — requirements depend on model
size, quantization and backend (documented, `linux.md`). What is documented:

| Item | Value |
|---|---|
| Model size by class | 1–3B: 1–3 GB · 7–13B: 4–8 GB · 30B+: 15–30+ GB |
| Quantization ratios | `Q4_K_M` ≈ 75% of original, `Q4_K_S` ≈ 60%, `Q2_K` ≈ 50% |
| Disk headroom | 2–3× the model size, for the download and temp files |
| VRAM floor (hard-coded) | **≤ 4 GiB VRAM downgrades the capability to `default`, i.e. CPU** |

The last row is a code path, not advice: a 4 GB GPU gets a CPU backend and a
warning. See [gpu](gpu.md).

## Upstream references

- [`Dockerfile`](https://github.com/mudler/LocalAI/blob/v4.8.2/Dockerfile) — `WORKDIR /`, `VOLUME`, `HEALTHCHECK`, NVIDIA env, build args. Validated against v4.8.2.
- [`entrypoint.sh`](https://github.com/mudler/LocalAI/blob/v4.8.2/entrypoint.sh) — `EXTRA_BACKENDS`, AVX diagnostics, `exec ./local-ai "$@"`. Validated against v4.8.2.
- [`.github/workflows/image.yml`](https://github.com/mudler/LocalAI/blob/v4.8.2/.github/workflows/image.yml) — the eight-suffix tag matrix. Validated against v4.8.2.
- [`.goreleaser.yaml`](https://github.com/mudler/LocalAI/blob/v4.8.2/.goreleaser.yaml) — release assets, no darwin/amd64 build, signing conditions. Validated against v4.8.2.
- [`flake.nix`](https://github.com/mudler/LocalAI/blob/v4.8.2/flake.nix) — x86_64-linux scope, `localai` binary name. Validated against v4.8.2.
- [`website/static/install.sh`](https://github.com/mudler/LocalAI/blob/v4.8.2/website/static/install.sh) — installer behaviour and platform gating. Validated against v4.8.2.
- [`README.md`](https://github.com/mudler/LocalAI/blob/v4.8.2/README.md) — DMG quarantine instruction, GPU `docker run` flags. Validated against v4.8.2.
- [`docs/content/getting-started/macos.md`](https://github.com/mudler/LocalAI/blob/v4.8.2/docs/content/getting-started/macos.md) — the contradicting signing/notarization claim. Validated against v4.8.2.
- [LocalAI release v4.8.2](https://github.com/mudler/LocalAI/releases/tag/v4.8.2) — asset list. Validated 2026-08-17.
- Registry tag counts, image sizes, absence of ghcr: observed 2026-08-17 against Quay and Docker Hub APIs.
- Container CPU/capability log lines: observed 2026-08-17 on `localai/localai:latest` reporting `v4.8.2 (5ff25d9d)`.
