# GPU deployment

How to get a device through to LocalAI in Docker, Compose and Kubernetes, and how to prove
it is actually being used. The mechanics of image variants, backends and layer offloading
are in [LocalAI GPU](../01-localai/gpu.md); this page is about the deployment plumbing
around them.

**Only LocalAI needs a GPU.** LocalAGI and LocalRecall are orchestration and I/O; they
never touch a device. That single fact is the strongest argument for splitting LocalAI out
of an integrated deployment — it is the only component with special hardware requirements.

## Three things must agree

```mermaid
flowchart LR
  T["image tag<br/>-gpu-nvidia-cuda-12"] --> A["accelerated"]
  D["device passthrough<br/>--gpus / device plugin"] --> A
  B["backend variant<br/>chosen at model install"] --> A
```

LocalAI does not warn when they disagree. It installs a CPU backend and runs.

## Docker

```bash
docker run -d --name localai -p 8080:8080 --gpus all \
  -v localai-models:/models -v localai-backends:/backends \
  localai/localai:v4.8.2-gpu-nvidia-cuda-12 qwen3-1.7b
```

Prove the runtime can reach the device **before** blaming LocalAI:

```bash
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

If that fails, the NVIDIA Container Toolkit is the problem.

| Vendor | Tag suffix | Passthrough |
|---|---|---|
| NVIDIA | `-gpu-nvidia-cuda-12`, `-gpu-nvidia-cuda-13` | `--gpus all` |
| AMD | `-gpu-hipblas` | `--device /dev/kfd --device /dev/dri` |
| Intel | `-gpu-intel` | `--device /dev/dri` |
| Any | `-gpu-vulkan` | `--device /dev/dri` |
| Jetson | `-nvidia-l4t-arm64`, `-nvidia-l4t-arm64-cuda-13` | `--runtime nvidia` |

## Compose

```yaml
services:
  localai:
    image: localai/localai:v4.8.2-gpu-nvidia-cuda-12
    ports:
      - "8080:8080"
    volumes:
      - localai-models:/models
      - localai-backends:/backends
      - localai-configuration:/configuration
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/readyz"]
      interval: 15s
      retries: 120
      start_period: 30s
```

For AMD or Intel, replace the `deploy.resources` block with device mappings:

```yaml
    devices:
      - /dev/dri:/dev/dri
      - /dev/kfd:/dev/kfd     # AMD only
```

Everything else in the [reference environment](https://github.com/wrkode/local-ai-stack-handbook/tree/main/compose)
is unchanged — LocalAGI, LocalRecall and PostgreSQL are unaffected by the switch.

## Kubernetes

```yaml
    spec:
      containers:
        - name: localai
          image: localai/localai:v4.8.2-gpu-nvidia-cuda-12
          resources:
            limits:
              nvidia.com/gpu: 1
```

A GPU is a **non-overcommittable** resource: `limits` must equal `requests`, and one
container gets whole devices. Consequences that shape the whole deployment:

| Consequence | Detail |
|---|---|
| Replica count is bounded by devices | four GPUs means at most four LocalAI pods, one device each |
| Pods are unschedulable without a device | they stay `Pending`, not `CrashLoopBackOff` |
| Node selection matters | use a node selector or taint/toleration so only GPU nodes are considered |
| Rolling updates need spare capacity | with one GPU and one replica, `maxSurge: 1` deadlocks — the new pod waits for a device the old one holds |

That last row is the one that surprises people. Set `maxSurge: 0` and accept downtime, or
keep a spare device.

```yaml
      nodeSelector:
        nvidia.com/gpu.present: "true"
      strategy:
        rollingUpdate:
          maxSurge: 0
          maxUnavailable: 1
```

Full manifests and the rest of the scaling story: [Kubernetes](kubernetes.md) and
[scaling](../07-deep-dives/scaling.md).

## Apple Silicon

The most common wasted afternoon in this ecosystem.

**There is no Metal or Darwin target anywhere in LocalAI's Dockerfile or image
workflows.** A containerised LocalAI on Apple Silicon is **CPU-only**, inside a Linux VM.
No flag, image tag or Docker Desktop setting changes this.

GPU acceleration on a Mac requires the **native install** (DMG or install script), which
pulls `metal-darwin-arm64-*` backends. The practical arrangement:

```text
LocalAI       native install (Metal)   -> host:8080
LocalAGI      container                -> host.docker.internal:8080
LocalRecall   container                -> host.docker.internal:8080
```

```yaml
services:
  localagi:
    environment:
      - LOCALAGI_LLM_API_URL=http://host.docker.internal:8080
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

The Apple Silicon validation was CPU-only for this reason. The **CUDA 12** path on this page was
validated separately on Ubuntu 24.04 amd64 with an NVIDIA Quadro RTX 6000; **ROCm, Intel SYCL,
Vulkan and Metal remain untested.**

## Proving the GPU is used

The image tag proves nothing. Neither does `nvidia-smi` showing a process.

```bash
docker exec localai ls /backends
```

**A `cpu-llama-cpp` directory on a GPU image means you are running on the CPU.** This is
the single most useful check on this page. Verified on a working CUDA host, `/backends` held
`cuda12-llama-cpp` and `llama-cpp`.

Do **not** judge by the process name: the running binary there was `llama-cpp-cpu-all`, which means
"all CPU microarchitecture variants in one binary", and `nvidia-smi` still attributed 3136 MiB of
VRAM to it. The directory is the signal.

Backends are downloaded as OCI artifacts at **model-install time**, and the variant is
chosen by hardware detection *inside the container*. If the device was invisible then, the
CPU backend was installed — and it persists in the `/backends` volume afterwards.

**Restarting with the device attached does not fix it.** Remove the backends volume and let
it re-install:

```bash
docker compose down
docker volume rm localai-stack_localai-backends
docker compose up -d
```

Then:

```bash
docker logs localai 2>&1 | grep -i -E 'cuda|rocm|sycl|vulkan|offload|gpu layer'
```

```bash
time curl -s -o /dev/null http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-1.7b","messages":[{"role":"user","content":"Write two sentences about vectors."}]}'
```

Compare **warm** calls only — the first includes model load either way. Reference: CPU-only
on Apple Silicon returned a completion in **4 s** including load.

## Memory planning

VRAM must hold the model **and** the KV cache, and the cache scales with context.

| Lever | Where | Effect |
|---|---|---|
| `gpu_layers` | model YAML | how many layers on the device; partial offload puts the rest in system RAM |
| `context_size` | model YAML | KV cache reservation scales with it |
| Quantisation | the model file | Q4_K_M is the reference; smaller quantisations trade quality for memory |

Note that `qwen3-1.7b`'s gallery config sets `context_size: 8192`, not the model's native
32,768. Raising it to 32,768 **quadruples** the KV-cache reservation — the most common cause
of an out-of-memory on load after an apparently harmless configuration change.

Loading a model may **evict another**, terminating that backend's process. Two models
alternating on one device pay a load per request. One model per deployment is the reliable
arrangement.

## What a GPU does not fix

| Slow thing | Helped? |
|---|---|
| Token generation | **yes** — measured **~4.5x** (30 -> 142 tok/s) |
| Embedding a large ingestion | yes per call; the call count is unchanged |
| Model load | marginally; largely I/O |
| Retrieval | **no** — already 30-56 ms |
| **Agent wall-clock** | **yes, substantially — measured ~11x** |

The agent row corrects an earlier, more pessimistic reading in this handbook. A GPU does not
reduce the *number* of model calls an agent makes, so we expected only a partial gain. Measured on
the same node, same model, same request, the agent went from **23.7 s to 2.12 s** — a larger
speed-up than the raw token-rate improvement.

Counting model calls is still the right first move when an agent is slow: a request making six
calls where it should make two is a prompt or model-capability problem, and no device fixes that.
But "a GPU barely helps agents" is not supported by measurement.

**Count the model calls before buying hardware:**

```bash
docker logs --since 5m localai 2>&1 | grep -c 'chat/completions'
```

A request making six calls where it should make two is a prompt or model-capability problem,
and no device fixes it.

## Upstream references

- [LocalAI container documentation](https://localai.io/basics/container/) — image variants and targets.
- [LocalAI `Dockerfile`](https://github.com/mudler/LocalAI/blob/v4.8.2/Dockerfile) — build targets; absence of any Metal or Darwin target. Validated against v4.8.2.
- [LocalAI `pkg/model/initializers.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/pkg/model/initializers.go) — backend selection, load and eviction.
- [LocalAI `core/config/backend_config.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/config/backend_config.go) — `gpu_layers`, `f16`, `context_size`.
- [LocalAI `gallery/qwen3.yaml`](https://github.com/mudler/LocalAI/blob/v4.8.2/gallery/qwen3.yaml) — the `context_size: 8192` the reference model actually uses.
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/) — Docker device passthrough.
- [Kubernetes device plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/) — how `nvidia.com/gpu` is advertised.
- Tag inventory, CPU-only latency, retrieval timings and agent model-call counts: observed 2026-08-17 on darwin/arm64.
- `cuda12-llama-cpp` in use, VRAM attribution, the `cpu-all` binary naming, auto-tuning setting all layers, CUDA OOM at 17,524 and 46,297 MiB, and MoE expert offload: observed 2026-08-17 on Ubuntu 24.04 amd64, NVIDIA Quadro RTX 6000, under Docker.
- GPU **in Kubernetes** — device plugin v0.19.3, `RuntimeClass`, containerd drop-in, 2194 MiB VRAM attributed to the pod, and the 4.5x / 11x measurements: observed 2026-08-17 on k0s v1.34.3. Procedure in [`kubernetes/gpu/`](https://github.com/wrkode/local-ai-stack-handbook/tree/main/kubernetes/gpu). **ROCm, Intel and Vulkan untested.** See [version matrix](../00-overview/version-matrix.md).
