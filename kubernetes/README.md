# Kubernetes manifests

Plain YAML, deliberately — Helm would hide exactly the details these are meant to show.

> **Not validated.** No Kubernetes deployment was executed during this handbook's validation.
> These manifests are derived from the
> [Compose environment](../compose/README.md), which *was* validated end to end, and from
> upstream source. The workload requirements they encode are source-verified. Treat this as a
> well-founded starting point, not a tested configuration.

The reasoning behind every choice is in
[docs/06-deployment/kubernetes.md](../docs/06-deployment/kubernetes.md). Read that first; this
directory is the artefact, not the explanation.

## Files

| File | Contains |
|---|---|
| `00-namespace.yaml` | the namespace |
| `01-config.yaml` | ConfigMap — non-secret settings |
| `02-secrets.yaml` | Secret — **template; replace every value** |
| `03-postgres.yaml` | StatefulSet + Service for the vector store |
| `04-localai.yaml` | Deployment + Service + PVCs for the model runtime |
| `05-localrecall.yaml` | Deployment + Service + PVC for the knowledge layer |
| `06-localagi.yaml` | Deployment + Service + PVC for the agent runtime |
| `07-ingress.yaml` | Ingress for LocalAGI only, with long timeouts |

Apply in order:

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f .
```

## Four things these encode that are easy to get wrong

**LocalAGI is `replicas: 1`, and must stay that way.** Agent definitions are JSON on disk with
no locking. Two replicas sharing a volume lose agents, and scheduled agents fire once *per
replica* — duplicating side effects rather than distributing work. The PVC is deliberately
`ReadWriteOnce` so the unsafe configuration is hard to build by accident.

**LocalAI's readiness probe checks `/v1/models`, not `/readyz`.** `/readyz` reports that the
listener is up. We reproduced a run where the model gallery was rate-limited, every install
failed, and `/readyz` still returned `200` with **zero models**. A readiness probe on `/readyz`
marks a pod Ready when it can serve nothing.

**LocalRecall has no `exec` probe.** Its image is built `FROM scratch` — no shell, no curl. Only
`httpGet` works, and `GET /api/collections` answers from disk, so it proves liveness and nothing
about embeddings.

**The Ingress read timeout is 600 seconds.** The default 60 is shorter than a real agent
request — 38.7 s was measured for one tool call on CPU. When it fires, the client gets a 504
**while the agent runs to completion and commits its tool side effects.**

## Before you apply

```bash
# 1. Replace every value in the Secret. The five keys must agree:
#    LOCALAI_API_KEY == LOCALAGI_LLM_API_KEY == LOCALRECALL_OPENAI_API_KEY
$EDITOR 02-secrets.yaml

# 2. Set your ingress host
$EDITOR 07-ingress.yaml

# 3. Check your storage class supports ReadWriteOnce
kubectl get storageclass
```

Note the version pins in `01-config.yaml`: LocalAGI is **v2.8.1**, not v2.9.0.
`quay.io/mudler/localagi:v2.9.0` does not exist, and v2.8.1 differs architecturally — it has no
in-process knowledge layer, so `LOCALAGI_LOCALRAG_URL` is required rather than optional. See the
[version matrix](../docs/00-overview/version-matrix.md).

## Verifying

```bash
kubectl -n localai-stack get pods
```

The check that matters is from **inside** the client pod, where DNS and NetworkPolicy actually
apply:

```bash
kubectl -n localai-stack exec deploy/localagi -- curl -s http://localai:8080/v1/models
```

Then run the real verification through port-forwards:

```bash
kubectl -n localai-stack port-forward svc/localai 8080:8080 &
kubectl -n localai-stack port-forward svc/localagi 8081:3000 &
kubectl -n localai-stack port-forward svc/localrecall 8082:8080 &
../scripts/verify-stack.sh
```

## First start is slow

LocalAI downloads ~1.4 GiB of models on first start. The readiness probe allows 30 minutes
(`failureThreshold: 120` at a 15-second period). Lower that and Kubernetes kills the pod
mid-download, forever.

```bash
kubectl -n localai-stack logs -f deploy/localai
```

## GPU

`04-localai.yaml` has the GPU stanza commented out. Uncomment it, switch the image tag, and note
`maxSurge: 0` — with one device and one replica a surging update deadlocks, because the new pod
waits for a device the old pod still holds.

Only LocalAI ever needs a GPU. LocalAGI and LocalRecall are orchestration and I/O.

## What these do not provide

| Missing | See |
|---|---|
| TLS between services | [security](../docs/06-deployment/security.md) |
| PostgreSQL HA | your database operator |
| Metrics for LocalAGI and LocalRecall | **they expose none** — [observability](../docs/06-deployment/observability.md) |
| Horizontal scaling of agents | **not possible** — [scaling](../docs/07-deep-dives/scaling.md) |
| Multi-tenant isolation | **no tenancy model exists** |
| Backup and restore | [persistence](../docs/06-deployment/persistence.md) |
