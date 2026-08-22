# A large MoE model on one GPU plus system RAM, in Kubernetes

```yaml
tested:
  date: 2026-08-22
model: Qwen3-Next-80B-A3B-Thinking-Q4_K_M (45.4 GiB, bartowski)
cluster:
  distribution: k0s v1.34.3
  node: bare metal, 12 vCPU, 125 GiB RAM, NVIDIA Quadro RTX 6000 24 GB
versions:
  localai: "v4.8.2"
  backend: cuda12-llama-cpp
results:
  vram_used: 3168 MiB of 24576 — 14% of the card
  throughput: 25.0 tok/s at 600 completion tokens
  cold_first_request: 100 s
  stack_regression: pass — all 7 verify-stack layers after the migration
```

The model configuration is not the hard part — `tensor_buft_overrides` works the same
here as under Docker, and [gpu.md](../../docs/01-localai/gpu.md) covers it. What
Kubernetes adds is a memory cgroup and a storage class, and both defaults are wrong
for a 45 GiB model.

## The two things Kubernetes changes

| | Docker | Kubernetes default | Consequence |
|---|---|---|---|
| Memory ceiling | none unless `--memory` | `limits.memory: 8Gi` | reclaim thrashing, then OOM |
| Model storage | host directory | Longhorn, `numberOfReplicas: 3` | a 120 GiB claim costs 360 GiB |

Neither appears in any model YAML, which is why a configuration that worked under
Docker fails here with no LocalAI-level explanation.

## The memory limit, measured rather than assumed

The obvious reasoning — "the model is 45 GiB, so the limit must exceed 45 GiB" —
reaches the right answer through wrong arithmetic, and the wrong arithmetic will
mislead you when you try to verify it.

With `mmap: true`, weights are file-backed pages charged to the cgroup **as they are
faulted in**. A Mixture-of-Experts model activates a small slice of its parameters
per token — A3B means roughly 3B of 80B — so most expert tensors are never touched by
any single request. Measured on a freshly started pod:

| Point in time | `memory.current` |
|---|---|
| After loading and one short prompt | **7.9 GiB** |
| After a second, different prompt | **8.0 GiB** |
| After five varied prompts | **8.5 GiB**, still climbing |

Resident set as reported by `kubectl top` was 6.7 GiB, against a 45 GiB model.

So the cost is real but **deferred and prompt-dependent**. Two practical consequences:

**Do not size the limit from observation.** A pod that has served a handful of
requests looks like it needs 8 GiB. Size from the file: the limit must exceed the
model's on-disk size, because a sufficiently diverse workload will eventually fault
in every expert.

**The old 8 GiB limit is crossed on roughly the second request.** That is the reason
this fails so confusingly. It does not fail at load, when you would be watching. It
fails later, under a workload that happens to reach an unvisited expert, as reclaim
thrashing — the kernel dropping model pages and re-reading them from disk on every
token — before it ever becomes a clean OOM kill.

`mmap: true` is what makes a limit survivable at all: mapped clean pages are
reclaimable, so the kernel has something to give back under pressure. Set
`mmap: false` and the same limit must hold anonymous memory that cannot be reclaimed,
turning gradual slowdown into an immediate kill.

## Storage: not the default class

`numberOfReplicas: 3` means a 120 GiB claim consumes 360 GiB across the cluster, and
every write during a 45 GiB download replicates twice over the network. On this
cluster the three non-GPU nodes had 87–104 GiB free, so the claim was close to
impossible as well as pointless.

Pointless because model files are a **re-downloadable cache**, and because the pod is
pinned to the only GPU node — the volume can never migrate, so replication protects
nothing that matters.

`local-path` uses `volumeBindingMode: WaitForFirstConsumer`, so the volume is created
on whichever node the pod lands on. Expect the claim to sit `Pending` until then; that
is correct, not a fault.

The trade-off, stated plainly: **this volume dies with the node.** Right for a model
cache, wrong for anything you cannot re-download. Agent state and collections stay on
`localai-data`.

## Order of operations

```bash
kubectl apply -f 01-models-local-path.yaml          # Pending until a pod claims it

# copy existing models across, so the swap does not lose them
kubectl apply -f - < the migrate Job in this README

kubectl apply -f 02-fetch-model-job.yaml            # 45 GiB, ~14 min at 55 MB/s
kubectl -n localai-stack wait --for=condition=complete job/fetch-qwen3next-80b --timeout=3600s

kubectl -n localai-stack cp qwen3next-80b-moecpu.yaml <pod>:/models/   # or exec -i

kubectl -n localai-stack patch deployment localai --patch-file 03-localai-large.yaml
```

Fetch **before** patching. The download runs in its own pod against the same volume,
so LocalAI keeps serving the whole time and the only interruption is the final
rollout.

### Why a Job rather than `/models/apply`

The gallery install runs inside the LocalAI process: a 45 GiB transfer holds one
request open for its duration, and any restart begins again at zero. A Job resumes
with `curl -C -`, survives restarts through `backoffLimit`, and is watchable. It also
verifies the checksum, which the gallery does silently — ours matched:

```text
expected  83481c75cc6c0837ba9afa52b59b4cd3f85f55dd7aa6c60e27230ff329c81367
actual    83481c75cc6c0837ba9afa52b59b4cd3f85f55dd7aa6c60e27230ff329c81367
```

## Three traps hit while doing this

**`curlimages/curl` cannot write to the volume.** It runs as uid 100; a fresh
`local-path` volume arrives root-owned, so the job dies before transferring a byte:

```text
mkdir: can't create directory '/models/llama-cpp/models': Permission denied
```

`runAsUser: 0` in the Job fixes it, and matches the ownership LocalAI's own downloads
create. Same family as PostgreSQL needing `fsGroup` on a fresh Longhorn volume:
**a dynamically provisioned volume is root-owned, and an unprivileged image cannot
use it without being told how.**

**`ReadWriteOnce` means one node, not one pod.** The fetch Job and the LocalAI pod
mounted the same claim simultaneously — that is legal because both were on the same
node. The `nodeSelector` is what guarantees it. Without one, the Job can be scheduled
elsewhere and wait forever on a volume attach.

**`kubectl exec` needs `-i` to accept redirected stdin.** Without it,
`kubectl exec pod -- sh -c 'cat > file' < local.yaml` creates a **0-byte file and
exits 0**. Check the byte count, not the exit status.

## Reading the results

```text
nvidia-smi: 3168 MiB   (the 80B backend)
             216 MiB   (the embedding model)
            ------
            3392 MiB of 24576 — 14% of the card
```

An 80B model occupying 3.1 GiB of VRAM is the whole point of the override: attention
and the shared trunk stay on the device, the experts live in RAM, and MoE sparsity
keeps the RAM traffic per token small. Without it llama.cpp asks for 46,297 MiB and
fails with `cudaMalloc failed: out of memory`.

**25.0 tok/s** at 600 completion tokens, 35 prompt tokens. For comparison on the same
node, `qwen3-1.7b` fully resident on the GPU ran at ~142 tok/s. So the offload costs
roughly 5–6× throughput and buys a 47× larger model on unchanged hardware.

First request took **100 s**, faulting in the initial working set. Later requests do
not repeat that.

### A Thinking model returns empty `content` if you cap tokens low

The first attempt looked like a failure:

```json
{"choices":[{"message":{"content":""}}]}
```

`max_tokens: 80` on a *Thinking* model spends every token inside the reasoning block
and leaves nothing for the answer. Not a loading problem, not an offload problem —
budget several hundred tokens, or use a non-thinking variant.

## Upstream references

- `local-ai run --help`, LocalAI v4.8.2 — `--models-path`, `--data-path`. Read
  2026-08-22 from the running container.
- [`bartowski/Qwen_Qwen3-Next-80B-A3B-Thinking-GGUF`](https://huggingface.co/bartowski/Qwen_Qwen3-Next-80B-A3B-Thinking-GGUF)
  — Q4_K_M, 48,727,678,848 bytes, sha256 `83481c75…c81367`. Retrieved 2026-08-22.
- [GPU acceleration](../../docs/01-localai/gpu.md) — `tensor_buft_overrides`, the
  selective-block variant and the VRAM figures.
- [Kubernetes deployment](../../docs/06-deployment/kubernetes.md) — probes, the
  `/data` volume and the base manifests.
- VRAM, throughput, cgroup and storage measurements: observed 2026-08-22 on
  k0s v1.34.3.
