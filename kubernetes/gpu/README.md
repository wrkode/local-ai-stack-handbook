# GPU on Kubernetes

Four prerequisites must all be true before a pod can use a GPU, and **each one fails with a
different, initially misleading error**. This directory covers all four, in order.

Only LocalAI ever needs a GPU. LocalAGI and LocalRecall are orchestration and I/O.

## The four prerequisites

| # | Requirement | Verify | Failure signature if missing |
|---|---|---|---|
| 1 | NVIDIA driver on the node | `nvidia-smi` | no devices at all |
| 2 | `nvidia-container-toolkit` on the node | `nvidia-container-cli info` | runtime binary not found |
| 3 | **containerd knows the `nvidia` runtime** | `grep -c nvidia /run/k0s/containerd-cri.toml` | `no runtime for "nvidia" is configured` |
| 4 | **Device plugin advertising `nvidia.com/gpu`** | `kubectl get node <n> -o jsonpath='{.status.capacity.nvidia\.com/gpu}'` | pod stays `Pending`: `Insufficient nvidia.com/gpu` |

Steps 1 and 2 are usually already done if Docker on that host can run `--gpus all`. **Steps 3 and
4 are not** — Docker's toolkit configuration does not touch k0s's own containerd.

## Files

| File | Applied by | Needs root |
|---|---|---|
| `containerd-nvidia.toml` | copied into `/etc/k0s/containerd.d/` | **yes** |
| `00-runtimeclass.yaml` | `kubectl apply` | no |
| `01-device-plugin.yaml` | `kubectl apply` | no |
| `02-localai-gpu.yaml` | `kubectl patch --patch-file` | no |

## Step 3 — containerd runtime (root, on each GPU node)

```bash
sudo install -m 0644 containerd-nvidia.toml /etc/k0s/containerd.d/nvidia.toml
sudo systemctl restart k0sworker
```

Verify **before** going further — this is the check that saves time:

```bash
grep -c nvidia /run/k0s/containerd-cri.toml
```

A non-zero count means the drop-in was merged. `0` means it was ignored.

!!! danger "Two ways this silently does nothing"
    **Missing `version = 2`.** k0s merges drop-ins into a v2 containerd config and discards a
    drop-in without that line, with no error anywhere. The symptom is identical to not having
    installed the file.

    **Not restarting.** containerd reads drop-ins only at startup. Check with
    `systemctl show k0sworker -p ActiveEnterTimestamp` — if it predates your edit, the file is
    inert.

### `SystemdCgroup` must match the node's cgroup driver

**k0s uses cgroupfs, so this is `false`.** A kubeadm cluster defaults to the systemd driver and
needs `true`.

Getting it wrong produces a failure that looks like progress, because the runtime lookup now
succeeds and it breaks one layer deeper, in runc:

```text
Failed to create pod sandbox: … OCI runtime create failed: runc create failed:
expected cgroupsPath to be of format "slice:prefix:name" for systemd cgroups,
got "/kubepods/besteffort/pod<uid>/<id>" instead
```

Read the path it *got*: `/kubepods/besteffort/…` **is** the cgroupfs format. So the message is
telling you the runtime was configured for systemd while kubelet is using cgroupfs. Flip
`SystemdCgroup` to `false` and restart.

## Step 4 — device plugin

Label the GPU nodes first, or the DaemonSet lands on CPU-only nodes and crash-loops:

```bash
kubectl label node <gpu-node> nvidia.com/gpu.present=true
```

```bash
kubectl apply -f 00-runtimeclass.yaml
kubectl apply -f 01-device-plugin.yaml
```

```bash
kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds
kubectl get node <gpu-node> -o jsonpath='{.status.capacity.nvidia\.com/gpu}{"\n"}'
```

Expect `1/1 Running` and a capacity of `1`. A healthy plugin logs:

```text
Detected platform: nvml
Using device discovery strategy: nvml
Registered device plugin for 'nvidia.com/gpu' with Kubelet
```

Note that the plugin itself sets `runtimeClassName: nvidia`, because this setup registers nvidia
as an *additional* runtime rather than the node default. Every GPU pod must do the same.

## Step 5 — move LocalAI onto the GPU

```bash
kubectl -n localai-stack patch deployment localai --patch-file 02-localai-gpu.yaml
```

!!! warning "You must also discard the backends volume"
    This is the step people miss, and it produces a GPU deployment that silently runs on the CPU.

    LocalAI chooses its backend variant by **hardware detection at model-install time**, and the
    choice persists in `/backends`. A volume populated while no device was visible holds
    `cpu-llama-cpp`, and LocalAI keeps using it. Switching the image does not change it.

    ```bash
    kubectl -n localai-stack scale deployment localai --replicas=0
    kubectl -n localai-stack delete pvc localai-backends
    kubectl -n localai-stack apply -f ../04-localai.yaml   # recreate the PVC
    kubectl -n localai-stack patch deployment localai --patch-file 02-localai-gpu.yaml
    kubectl -n localai-stack scale deployment localai --replicas=1
    ```

    Scale to zero first so the volume detaches. Full explanation in
    [model runtime abstraction](../../docs/07-deep-dives/model-runtime-abstraction.md).

!!! danger "You also need a `startupProbe`, or the download loops forever"
    The CUDA backend is **1.8 GiB**, and it downloads *before* the HTTP listener starts — so
    `/readyz` refuses connections throughout. A liveness probe then kills the container
    mid-download, and the download restarts from zero.

    Verified: with liveness alone (30 s delay, 6 x 15 s), the install was killed at ~120 s and
    looped **5 times**. Adding a `startupProbe` fixed it — Ready in ~3 minutes, zero restarts.

    ```yaml
    startupProbe:
      httpGet: { path: /readyz, port: 8080 }
      periodSeconds: 15
      failureThreshold: 120      # 30 minutes
    ```

    `../04-localai.yaml` now ships this. Note the CPU backend is small enough to finish inside
    the liveness window, so **this defect appears only on first GPU deployment.**

## Verifying the GPU is really being used

Three checks, in increasing strength.

**1. The installed backend variant** — the single most useful check:

```bash
kubectl -n localai-stack exec deploy/localai -- ls /backends
```

`cuda12-llama-cpp` means a CUDA backend is installed. **`cpu-llama-cpp` on a GPU image means you
are running on the CPU.**

**2. What the log detected:**

```bash
kubectl -n localai-stack logs deploy/localai | grep -i capability
```

```text
INFO Using forced capability run file capability="nvidia-cuda-12"
```

**3. VRAM actually attributed to the process:**

```bash
ssh <gpu-node> nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
```

!!! note "Do not judge by the process name"
    The running binary is `llama-cpp-cpu-all` even on a GPU. That means "all CPU
    microarchitecture variants in one binary" — ggml `dlopen`s the best `libggml-cpu-*.so` at
    runtime — **not** CPU-only execution. The same bundle carries `libcublas` and `libcudart`.

    Judge by the **directory** (`cuda12-llama-cpp`) and by VRAM, never by the binary name.

## Measured: GPU versus CPU

Same node, same model (`qwen3-1.7b` Q4_K_M), same prompt, same 200-token cap, warm.

| Workload | CPU (`cpu-llama-cpp`) | GPU (`cuda12-llama-cpp`) | Speed-up |
|---|---|---|---|
| 200-token completion | 6.67 s / 6.78 s | **1.41 s / 1.50 s** | **~4.5x** |
| Throughput | ~30 tok/s | **~142 tok/s** | ~4.7x |
| Agent: knowledge + tool | 23.7 s | **2.12 s** | **~11x** |
| VRAM used | — | **2194 MiB** | — |

The agent speed-up (11x) exceeds the raw token-rate speed-up (4.7x). A GPU does not reduce the
*number* of model calls an agent makes, so the extra gain comes from each call being faster in
wall-clock terms including its fixed overheads. Whatever the mechanism, the practical answer is
that **a GPU helps agent latency substantially**, not marginally.

VRAM was attributed to the backend process, which is the proof that matters:

```text
1223419, /backends/cuda12-llama-cpp/lib/ld.so, 2194 MiB
```

Note it reads `0 MiB` until the first inference request — LocalAI starts the backend process
lazily, so an idle GPU is not evidence of a broken setup.

## Scheduling consequences

A GPU is a **non-overcommittable** resource: `limits` must equal `requests`, and a container gets
whole devices.

| Consequence | Detail |
|---|---|
| Replicas bounded by devices | one GPU means at most one LocalAI pod |
| No device → `Pending` | not `CrashLoopBackOff`; check `kubectl describe`, not the logs |
| Rolling updates deadlock | with one device, a surging pod waits for the device the old one holds |

Hence `maxSurge: 0` in `02-localai-gpu.yaml`. Accept the brief downtime, or keep a spare device.

Verified with no device plugin installed:

```text
0/4 nodes are available: 4 Insufficient nvidia.com/gpu.
preemption: 0/4 nodes are available: 4 Preemption is not helpful for scheduling.
```

## Memory planning

VRAM holds the model **and** the KV cache, and hardware auto-tuning will try to offload
everything:

```text
INFO effective runtime tuning … n_gpu_layers=99999999 n_batch=512 flash_attention="auto"
```

On a card too small for the model that produces a hard failure naming the exact byte count:

```text
ggml_backend_cuda_buffer_type_alloc_buffer: allocating 17524.43 MiB on device 0:
cudaMalloc failed: out of memory
```

Levers, all in the model YAML: `gpu_layers` for partial offload, `context_size` (the KV cache
scales with it), `cache_type_k`/`cache_type_v` for a quantised cache, and
`options: [tensor_buft_overrides:exps=CPU]` to put MoE experts in system RAM. See
[GPU deployment](../../docs/06-deployment/gpu.md).

`LOCALAI_DISABLE_HARDWARE_DEFAULTS=true` turns the auto-tuner off entirely.

## Removing GPU support

```bash
kubectl -n localai-stack scale deployment localai --replicas=0
kubectl -n localai-stack delete pvc localai-backends
kubectl -n localai-stack apply -f ../04-localai.yaml
kubectl -n localai-stack scale deployment localai --replicas=1
```

Discard the backends volume in this direction too, or LocalAI keeps trying to use a CUDA backend
on a node with no device.

```bash
kubectl delete -f 01-device-plugin.yaml -f 00-runtimeclass.yaml
sudo rm /etc/k0s/containerd.d/nvidia.toml && sudo systemctl restart k0sworker
```
