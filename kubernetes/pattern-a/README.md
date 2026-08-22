# Pattern A — chat with retrieval inside LocalAI

```yaml
tested:
  date: 2026-08-22
cluster:
  distribution: k0s v1.34.3
  gpu: NVIDIA Quadro RTX 6000, cuda12-llama-cpp
versions:
  localai: "v4.8.2"
results:
  agent_pool_enabled: pass
  collection_create_ingest_search: pass — similarity 0.693
  agent_answers_from_knowledge: pass — 53 s cold
  remote_localrecall_via_local_rag_url: FAIL — field accepted, silently ignored
```

The base manifests in `../` deploy Pattern B: LocalAI, LocalAGI and LocalRecall as
three processes, retrieval over HTTP. This overlay turns on LocalAI's **embedded**
agent pool so you can chat with a knowledge-backed agent inside LocalAI itself,
with no LocalAGI and no LocalRecall in the request path.

## Read this before you start

**LocalAI cannot use your standalone LocalRecall.** Not "it is awkward" — it does
not happen. The agent config has a `local_rag_url` field, it accepts a URL, it
persists it, and it is **ignored**. See
[the field that does nothing](#the-field-that-does-nothing) for the proof.

So Pattern A means LocalAI keeps its **own** collections. Anything already ingested
into a standalone LocalRecall must be re-ingested. If that is unacceptable, use
Pattern B and chat in LocalAGI instead — LocalAGI's `LOCALAGI_LOCALRAG_URL` *is*
honoured.

## Order of operations

| Step | Command | Skip it and |
|---|---|---|
| 1 | `kubectl apply -f ../04-localai.yaml` | collections vanish on every rollout |
| 2 | `kubectl -n localai-stack patch deployment localai --patch-file 01-enable-agents.yaml` | `/api/agents` stays 404 |
| 3 | `kubectl -n localai-stack rollout status deploy/localai` | you test against the old pod |

Step 1 is not optional. `--data-path` defaults to `/data` and holds `collectiondb`,
agent state, tasks and jobs. The base manifest mounted only `/models` and
`/backends`, so `/data` was the container's writable layer — every ingested
document discarded on the next rollout, silently. The PVC was added for this.

`patch`, not `apply`, in step 2: `01-enable-agents.yaml` is a partial Deployment,
and `kubectl apply -f` on it would prune every field it omits — image, ports,
probes, volume mounts.

## Verify the surface appeared

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://<localai>/api/agents
```

`200` means the pool is up. `404` means `LOCALAI_DISABLE_AGENTS` is still `true` —
check that the patch actually applied, because the first attempt at it fails (see
[the patch trap](#the-patch-trap)).

## The routes, which are not the ones you expect

None of these are in `/swagger/doc.json`; it documents only agent tasks and jobs.
Recorded here because they were established by probing a running v4.8.2.

| Method | Path | Notes |
|---|---|---|
| `GET` | `/api/agents` | **summary object**, not a list: `agentCount`, `agents`, `actions`, `connectors` |
| `POST` | `/api/agents` | create — returns **201** |
| `PUT` | `/api/agents/{name}` | update |
| `DELETE` | `/api/agents/{name}` | delete |
| `GET` | `/api/agents/{name}/config` | the full 57-field config |
| `GET` | `/api/agents/collections` | list |
| `POST` | `/api/agents/collections` | create — `{"name":"..."}` |
| `DELETE` | `/api/agents/collections?name=X` | **query parameter, not a path segment** |
| `POST` | `/api/agents/collections/{c}/upload` | multipart `file=@...` |
| `GET` | `/api/agents/collections/{c}/entries` | `GET` only — `POST` here is 404 |
| `POST` | `/api/agents/collections/{c}/search` | `{"query":"...","max_results":N}` |

Three things to notice. The prefix is `/api/agents/collections`, **not**
`/api/collections` — so it collides with neither LocalRecall's nor LocalAGI's API.
`GET /api/agents` returns a summary where LocalAGI's returns an array. And the
response envelopes differ from LocalRecall's:

```text
LocalAI      {"collections":["x"],"count":1}
LocalRecall  {"success":true,"message":"...","data":{"collections":["x"],"count":1}}
```

**These two APIs are not wire-compatible.** A client written against one will not
work against the other, which matters if you are migrating between patterns.

## Working example

The collection is bound to the agent **by name**. There is no collection field in
the agent config — an agent named `notes` reads the collection named `notes`. So
create the collection first.

```bash
L=http://<localai>

curl -s -X POST "$L/api/agents/collections" \
  -H 'Content-Type: application/json' -d '{"name":"handbook"}'

curl -s -X POST "$L/api/agents/collections/handbook/upload" -F "file=@notes.txt"

curl -s -X POST "$L/api/agents" -H 'Content-Type: application/json' -d '{
  "name":"handbook",
  "model":"qwen3-1.7b",
  "enable_kb":true,
  "kb_auto_search":true,
  "kb_results":1,
  "system_prompt":"Answer from retrieved knowledge. If it is not there, say so."
}'
```

Then chat — the agent name goes in the `model` field, as in LocalAGI:

```bash
curl -s -X POST "$L/v1/responses" -H 'Content-Type: application/json' \
  -d '{"model":"handbook","input":"What does the note say?"}'
```

Observed: 53 s cold on a Quadro RTX 6000, including the embedding backend load.

`kb_auto_search: true` retrieves on every turn. `kb_as_tools: true` instead makes
retrieval a tool the model chooses to call — cheaper, but it will sometimes decline
to look.

## The failure you will actually hit

`kb_results` **must not exceed the number of documents in the collection.**
`chromem` returns a hard error rather than clamping:

```text
Error finding similar strings inside KB: error=nResults must be <= the number of
documents in the collection
[Knowledge Base Lookup] No similar strings found in KB agent="handbook"
```

Both lines are **INFO**. Nothing is logged at ERROR, the HTTP request returns 200,
and the model answers "I do not know" with complete confidence. An empty
collection is the worst case: zero documents, so *any* `kb_results` errors and
every answer is a plausible denial.

If an agent will not answer from its knowledge, check the document count before
anything else:

```bash
curl -s "$L/api/agents/collections/<name>/entries"
```

The same error surfaces directly from the search endpoint, which is the quickest
way to confirm it:

```text
{"error":"nResults must be <= the number of documents in the collection"}
```

## The field that does nothing

The agent config carries `local_rag_url` and `local_rag_api_key`. Setting
`local_rag_url` to a reachable LocalRecall returns 201, and reading the config back
shows the value stored. **It has no effect.** Three independent observations:

**1. LocalAI initialises a local store anyway.** At agent start, with
`local_rag_url=http://localrecall:8080` set:

```text
INFO Chromem collection collectionName="k8s-probe" dbPath="/data/collections"
```

**2. No request ever arrives.** Every entry in the standalone LocalRecall's access
log across the whole test window came from `curl` or a browser. The agent
conversation produced **zero** requests — not a failed one, none.

**3. Seeding LocalAI's own collection fixes it.** A question whose answer existed
only in the standalone LocalRecall got "I do not have access to specific
information about..." Uploading the identical sentence into LocalAI's *own*
collection of the same name, changing nothing else, produced the correct answer.

The field is almost certainly inherited from the shared LocalAGI agent config
struct, where it is honoured. Consistent with a defect already recorded for
LocalAGI, where embeddings do not follow `api_url` either: **in this codebase a
populated URL field is not evidence that anything reads it.**

An absent option would be better than this. An absent option makes you find
another way; a field that accepts your value and discards it makes you believe you
are done.

## Reverting

```bash
kubectl -n localai-stack set env deploy/localai LOCALAI_DISABLE_AGENTS=true
```

Routes disappear; collections stay on the PVC and return if you re-enable. To also
reclaim the storage, delete the `localai-data` PVC after scaling to zero.

## The patch trap

The first `patch` attempt fails:

```text
The Deployment "localai" is invalid: spec.template.spec.containers[0]
.env[0].valueFrom: Invalid value: "": may not be specified when `value` is not empty
```

The base manifest sources `LOCALAI_DISABLE_AGENTS` from a ConfigMap. A
strategic-merge patch merges `env` entries **by name**, so it keeps that
`valueFrom` and adds `value` alongside it, which the API server rejects. The fix is
in `01-enable-agents.yaml` already — an explicit `valueFrom: null` deletes the
reference:

```yaml
            - name: LOCALAI_DISABLE_AGENTS
              valueFrom: null
              value: "false"
```

Worth remembering generally: you cannot override a `configMapKeyRef` with a
literal by merging over it. You must null the reference in the same patch.

## Upstream references

- `local-ai run --help`, LocalAI v4.8.2 — the `agents` flag group and
  `--data-path`. Read 2026-08-22 from the running container.
- `/swagger/doc.json`, LocalAI v4.8.2 — documents `/api/agent/tasks` and
  `/api/agent/jobs` only; the agent-pool and collection routes above are absent
  and were established by probing.
- [LocalAI releases](https://github.com/mudler/LocalAI/releases/tag/v4.8.2) — v4.8.2.
- Route shapes, response envelopes, timings and the `local_rag_url` finding:
  observed 2026-08-22 on k0s v1.34.3.
- [Deployment patterns](../../docs/04-integration/deployment-patterns.md) —
  choosing between A and B.
