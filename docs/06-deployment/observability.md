# Observability

What you can actually see, measured rather than assumed. The short version: **logs are
good, metrics are thin, distributed tracing does not exist, and token accounting is
absent at the agent layer.**

Knowing precisely where the gaps are matters more than the usual advice, because two of
this stack's most important failure modes are *silent*.

## What each service exposes

Probed on the reference environment.

| Service | `/metrics` | Health endpoint | Access log | Structured logs |
|---|---|---|---|---|
| LocalAI | **200** | `/readyz` | yes | yes, levelled |
| LocalAGI | **404** | **none** | yes | yes, levelled, with `agent=` |
| LocalRecall | **404** | **none** | yes, JSON | yes, with `caller` |

Two of the three services expose **no metrics at all**. Plan for log-based monitoring,
because that is what exists.

## LocalAI metrics

```bash
curl -s http://localhost:8080/metrics | grep -c '^# HELP'
```

Observed: **44 metric families**.

Two non-metric endpoints fill real gaps and are worth wiring into a dashboard instead:

```bash
curl -s http://localhost:8080/system | jq
```

```json
{"backends":["llama-cpp","cuda12-llama-cpp"],
 "loaded_models":[{"id":"qwen3next-80b-moecpu","backend":"llama-cpp"}]}
```

**This is how you answer "which models are resident"** — admin-gated, and it shows the backend
alias beside the resolved variant. `GET /v1/models/capabilities` similarly reports per-model
capabilities and modalities. Neither is a Prometheus metric, so both need a scraper of their own. Then:

```bash
curl -s http://localhost:8080/metrics | grep '^# HELP' | grep -v '^# HELP go_\|^# HELP process_'
```

Observed: **one**.

```text
# HELP api_call api calls
```

So of 44 families, 43 are Go runtime and process metrics — heap, goroutines, GC, file
descriptors — and exactly one is about LocalAI's own behaviour.

`api_call` is an OpenTelemetry-sourced histogram labelled by `method` and `path`:

```text
api_call_bucket{method="GET",otel_scope_name="github.com/mudler/LocalAI",path="/readyz",le="0"} 0
```

That is genuinely useful: it gives you request rate, error-free latency distribution and
per-endpoint percentiles for everything on the HTTP surface, including
`/v1/chat/completions` and `/v1/embeddings`.

What it does **not** give you:

| Want | Available? |
|---|---|
| Request latency per endpoint | **yes**, via `api_call` |
| Tokens generated or consumed | **no** |
| Model load events and duration | **no** — but the `effective runtime tuning` log line marks each load |
| Which models are resident | **yes — `GET /system`**, not a metric |
| Backend process health or count | **no** |
| Queue depth or concurrency | **no** |
| GPU utilisation | **no** |

Model load is the biggest omission for capacity work: it is the difference between a 4-second
first request and a sub-second warm one, and no metric distinguishes them. You must infer it
from the latency histogram's tail or from the log.

## The traces endpoint that stays empty

```bash
curl -s http://localhost:8080/api/traces/summary | jq
```

```json
{"total":0,"errors":0,"p95_ms":0,"window_hours":24,
 "buckets":[{"start":"2026-08-16T16:21:36Z","count":0,"errors":0}, …]}
```

The endpoint exists, returns 200, and reports a 24-hour window in two-hour buckets. After
dozens of chat completions, embeddings calls and agent requests, it still reported
`total: 0`.

So it is **not** an HTTP request tracer. It is a summary over some other trace concept —
most likely agent jobs in the distributed execution path, which the reference environment
does not use. Do not wire it into a dashboard expecting request traffic; you will get a
flat zero and conclude the system is idle.

*(Observed empty; what populates it was not established.)*

## There is no distributed tracing

No request ID is generated, propagated or logged across the three services. Note the
LocalRecall access log line:

```json
{"time":"2026-08-17T15:42:53.705Z","id":"","remote_ip":"172.18.0.5", …}
```

The `id` field is present and **empty**. No incoming correlation header is honoured and
none is added.

### Correlating a request by hand

Timestamps and container IPs are what you have, and they are enough. This is the technique
used throughout this handbook to prove boundary crossings.

```bash
docker logs localagi 2>&1 | grep -i 'knowledge base'
```

```text
2026-08-17T15:42:53.667Z INFO [Knowledge Base Lookup] Last user message agent=kb-probe
2026-08-17T15:42:53.705Z INFO [Knowledge Base Lookup] Found similar strings in KB agent=kb-probe
```

```bash
docker logs localrecall 2>&1 | grep 'search' | tail -1
```

```json
{"time":"2026-08-17T15:42:53.705Z","remote_ip":"172.18.0.5","method":"POST",
 "uri":"/api/collections/kb-probe/search","user_agent":"Go-http-client/1.1",
 "status":200,"latency_human":"37.190542ms"}
```

Matching `15:42:53.705` on both sides proves the hop and gives its cost. `remote_ip`
identifies the caller; `user_agent: Go-http-client/1.1` distinguishes an internal call from
a `curl`.

If you want real correlation, add it at an ingress proxy and log there. Nothing inside the
stack will do it for you.

## Latency, measured

Reference figures from the validated environment — CPU-only, `qwen3-1.7b`,
`granite-embedding-107m-multilingual`.

| Operation | Latency |
|---|---|
| Embedding call, warm | **0.06–0.09 s** |
| Embedding call, cold (incl. model load) | 3.34 s |
| Chat completion, incl. model load | 4 s |
| LocalRecall ingest (chunk, embed, store) | **34.9 ms** |
| LocalRecall search, direct | **30.4 ms** |
| Retrieval hop inside an agent request | **29–37 ms** |
| Agent, no tools, no knowledge | 2–3 s |
| Agent, knowledge only | **2.27 s** |
| Agent, knowledge + one tool | **24.1 s** |
| Agent, one tool, three model calls | **38.7 s** |

The shape of that table is the lesson. **Retrieval is never your bottleneck** — 30 ms
against a 24-second request. Agent latency is `iterations × model latency`, and the only
lever that matters is the iteration count.

### Count iterations, not seconds

The single most useful diagnostic in this stack:

```bash
docker logs --since 5m localai 2>&1 | grep -c 'chat/completions'
```

| Request type | Expected calls |
|---|---|
| No tools | 1 |
| Knowledge, no tools | 1 |
| One tool | 2–3 |
| Forced reasoning enabled | more — cogito issues additional scoped calls |

A count that climbs during a single request is a loop. Cap it with `loop_detection` and
`max_attempts`.

## Token usage is not available at the agent layer

```json
"usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}
```

Always zero. Hardcoded, with `// TODO: calculate actual usage` beside it in the source.
Verified on every agent response we made.

If you need token accounting, take it from LocalAI's `/v1/chat/completions` responses,
which report real numbers — and remember that **one agent request produces several**, so
you must sum them and you cannot attribute them to an agent without correlating by
timestamp.

## Logs, and how to read them

### LocalAI

```bash
docker logs localai 2>&1 | grep -i error | tail -20
```

Beware `error=<nil>` — a real log line with an empty error, emitted on the gallery-install
failure path. The actual cause is on a nearby line.

```bash
docker logs localai 2>&1 | grep -i -E 'loading model|grpc|127.0.0.1'
```

Model loads and the backend process's gRPC port — where the two-process architecture
becomes visible.

```bash
DEBUG=true
```

Substantially more detail. Note that the reference environment's `.env` exposes this.

### LocalAGI

Levelled, structured, and every agent line carries `agent=<name>` — which is how you
separate interleaved agents in a multi-agent deployment.

```bash
docker logs localagi 2>&1 | grep -E 'Agent Ask|Agent Execute|has finished'
```

Brackets one request. The delta between `Agent Ask()` and `Agent has finished` is the
agent's real cost — and comparing it against your client's timeout tells you whose fault a
504 was.

```bash
docker logs localagi 2>&1 | grep 'we got a response from the agent'
```

Logged at INFO with the final text. **If this line exists and your client timed out, the
timeout was yours.**

Lines also carry `source.file` and `source.L`, so a message points at the exact source
location — unusually helpful when reconciling behaviour against a version.

### LocalRecall

JSON access log plus structured application logs with a `caller` block.

```bash
docker logs localrecall 2>&1 | grep -i 'Chunked file'
```

```text
INFO Chunked file file="/data/assets/kb-probe/<uuid>/kb-fact.txt"
     content_length=207 max_chunk_size=400 chunk_overlap=80 chunk_count=1
```

The single best log line in the stack: it tells you your chunking configuration actually
took effect, which is otherwise invisible.

Remember there is **no shell** in the LocalRecall image — `docker exec` cannot help.
`docker logs` and `docker inspect` are the whole toolkit.

## The two silent failures worth alerting on

Both return HTTP 200 with a plausible answer. Availability monitoring will not catch
either.

### 1. Knowledge layer unreachable

Verified by stopping LocalRecall and re-asking a question whose answer existed only in a
collection: the agent answered "**10 seconds**" where the document said 4200 milliseconds.
`status: completed`, `error: null`.

Logged at **INFO**:

```text
INFO Error finding similar strings inside KB: error="Post \"http://localrecall:8080/api/collections/x/search\": dial tcp: lookup localrecall on 127.0.0.11:53: no such host"
INFO [Knowledge Base Lookup] No similar strings found in KB
```

**Alert on `Error finding similar strings inside KB`.** It is the only default-level signal
that an agent has quietly stopped using its knowledge.

### 2. Knowledge disabled by configuration

The three guards — `enable_kb`, `kb_auto_search`, and a RAG provider existing — log at
**DEBUG only**. At default log level an agent whose knowledge is switched off is
indistinguishable from one whose collection is empty.

No log line will save you here. **Assert configuration instead:**

```bash
curl -s http://localhost:8081/api/agent/<name>/config \
  | jq '{enable_kb, kb_auto_search, kb_results}'
```

Run that as a synthetic check. It is the only reliable detection.

## What to actually monitor

Given what exists, a workable set:

| Signal | Source | Catches |
|---|---|---|
| LocalAI `/readyz` | HTTP | process down |
| **`GET /v1/models` non-empty** | HTTP | **models failed to install** — `/readyz` will not tell you |
| `api_call` p95 by path | `/metrics` | inference and embedding latency regression |
| `GET /api/agents` | HTTP | LocalAGI liveness (the reference healthcheck) |
| `GET /api/collections` | HTTP | LocalRecall liveness — **not** its embeddings edge |
| Synthetic search against a known collection | HTTP | the embeddings edge and the vector store |
| Synthetic agent request with a known answer | HTTP | the whole path, end to end |
| Log match: `Error finding similar strings inside KB` | logs | silent knowledge failure |
| Config assertion on `enable_kb` / `kb_auto_search` | HTTP | silently disabled knowledge |
| `chat/completions` count per request | logs | agent loops |
| PostgreSQL `pg_isready` | exec | vector store down |

The two synthetic checks are the ones that carry real information, because they are the only
things that exercise a full edge. This is exactly what
[`verify-stack.sh`](https://github.com/wrkode/local-ai-stack-handbook/blob/main/scripts/verify-stack.sh)
does, and it is reasonable to run it on a schedule:

```bash
./scripts/verify-stack.sh --agent <canary-agent>
```

It exits non-zero at the first failing layer and names it.

!!! warning "Do not use `/readyz` as a readiness probe"
    Reproduced: with `raw.githubusercontent.com` rate-limiting the host, **both model
    installs failed** while LocalAI logged `core/startup process completed!` and answered
    `/readyz` with `200`, holding zero models.

    Pair it with `GET /v1/models`. In Kubernetes, use `/readyz` for liveness and a
    models-check for readiness — see [Kubernetes](kubernetes.md).

## Gaps, stated plainly

| Gap | Impact |
|---|---|
| No metrics on LocalAGI or LocalRecall | no agent or retrieval metrics at all |
| No request ID propagation | correlation is by timestamp and container IP |
| `usage` hardcoded to zero | no token accounting or cost attribution at the agent layer |
| `/api/traces/summary` empty for HTTP traffic | misleading if dashboarded |
| No model-load metric | cold-start cost invisible except in the latency tail and the `effective runtime tuning` log line |
| Action history capped at 10, in memory | tool audit trail lost on restart |
| API keys have no identity | actions cannot be attributed to a person |
| Knowledge guards log at DEBUG | the most common misconfiguration is invisible |

None of this prevents running the stack. All of it means **you will build monitoring out of
logs and synthetic probes rather than metrics**, and it is better to plan for that than to
discover it.

## Upstream references

- [LocalAI `core/http/app.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/app.go) — middleware chain, metrics and access logging. Validated against v4.8.2.
- [LocalAI `core/http/middleware`](https://github.com/mudler/LocalAI/tree/v4.8.2/core/http/middleware) — the OpenTelemetry `api_call` instrumentation.
- [LocalAI `core/cli/run.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/cli/run.go) — `DEBUG` and log-level configuration.
- [LocalAGI `core/agent/knowledgebase.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/agent/knowledgebase.go) — the DEBUG-level guards at 19-31 and the INFO-level search-error path. Validated against v2.9.0.
- [LocalAGI `webui/app.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/app.go) — hardcoded zero `usage` at 567-571; the `we got a response from the agent` line at 641.
- [LocalAGI `core/state/pool.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/state/pool.go) — `Status.addResult` trimming to ten at 83-90.
- [LocalRecall `main.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/main.go) — Echo logger and recover middleware at 57-58. Validated against v0.6.4.
- [LocalRecall `rag/persistency.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/persistency.go) — the `Chunked file` and `Stored file` log lines.
- [LocalAI `core/http/routes/localai.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/localai.go) — `GET /system` registered with `adminMiddleware` at 417.
- Metric family counts, the 404s on LocalAGI and LocalRecall `/metrics`, the empty `api/traces/summary`, the empty access-log `id`, every latency figure, and the knowledge-down hallucination: observed 2026-08-17 on darwin/arm64.
- `GET /system` and `/v1/models/capabilities` responses, and the `effective runtime tuning` load banner: observed 2026-08-17 on linux/amd64 with a CUDA GPU. See [version matrix](../00-overview/version-matrix.md).
