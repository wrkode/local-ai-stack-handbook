# GPU acceleration

GPU support in LocalAI is a property of two things chosen independently: the **image
variant** and the **backend** it downloads. Getting one right and the other wrong
produces a working CPU deployment that looks like it should be fast.

Nothing in this handbook's learning path requires a GPU. That is deliberate — mixing
device-plugin problems with "what does an agent do" makes both harder to learn.

## The two decisions

```mermaid
flowchart TB
  IMG["image tag<br/>e.g. :v4.8.2-gpu-nvidia-cuda-12"]
  RT["container runtime<br/>device passthrough"]
  BE["backend variant<br/>downloaded at model install"]
  ACC["accelerated inference"]
  IMG --> ACC
  RT --> ACC
  BE --> ACC
```

All three must agree. LocalAI does not warn you when they do not; it falls back to CPU
and runs.

## Image variants

Eight tag suffixes for v4.8.2, verified present:

| Suffix | Target |
|---|---|
| *(none)* | CPU, amd64 + arm64, 0.29 GB |
| `-gpu-nvidia-cuda-12` | NVIDIA, CUDA 12 |
| `-gpu-nvidia-cuda-13` | NVIDIA, CUDA 13 |
| `-gpu-hipblas` | AMD ROCm |
| `-gpu-intel` | Intel SYCL |
| `-gpu-vulkan` | Vulkan, vendor-neutral |
| `-nvidia-l4t-arm64` | Jetson |
| `-nvidia-l4t-arm64-cuda-13` | Jetson, CUDA 13 |

```bash
docker run -p 8080:8080 --gpus all \
  -v localai-models:/models -v localai-backends:/backends \
  localai/localai:v4.8.2-gpu-nvidia-cuda-12 qwen3-1.7b
```

!!! warning "Do not use AIO or `latest-*` tags"
    **All-in-one images were removed in the 4.x line.** Tags such as `latest-aio-gpu-*`,
    `-extras`, `-cuda-11` and `-intel-f16/f32` still *resolve* but are frozen builds from
    2026-02-21 or earlier. `latest-cpu` has been stale since 2025-06-19 — and is still
    referenced in comments in LocalAI's own compose file.

    A tutorial using `latest-aio-gpu-nvidia-cuda-12` is describing software you are not
    running. Pin an explicit version.

## macOS: Docker cannot reach the GPU

This is the most common wasted afternoon in this ecosystem, so it comes before the Linux
material.

**There is no Metal or Darwin target anywhere in LocalAI's Dockerfile or image
workflows.** A containerised LocalAI on Apple Silicon runs **CPU-only**, inside a Linux
VM. No flag, no image tag and no Docker Desktop setting changes this.

GPU acceleration on a Mac requires the **native install** — the DMG or the install script
— which pulls `metal-darwin-arm64-*` backends.

The practical arrangement on a Mac:

```text
LocalAI          native install (Metal)      host:8080
LocalAGI         container                   -> host.docker.internal:8080
LocalRecall      container                   -> host.docker.internal:8080
```

Everything else in this handbook works unchanged; only LocalAI moves out of Docker. Note
also that **no Intel-Mac binary is published**: release assets cover `linux-amd64`,
`linux-arm64`, `darwin-arm64` and a DMG.

Our own validation was run CPU-only under Docker on Apple Silicon, which is why every
GPU claim on this page is marked source-verified or documented rather than tested.

## NVIDIA on Linux

```bash
nvidia-smi
```

```bash
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

The second command is the one that matters: it proves the **container runtime** can reach
the device. If it fails, LocalAI cannot either, and the problem is the NVIDIA Container
Toolkit rather than LocalAI.

Then match the CUDA major version to the image tag — `-gpu-nvidia-cuda-12` against a
CUDA 12 driver stack, `-cuda-13` against 13.

In Compose:

```yaml
services:
  localai:
    image: localai/localai:v4.8.2-gpu-nvidia-cuda-12
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

## AMD, Intel, Vulkan

| Vendor | Tag | Device passthrough |
|---|---|---|
| AMD | `-gpu-hipblas` | `--device /dev/kfd --device /dev/dri` |
| Intel | `-gpu-intel` | `--device /dev/dri` |
| Any | `-gpu-vulkan` | `--device /dev/dri` |

Vulkan is the fallback worth remembering: vendor-neutral, and often the fastest path to
*some* acceleration on hardware whose vendor-specific stack is awkward. It is usually
slower than the native path.

*(Documented and source-verified from the image workflows. Not tested.)*

## Verifying that the GPU is actually being used

The image tag proves nothing. Neither does `nvidia-smi` showing the process. Check the
backend and the load line.

**1. Which backend was installed:**

```bash
docker exec localai ls /backends
```

A CPU deployment shows `cpu-llama-cpp`. An accelerated one shows a CUDA, ROCm, SYCL or
Vulkan variant. **If you see `cpu-llama-cpp` on a GPU image, you are running on the
CPU** — this is the single most useful check on this page.

Backends are downloaded as OCI artifacts at model-install time, and the variant is chosen
by hardware detection *inside the container*. If the container cannot see the device at
install time, it installs the CPU backend and keeps using it afterwards.

**2. What the log says at load:**

```bash
docker logs localai 2>&1 | grep -i -E 'cuda|rocm|sycl|vulkan|metal|offload|gpu layer'
```

**3. Whether it is faster:**

```bash
time curl -s -o /dev/null http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-1.7b","messages":[{"role":"user","content":"Write two sentences about vectors."}]}'
```

Compare warm calls, not cold ones — the first includes model load either way. For
reference, CPU-only on Apple Silicon produced a completion in **4 s** including load.

## Layer offloading

For llama.cpp-family backends, `gpu_layers` in the model YAML controls how many
transformer layers are placed on the device:

```yaml
name: qwen3-1.7b
backend: llama-cpp
parameters:
  model: Qwen3-1.7B.Q4_K_M.gguf
gpu_layers: 999
```

A high number means "all of them"; the backend clamps to the actual layer count. Partial
offload is the useful case: a model larger than VRAM can put most layers on the device and
the remainder in system RAM, at the cost of the transfer.

Note that `f16: true` and `context_size` interact with VRAM here — a large context reserves
KV-cache memory proportional to it. The reference model's gallery config sets
`context_size: 8192`; raising it to the model's native 32,768 quadruples that reservation.

*(Source-verified from the configuration schema. Not tested.)*

## Failure modes

**GPU image, CPU speed.**

- *Check:* `docker exec localai ls /backends` — is it `cpu-llama-cpp`?
- *Cause:* the device was invisible when the backend was installed, so the CPU variant
  was selected and persists in the `/backends` volume.
- *Fix:* fix device passthrough, then remove the backend volume and let it re-install.
  Merely restarting with the device attached does **not** replace an already-installed
  backend.

**`docker run --gpus all` fails.**

- *Cause:* NVIDIA Container Toolkit not installed or not configured.
- *Check:* the `nvidia/cuda … nvidia-smi` command above.
- *Fix:* install the toolkit. This is not a LocalAI problem.

**Out of memory on load.**

- *Symptom:* the backend dies during load; container exit code 137 for host OOM.
- *Cause:* model plus KV cache exceeds VRAM.
- *Fix:* lower `gpu_layers` for partial offload; reduce `context_size`; use a smaller
  quantisation.

**Two models, one GPU, constant reloading.**

- *Cause:* loading a model may **evict** another, terminating that backend's process.
  Two clients alternating between two models pay a load per request.
- *Fix:* separate deployments per model, or pick one model. See
  [scaling](../07-deep-dives/scaling.md).

**Works standalone, not in Kubernetes.**

- *Cause:* device plugin, resource limits, or node selection — not LocalAI.
- *Fix:* see [Kubernetes](../06-deployment/kubernetes.md).

## What GPU acceleration does not fix

Worth stating, because it is a recurring disappointment:

| Slow thing | Helped by a GPU? |
|---|---|
| Token generation | **yes** — this is the point |
| Embedding a large ingestion | yes, per call, but you still make one call per chunk |
| Model load time | marginally; it is largely I/O |
| **Agent latency** | **only partly** |

That last row matters. An agent request is a loop: [Recipe 5](../05-recipes/agent-with-tools.md)
took 38.7 s for three model calls, and [Recipe 8](../05-recipes/complete-agent-stack.md)
took 24 s for two. A GPU shortens each call; it does not reduce the *number* of calls, and
it does nothing for tool execution or retrieval. Retrieval was **29–37 ms** — already
negligible. If an agent is slow, count the model calls before buying hardware.

## Upstream references

- [LocalAI container documentation](https://localai.io/basics/container/) — image variants and their targets.
- [LocalAI `Dockerfile`](https://github.com/mudler/LocalAI/blob/v4.8.2/Dockerfile) — build targets; the absence of any Metal or Darwin target. Validated against v4.8.2.
- [LocalAI `pkg/model/initializers.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/pkg/model/initializers.go) — backend selection, load and eviction.
- [LocalAI `core/config/backend_config.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/config/backend_config.go) — `gpu_layers`, `f16`, `context_size`.
- [LocalAI releases](https://github.com/mudler/LocalAI/releases/tag/v4.8.2) — published assets; no Intel-Mac binary.
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/) — device passthrough prerequisites.
- Tag suffix inventory, AIO removal and staleness dates, CPU-only latency on Apple Silicon, and retrieval-hop timings: observed 2026-08-17, see [version matrix](../00-overview/version-matrix.md). **No GPU configuration was tested.**
