# Production considerations

An honest assessment. This page exists because "production ready" is a claim that requires
evidence, and for several of the capabilities below the evidence points the other way.

Nothing here says the stack is unfit for real use. It says **which properties you must
supply yourself**, and which are not available at any effort — because that distinction is
what a deployment decision actually turns on.

## Summary

Each row is assessed against v4.8.2 / v2.9.0 / v0.6.4, with the basis stated.

| Capability | Status | Basis |
|---|---|---|
| Inference serving | **usable** | tested |
| Retrieval and RAG | **usable** | tested |
| Single-node agent runtime | **usable** | tested |
| Persistence | **usable, with care** | tested; two-volume coupling |
| Authentication | **available, primitive** | source-verified; no identity, no scopes |
| TLS | **not provided** | source-verified; terminate externally |
| Horizontal scaling of inference | **possible** | source-verified; bounded by devices |
| Horizontal scaling of retrieval | **possible with PostgreSQL** | source-verified |
| **Horizontal scaling of agents** | **not supported** | source-verified; file-based state |
| **Multi-tenancy** | **absent** | source-verified; no tenancy model |
| **Authorization / RBAC** | **absent** | source-verified; keys are all-or-nothing |
| Observability | **thin** | tested; two of three services expose no metrics |
| Token accounting | **absent at the agent layer** | tested; hardcoded zeros |
| Distributed tracing | **absent** | tested; no request-ID propagation |
| High availability | **partial** | inference and retrieval yes; agents no |
| Backup / restore | **do it yourself** | tested; procedure works, nothing built in |
| Tool sandboxing | **absent** | source-verified |
| Auditability | **partial** | tested; last-10, in-memory, no identity |

The three rows in bold are the ones that should change a deployment plan.

## The three hard limits

### 1. The agent runtime is a singleton

Agent definitions are **JSON on disk**, read at boot and rewritten on change. There is no
locking protocol, no leader election, no shared-state backend.

Two replicas sharing a volume are two processes rewriting one inventory: **last writer
wins, and agents disappear.**

It is worse than a data-consistency problem. Agents can act autonomously —
`periodic_runs`, `initiate_conversations`, `permanent_goal`, and any connector — so a second
replica does not share the work, it **duplicates the side effects**. Two replicas with a
scheduled agent send two emails.

| What you can do | What you cannot do |
|---|---|
| Run one replica and restart it quickly | Run two replicas of one agent pool |
| Shard by agent across separate deployments, each with its own state | Load-balance one pool |
| Scale LocalAI behind it freely | Get HA for the agent layer |

Sharding is the real answer if you need more than one node's worth of agents: separate
deployments, separate state volumes, a router in front keyed on agent name. That is work you
do, not a feature you enable.

See [scaling](../07-deep-dives/scaling.md).

### 2. There is no tenancy model

An agent's collection is its **lowercased name**. That is the entire isolation mechanism.

| Consequence | Detail |
|---|---|
| Any valid key reads any collection | keys have no scope |
| Any valid key writes any collection | including agents' memories |
| Case-differing agent names **share** a collection | `Support-Bot` and `support-bot` both use `support-bot` |
| Memory and knowledge share one store | resetting a collection deletes memories too |

**Do not co-tenant.** Separation means separate deployments, separate databases, or a proxy
you write that enforces collection scoping before requests arrive. There is no configuration
that achieves it.

### 3. Authorization does not exist

Authentication does: bearer keys on all three services, constant-time compared in
LocalRecall. Authorization does not.

A key is **all-or-nothing**. There are no users, roles, scopes, per-collection permissions,
per-agent permissions or expiry. In particular:

- Anyone who can create an agent can choose its tools — including `shell-command`. **The
  ability to create an agent is the ability to execute code.**
- Anyone with a key can delete models, reset collections, or delete agents.
- Actions cannot be attributed to a person, because a key is not an identity.

If you need any of this, it belongs in an identity-aware proxy in front, and the audit log
belongs there too.

## What you must supply

| Concern | What to do |
|---|---|
| TLS | terminate at ingress; keep service-to-service traffic on a private network |
| Identity and authorization | identity-aware proxy in front of LocalAGI |
| Audit with attribution | log at that proxy; the stack cannot attribute |
| Backup | see [persistence](persistence.md) — and back up both knowledge volumes together |
| Monitoring | logs and synthetic probes; two services expose no metrics |
| Secret management | agent state contains **plain-text** tokens; treat the volume accordingly |
| Egress control | network policy — assume `browse`, `scraper` and `webhook` are exfiltration paths |
| Rate limiting | at the proxy |
| Tool isolation | read-only root filesystem, minimal mounts, scoped credentials |

## Sizing, from measurement

CPU-only, `qwen3-1.7b`, `granite-embedding-107m-multilingual`.

| Operation | Latency |
|---|---|
| Embedding, warm | 0.06–0.09 s |
| Chat completion, incl. model load | 4 s |
| Retrieval, end to end | **29–37 ms** |
| Agent, no tools | 2–3 s |
| Agent, knowledge + one tool | **24.1 s** |
| Agent, one tool, three model calls | **38.7 s** |

The distribution is the point:

**Agent latency is `iterations × model latency`.** Retrieval is 30 ms against a 24-second
request — it is never your bottleneck, and optimising it is wasted effort.

**Capacity is governed by concurrent model calls**, not by request count. One agent request
can be three or more. Size the inference layer against model calls per second, then divide.

**Timeouts must be ordered:** client > proxy > `LOCALAGI_TIMEOUT` (per model call, default
`5m`). An ingress default of 60 s is shorter than a real agent request, and the failure mode
is a 504 to the client **while the agent completes and commits its side effects**.

## Failure modes to plan for

The two that matter most are silent. Neither shows up in availability monitoring.

### Knowledge fails open

Verified by stopping LocalRecall and re-asking a question whose answer existed only in a
collection. The agent returned HTTP 200, `status: completed`, `error: null` — and answered
"**10 seconds**" where the document said 4200 milliseconds.

**Losing the knowledge layer degrades correctness without degrading availability.** Alert on
the INFO-level log line `Error finding similar strings inside KB`.

### Knowledge disabled by configuration is invisible

The three guards — `enable_kb`, `kb_auto_search`, and a provider existing — log at **DEBUG
only**. An agent whose knowledge is switched off is indistinguishable from one whose
collection is empty. No log line detects it; assert the configuration:

```bash
curl -s http://localhost:8081/api/agent/<name>/config \
  | jq '{enable_kb, kb_auto_search, kb_results}'
```

### The rest

| Failure | Behaviour | Mitigation |
|---|---|---|
| Inference down | loud, immediate | agents fail fast; this is the good case |
| Model gallery unreachable | **install fails, `/readyz` still 200 with zero models** | pre-bake models into the image or the volume; probe `/v1/models` |
| Agent state volume lost | every agent gone | back up the 6 kB |
| Embedding model changed | writes fail, or retrieval silently degrades | treat as collection identity; re-ingest |
| One knowledge volume restored | search works, raw files 404 | back up both together |
| Tool has a side effect on a timed-out request | duplicate emails, duplicate issues | order timeouts; prefer idempotent tools |
| Two agent pools on one state dir | agents disappear | `LOCALAI_DISABLE_AGENTS=true` |

## Version discipline

Two facts that belong in any production decision:

**The newest published LocalAGI image is v2.8.1**, and `v2.9.0` does not exist as an image —
its build has been failing since 2026-04-15. So the newest *release* is not deployable
without building from source.

**v2.8.1 and v2.9.0 differ architecturally.** v2.8.1 does not import LocalRecall at all: no
in-process knowledge layer, no `/api/collections` routes. If you plan around v2.9.0's source
you are planning around software you cannot pull.

**Avoid stale tags.** `latest-aio-*`, `latest-cpu`, `-extras`, `-cuda-11` still resolve but
are frozen builds from 2026-02-21 or earlier — `latest-cpu` since 2025-06-19. Pin explicit
versions and know that pinning LocalAI also pins the LocalAGI, LocalRecall and cogito commits
compiled into it.

## A staged path

Rather than a readiness verdict, the order in which the gaps actually bite.

**Stage 1 — internal, trusted users, one node.** Usable today. Compose environment, one
agent pool, PostgreSQL for hybrid search, backups of agent state and both knowledge volumes,
`verify-stack.sh` on a schedule. Do not enable `shell-command`.

**Stage 2 — internal, many users.** Add authentication on all five hops, TLS at the ingress,
long proxy timeouts, log-based alerting on the knowledge-failure line, and config assertions
on the knowledge flags. Split LocalAI onto its own node so inference scales and restarts
independently.

**Stage 3 — externally reachable.** Add an identity-aware proxy for authorization and
attribution, egress network policy, tool sandboxing with scoped credentials, and rate
limiting. Review every agent's `actions` list as a permission grant. Set a `whitelist` on
every `call_agents`.

**Stage 4 — multi-tenant.** Not achievable by configuration. One deployment per tenant, or a
scoping proxy you build. Do not attempt it by naming conventions on collections.

**Stage 5 — HA for agents.** Not available. Shard by agent, accept single-replica restarts,
or wait for upstream to move agent state into a shared store.

## What would change this assessment

Worth stating so the page can be re-evaluated rather than re-argued:

- Agent state in a database rather than a file → agent HA and horizontal scaling
- Scoped API keys or any authorization model → multi-tenancy becomes conceivable
- Metrics on LocalAGI and LocalRecall → monitoring stops being log-scraping
- Real `usage` numbers → cost attribution and quota
- A relevance threshold on retrieval → knowledge failing closed rather than open
- Request-ID propagation → tracing across the three services

## Upstream references

- [LocalAGI `core/state/pool.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/state/pool.go) — file-based pool persistence; no locking. Validated against v2.9.0.
- [LocalAGI `core/state/config.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/state/config.go) — `periodic_runs`, `initiate_conversations`, `permanent_goal`, `actions`.
- [LocalAGI `webui/collections/rag_provider.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/collections/rag_provider.go) — collection name as the lowercased agent name at 160.
- [LocalAGI `webui/app.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/app.go) — hardcoded zero `usage` at 567-571.
- [LocalAGI `core/agent/knowledgebase.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/agent/knowledgebase.go) — DEBUG-level guards at 19-31; INFO-level search-error path.
- [LocalAGI `webui/routes.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/routes.go) — global keyauth; the four key locations at 252-254.
- [LocalRecall `routes.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/routes.go) — `API_KEYS` with `subtle.ConstantTimeCompare` at 158-175; no per-collection permissions. Validated against v0.6.4.
- [LocalAI `core/cli/run.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/cli/run.go) — `LOCALAI_API_KEY`, `LOCALAI_DISABLE_AGENTS`. Validated against v4.8.2.
- [LocalAI `go.mod`](https://github.com/mudler/LocalAI/blob/v4.8.2/go.mod) — the LocalAGI, LocalRecall and cogito commits compiled in.
- All latencies, the knowledge-down hallucination, the metrics inventory, the `/readyz`-with-no-models reproduction, and LocalAGI v2.8.1's absent LocalRecall dependency: observed 2026-08-17, see [version matrix](../00-overview/version-matrix.md).
