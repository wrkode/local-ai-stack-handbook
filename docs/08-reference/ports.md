# Ports

Every listening port in the stack, what binds it, and whether it should be reachable.

## The table

| Service | Port **in container** | Configurable? | Protocol | Reference env host port |
|---|---|---|---|---|
| LocalAI | **8080** | yes — `LOCALAI_ADDRESS` | HTTP | 8080 |
| LocalAGI | **3000** | **no — hardcoded** | HTTP | 8081 |
| LocalRecall | **8080** | yes — `LISTENING_ADDRESS` | HTTP | 8082 |
| PostgreSQL | 5432 | yes | PostgreSQL wire | **not published** |
| LocalAI → backend | ephemeral on `127.0.0.1` | no — allocated per load | gRPC | never published |

Two of those rows cause most of the confusion.

## LocalAGI listens on 3000, and you cannot change it

```go
log.Fatal(app.Listen(":3000"))
```

The address is a literal in `cmd/serve.go`. There is no environment variable, no flag and no
configuration field. Remap it at the container or the proxy:

```yaml
ports:
  - "8081:3000"
```

This is the most common "cannot reach LocalAGI" cause: mapping `8081:8081` produces a
container that listens on 3000 and a mapping that points at nothing.

In Kubernetes the Service must target 3000:

```yaml
ports:
  - port: 3000
    targetPort: 3000
```

## LocalAI and LocalRecall both default to 8080

They cannot both be published on the host at 8080. The reference environment resolves it by
moving LocalRecall's **host** port, leaving both container ports at their defaults:

```text
localai       8080 -> 8080
localagi      8081 -> 3000
localrecall   8082 -> 8080
```

So inside the Docker network, `http://localai:8080` and `http://localrecall:8080` are both
correct — the collision exists only on the host. Configure service-to-service URLs with the
**container** port, never the published one:

| Variable | Correct value | Common mistake |
|---|---|---|
| `LOCALAGI_LLM_API_URL` | `http://localai:8080` | `http://localai:8080` via `localhost` |
| `LOCALAGI_LOCALRAG_URL` | `http://localrecall:8080` | `http://localrecall:8082` — the host port |
| `OPENAI_BASE_URL` (LocalRecall) | `http://localai:8080` | `http://localhost:8080` |

`localhost` inside a container is that container. Use the Compose service name, or
`host.docker.internal` when reaching the host.

## The gRPC ports you never configure

LocalAI does not talk to its backends over a fixed port. On each model load it allocates a
**free port on `127.0.0.1`**, fork/execs the backend's `run.sh` with that address, polls it
with a gRPC health call, then sends `LoadModel`.

| Property | Consequence |
|---|---|
| Ephemeral and per-load | nothing to configure, nothing to firewall |
| Bound to loopback | not reachable from outside the container |
| One per resident model | two models resident means two backend processes |

You will see these in the log, which is where the two-process architecture becomes visible:

```bash
docker logs localai 2>&1 | grep -i -E 'grpc|127.0.0.1'
```

## Exposure

| Port | Who legitimately needs it |
|---|---|
| LocalAGI 3000 | your applications, via an ingress |
| LocalAI 8080 | LocalAGI, LocalRecall, and any application calling inference directly |
| LocalRecall 8080 | **LocalAGI only** |
| PostgreSQL 5432 | **LocalRecall only** |

The reference environment publishes LocalRecall on 8082 **for teaching** — so retrieval can
be probed independently, which the recipes rely on. In a real deployment that port should not
leave the internal network: it is unauthenticated by default and offers both read **and
write** access to your collections, including the ability to poison an agent's memory.

PostgreSQL is deliberately left unpublished there. Uncomment it only to inspect vectors with
`psql`, and comment it back.

## Endpoints worth remembering per port

| Port | Path | Purpose |
|---|---|---|
| LocalAI 8080 | `/readyz` | listener liveness — **not** model readiness |
| LocalAI 8080 | `/v1/models` | the only reliable "is it usable" check |
| LocalAI 8080 | `/metrics` | 44 families, one application-specific |
| LocalAGI 3000 | `/api/agents` | liveness; there is no health endpoint |
| LocalAGI 3000 | `/v1/responses` | the agent entry point |
| LocalRecall 8080 | `/api/collections` | liveness; answers from disk, proves nothing about embeddings |

LocalAGI and LocalRecall expose **no `/metrics`** — both return 404. See
[observability](../06-deployment/observability.md).

## Full route tables

[API map](api-map.md).

## Upstream references

- [LocalAGI `cmd/serve.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/cmd/serve.go) — `app.Listen(":3000")` at 126. Validated against v2.9.0.
- [LocalAGI `docker-compose.yaml`](https://github.com/mudler/LocalAGI/blob/v2.9.0/docker-compose.yaml) — upstream's own `8080:3000` mapping.
- [LocalRecall `main.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/main.go) — `LISTENING_ADDRESS` defaulting to `:8080` at 43-45. Validated against v0.6.4.
- [LocalAI `core/cli/run.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/cli/run.go) — `LOCALAI_ADDRESS`. Validated against v4.8.2.
- [LocalAI `pkg/model/initializers.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/pkg/model/initializers.go) — free-port allocation on `127.0.0.1` and the backend fork/exec.
- The `/metrics` 404s on LocalAGI and LocalRecall, and the metric-family count: observed 2026-08-17, see [version matrix](../00-overview/version-matrix.md).
