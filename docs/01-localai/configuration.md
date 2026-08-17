# Configuring LocalAI

Configuration is a kong CLI struct. Every flag carries an `env:` tag, so every
flag is also an environment variable, and the two are the same surface. There are
**261** `env:` struct tags under `core/cli/` naming roughly **290** distinct
variables once legacy aliases are counted (measured against v4.8.2 sources).

This page groups the ones that change behaviour you will notice. The full
enumerated table lives in
[environment variables](../08-reference/environment-variables.md).

## Naming convention

Canonical names are prefixed `LOCALAI_`. Most flags also accept a legacy
unprefixed alias, declared as a comma-separated list where **the first name
wins**:

```go
env:"LOCALAI_MODELS_PATH,MODELS_PATH"
```

So `MODELS_PATH` still works, and `LOCALAI_MODELS_PATH` beats it if both are set.
Four variables are read that have no `LOCALAI_` form at all: `HF_TOKEN`,
`DATABASE_URL`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`.

## Load order

`cmd/local-ai/main.go` loads dotenv files **before** kong parses anything, in
this order:

1. `./.env`
2. `./localai.env`
3. `$HOME/localai.env`
4. `$HOME/.config/localai.env`
5. `/etc/localai.env`

`godotenv.Load` does **not** override variables already present in the process
environment. The practical precedence, highest first:

| Rank | Source |
|---|---|
| 1 | CLI flags |
| 2 | Process environment (`docker run -e`, systemd `Environment=`, shell export) |
| 3 | The five dotenv files, earlier file wins over later |
| 4 | `runtime_settings.json` in the config directory |
| 5 | Built-in defaults |

Rank 4 is the one people trip over: a value saved through the web UI is
**overridden** at every boot by the same value set in the environment. That is
deliberate (`core/application/startup.go` merges the file first, then lets
env/CLI win) but it makes "I changed it in the UI and it reverted" a common
report.

## The `${basepath}` trap

Four defaults are relative to kong's `${basepath}`, which expands to **the
process working directory** — not `/usr/share/local-ai`, not `~/.local/share`:

| Setting | Default |
|---|---|
| `LOCALAI_MODELS_PATH` | `${basepath}/models` |
| `LOCALAI_BACKENDS_PATH` | `${basepath}/backends` |
| `LOCALAI_DATA_PATH` | `${basepath}/data` |
| `LOCALAI_CONFIG_DIR` | `${basepath}/configuration` |

Running `local-ai run` from a different directory silently uses a different tree,
with a fresh empty models list and no agents. In the container this is harmless
because `WORKDIR /` makes the defaults absolute. Outside a container, set all
four explicitly.

## Paths and storage

| Variable | Default | Notes |
|---|---|---|
| `LOCALAI_MODELS_PATH` | `${basepath}/models` | Weights and per-model YAML |
| `LOCALAI_BACKENDS_PATH` | `${basepath}/backends` | Installed backend artifacts |
| `LOCALAI_BACKENDS_SYSTEM_PATH` | `/var/lib/local-ai/backends` | Read-only, package-installed |
| `LOCALAI_DATA_PATH` | `${basepath}/data` | Agent state, jobs, auth DB, traces, MITM CA |
| `LOCALAI_CONFIG_DIR` | `${basepath}/configuration` | Hot-reloaded JSON config |
| `LOCALAI_CONFIG_DIR_POLL_INTERVAL` | unset (fsnotify) | Set e.g. `1m` where fsnotify is unreliable (network mounts, some container runtimes) |
| `LOCALAI_GENERATED_CONTENT_PATH` | `$TMPDIR/localai-<uid>/generated/content` | Not a declared volume |
| `LOCALAI_UPLOAD_PATH` | `$TMPDIR/localai-<uid>/upload` | Not a declared volume |
| `LOCALAI_MODELS_CONFIG_FILE` | unset | One YAML file holding several model configs |
| `LOCALAI_ARTIFACT_DOWNLOAD_CONCURRENCY` | `1` | Parallel file downloads within one model artifact |

The per-UID temp directory exists because a fixed `/tmp/generated` collides
across accounts on multi-user hosts — notably macOS, where `/tmp` is the shared
`/private/tmp`.

## API and server

| Variable | Default | Notes |
|---|---|---|
| `LOCALAI_ADDRESS` | `:8080` | All interfaces |
| `LOCALAI_API_KEY` | unset | Comma-separated static keys. **Setting it turns on authentication for everything** |
| `LOCALAI_CORS` | `false` | See the inversion below |
| `LOCALAI_CORS_ALLOW_ORIGINS` | unset | Required if CORS is on |
| `LOCALAI_DISABLE_CSRF` | `false` | CSRF is **on** by default, Sec-Fetch-Site mode |
| `LOCALAI_DISABLE_HTTP_COMPRESSION` | `false` | Streaming routes are never compressed regardless |
| `LOCALAI_HTTP_COMPRESSION_MIN_LENGTH` | `1024` | |
| `LOCALAI_UPLOAD_LIMIT` | `15` (MB) | Body limit; `/3d/remesh` is exempt at 513 MB |
| `LOCALAI_DISABLE_WEBUI` | `false` | API-only mode |
| `LOCALAI_OLLAMA_API_ROOT_ENDPOINT` | `false` | Registers the Ollama heartbeat on `/`, replacing the UI redirect. `/api/*` Ollama routes are always on |
| `LOCALAI_DISABLE_METRICS_ENDPOINT` | `false` | Metrics are on by default, admin-gated |
| `LOCALAI_DISABLE_GALLERY_ENDPOINT` | `false` | Removes all gallery/model administration routes |
| `LOCALAI_DISABLE_MCP` | `false` | Removes `/v1/mcp/*` and the agent-job routes |
| `LOCALAI_DISABLE_RUNTIME_SETTINGS` | `false` | Ignore `runtime_settings.json` |
| `LOCALAI_MACHINE_TAG` | unset | Adds a `Machine-Tag` response header |
| `LOCALAI_ENABLE_TRACING` | `false` | In-memory request/response capture |
| `LOCALAI_TRACING_MAX_ITEMS` | `1024` | |
| `LOCALAI_TRACING_MAX_BODY_BYTES` | `65536` | `0` = uncapped |
| `LOCALAI_OPEN_RESPONSES_STORE_TTL` | `0` (no expiry) | TTL for stored `/v1/responses` |
| `LOCALAI_BASE_URL` | derived from headers | External base URL for OAuth callbacks and self-referential links |

**The CORS inversion.** With `LOCALAI_CORS=false` LocalAI installs Echo's
permissive default CORS middleware. With `LOCALAI_CORS=true` and no
`LOCALAI_CORS_ALLOW_ORIGINS`, it refuses to register a wildcard policy and warns.
Enabling CORS without an origin list is therefore *more* restrictive than leaving
it off (source-verified, v4.8.2).

## Hardening

| Variable | Default | Effect |
|---|---|---|
| `LOCALAI_ALLOW_INSECURE_PUBLIC_BIND` | `false` | Without it, LocalAI **refuses to start** when bound to a public address with neither an auth DB nor static keys. Loopback, RFC 1918, ULA, link-local and CGNAT/Tailscale ranges are always accepted |
| `LOCALAI_REQUIRE_BACKEND_INTEGRITY` | `false` | Rejects backend installs with no cosign policy (OCI) or no SHA256 (tarball). **Set this in production** |
| `LOCALAI_DISABLE_PREDOWNLOAD_SCAN` | `false` | Disables the best-effort scanner run before downloading files |
| `LOCALAI_OPAQUE_ERRORS` | `false` | Replaces every error body with a blank 500 |
| `LOCALAI_DISABLE_API_KEY_REQUIREMENT_FOR_HTTP_GET` | `false` | Opens GETs matching the regex allowlist |
| `LOCALAI_HTTP_GET_EXEMPTED_ENDPOINTS` | `^/$,^/app(/.*)?$,^/browse(/.*)?$,^/login/?$,^/explorer/?$,^/assets/.*$,^/static/.*$,^/swagger.*$` | Used only with the flag above |
| `LOCALAI_SUBTLE_KEY_COMPARISON` | `false` | See the note below |
| `LOCALAI_EXPOSE_NODE_HEADER` | `false` | `X-LocalAI-Node` leaks internal topology; off deliberately |

Two things to know here:

- The public-bind guard is the most surprising startup behaviour in the product.
  A container run with `--net=host` on a box with a public IP and no
  `LOCALAI_API_KEY` **fails to boot** rather than starting unauthenticated.
- `LOCALAI_SUBTLE_KEY_COMPARISON` presents itself as the switch that enables
  constant-time API key comparison. The legacy key validator uses
  `crypto/subtle.ConstantTimeCompare` **unconditionally**. The flag's help text
  is stale with respect to that code path (source-verified, v4.8.2).

The really load-bearing hardening fact is not a variable: **with no auth DB, every
admin endpoint is open**, because `adminMiddleware` degrades to a no-op. Static
API keys give you a synthetic admin user, so a single shared key is
all-or-nothing access.

## Authentication

Two systems behind one middleware: static keys (`LOCALAI_API_KEY`) and a real
user database.

| Variable | Default | Notes |
|---|---|---|
| `LOCALAI_AUTH` | `false` | Accounts, sessions, per-user keys, quotas |
| `LOCALAI_AUTH_DATABASE_URL` / `DATABASE_URL` | `{DataPath}/database.db` | SQLite path or `postgres://…` |
| `LOCALAI_AUTH_HMAC_SECRET` | auto-generated | **Persist this.** Auto-generated to `{DataPath}/.hmac_secret` (mode `0600`); losing it invalidates every issued API key |
| `LOCALAI_REGISTRATION_MODE` | `open` | `open` \| `approval` \| `invite` |
| `LOCALAI_ADMIN_EMAIL` | unset | Auto-promoted to admin on registration |
| `LOCALAI_DISABLE_LOCAL_AUTH` | `false` | OAuth/OIDC only |
| `LOCALAI_DEFAULT_API_KEY_EXPIRY` | unset | e.g. `90d` |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | unset | **Setting the ID auto-enables auth** |
| `LOCALAI_OIDC_ISSUER` / `_CLIENT_ID` / `_CLIENT_SECRET` | unset | Setting the client ID auto-enables auth |

`LOCALAI_AUTH=true` is not required to end up with authentication on: setting
either OAuth client ID turns it on implicitly.

## Backend lifecycle

These decide how many model processes exist and when they die.

| Variable | Default | Effect |
|---|---|---|
| `LOCALAI_MAX_ACTIVE_BACKENDS` | `0` (unlimited) | LRU eviction beyond this count |
| `LOCALAI_SINGLE_ACTIVE_BACKEND` | `false` | Deprecated alias for `--max-active-backends=1` |
| `LOCALAI_WATCHDOG_IDLE` / `_IDLE_TIMEOUT` | `false` / `15m` | Stop backends idle past the timeout |
| `LOCALAI_WATCHDOG_BUSY` / `_BUSY_TIMEOUT` | `false` / `5m` | Force-kill backends stuck busy past the timeout |
| `LOCALAI_WATCHDOG_INTERVAL` | `500ms` | Tick |
| `LOCALAI_MEMORY_RECLAIMER` / `_THRESHOLD` | `false` / `0.95` | Evict above a VRAM (or RAM, if no GPU) fraction |
| `LOCALAI_VRAM_BUDGET` | unset | `80%` or `12GB`; clamped to physical, can only lower |
| `LOCALAI_SIZE_AWARE_EVICTION` | `false` | Evict the largest model first instead of the least recent |
| `LOCALAI_FORCE_EVICTION_WHEN_BUSY` | `false` | Evict even with calls in flight |
| `LOCALAI_LRU_EVICTION_MAX_RETRIES` / `_RETRY_INTERVAL` | `30` / `1s` | How long an eviction waits for a busy model to idle |
| `LOCALAI_MODEL_LOAD_FAILURE_COOLDOWN` | `10s` | After a failed load, refuse new loads for this long (503 + `Retry-After`), doubling to a 5 m cap; `0` disables |
| `LOCALAI_FORCE_BACKEND_SHUTDOWN` | `false` | Escalate a busy graceful shutdown to a kill |

The cooldown is what stops a polling client from leaking one backend process per
request against a model that cannot load. Disabling it is almost always wrong.
See [backends](backends.md) for the eviction mechanics, including the fact that
evicting one model can kill a *different* backend process.

## Models and galleries

| Variable | Default | Effect |
|---|---|---|
| `LOCALAI_GALLERIES` | `[{"name":"localai","url":"https://index.localai.io/models","mirrors":["github:mudler/LocalAI/gallery/index.yaml@master"]}]` | JSON list |
| `LOCALAI_BACKEND_GALLERIES` | same shape, `/backends` | JSON list |
| `LOCALAI_AUTOLOAD_GALLERIES` | `true` | |
| `LOCALAI_AUTOLOAD_BACKEND_GALLERIES` | `true` | **Why installing a model can install a backend** |
| `LOCALAI_MODELS` | unset | Model config URLs applied at boot, same as positional args |
| `LOCALAI_PRELOAD_MODELS` | unset | JSON list applied at boot |
| `LOCALAI_PRELOAD_MODELS_CONFIG` | unset | Path to a YAML file of the same |
| `LOCALAI_LOAD_TO_MEMORY` | unset | Models loaded into RAM/VRAM at boot |
| `LOCALAI_PRELOAD_BACKEND_ONLY` | `false` | Install/preload, then exit without serving |
| `LOCALAI_EXTERNAL_BACKENDS` | unset | Gallery backends to install at boot |
| `LOCALAI_EXTERNAL_GRPC_BACKENDS` | unset | Externally managed gRPC backends, `name:host:port` |
| `LOCALAI_BACKEND_IMAGES_RELEASE_TAG` / `_BRANCH_TAG` / `LOCALAI_BACKEND_DEV_SUFFIX` | `latest` / `master` / `development` | Fallback tag chain for backend OCI pulls |
| `LOCALAI_AUTO_UPGRADE_BACKENDS` | `false` | |
| `LOCALAI_PREFER_DEV_BACKENDS` | `false` | Inverts the release/development preference |
| `HF_TOKEN` | unset | For gated Hugging Face repos |
| `LOCALAI_VRAM_WARM_LIMIT` | `300` | Gallery entries whose VRAM estimate is warmed at boot; **`0` disables** it. Both upstream compose files set `0` |

Every variable in the top half of that table can extend startup time
unboundedly, because all of it runs before the socket binds.

## Performance

| Variable | Default | Notes |
|---|---|---|
| `LOCALAI_THREADS` | auto (physical cores) | |
| `LOCALAI_CONTEXT_SIZE` | unset | Default context for models that do not set one |
| `LOCALAI_F16` | `false` | f16 flag passed to backends |
| `LOCALAI_DISABLE_HARDWARE_DEFAULTS` | `false` | Turns off automatic batch-size and parallel-slot tuning |
| `LOCALAI_DISABLE_GUESSING` | `false` | Turns off llama.cpp option guessing |

## Agents

The agent pool runs inside the server process by default.

| Variable | Default | Notes |
|---|---|---|
| `LOCALAI_DISABLE_AGENTS` | `false` | Removes the whole `/api/agents` surface |
| `LOCALAI_DISABLE_ASSISTANT` | `false` | Disables the in-process MCP admin server (36 tools, writable — tested 2026-08-17) |
| `LOCALAI_AGENT_POOL_API_URL` | self (`http://127.0.0.1:8080`) | The loopback endpoint agents call |
| `LOCALAI_AGENT_POOL_API_KEY` | first static API key | What agents authenticate with |
| `LOCALAI_AGENT_POOL_DEFAULT_MODEL` | unset | |
| `LOCALAI_AGENT_POOL_EMBEDDING_MODEL` | `granite-embedding-107m-multilingual` | Knowledge-base embedder |
| `LOCALAI_AGENT_POOL_VECTOR_ENGINE` | `chromem` | `chromem` \| `postgres` |
| `LOCALAI_AGENT_POOL_DATABASE_URL` | unset | Required for the postgres engine |
| `LOCALAI_AGENT_POOL_MAX_CHUNKING_SIZE` / `_CHUNK_OVERLAP` | `400` / `0` | |
| `LOCALAI_AGENT_POOL_STATE_DIR` | data path | Holds `pool.json` and per-user directories |
| `LOCALAI_AGENT_POOL_TIMEOUT` | `5m` | |
| `LOCALAI_AGENT_POOL_ENABLE_SKILLS` / `_ENABLE_LOGS` | `false` | |
| `LOCALAI_AGENT_POOL_CUSTOM_ACTIONS_DIR` | unset | |
| `LOCALAI_AGENT_HUB_URL` | `https://agenthub.localai.io` | **A default outbound reference to a third-party service** |
| `LOCALAI_AGENT_JOB_RETENTION_DAYS` | `30` | |

Setting `LOCALAI_API_KEY` without setting `LOCALAI_AGENT_POOL_API_KEY` works,
because the pool defaults to the first static key — but only the first. With a
rotated key list, pin the pool's key explicitly.

## P2P

| Variable | Default | Notes |
|---|---|---|
| `LOCALAI_P2P` | `false` | Generates and prints a token if none is supplied |
| `LOCALAI_P2P_TOKEN` | unset | **The token is the network identity and the crypto material.** Treat it as a secret |
| `LOCALAI_P2P_NETWORK_ID` | unset | Namespaces several logical clusters within one token space |
| `LOCALAI_P2P_DHT_INTERVAL` / `_OTP_INTERVAL` | `360` / `9000` | Used at token generation |
| `LOCALAI_FEDERATED` | `false` | Federated (request load-balancing) mode |

Discovery is DHT + mDNS keyed by the token; there is no registry. Six further
knobs are read straight from the environment rather than through kong, so they do
not appear in `--help`: `LOCALAI_P2P_DISABLE_DHT`, `LOCALAI_P2P_ENABLE_LIMITS`,
`LOCALAI_P2P_LISTEN_MADDRS`, `LOCALAI_P2P_BOOTSTRAP_PEERS_MADDRS`,
`LOCALAI_P2P_DHT_ANNOUNCE_MADDRS`, `LOCALAI_P2P_LIB_LOGLEVEL`, plus
`LOCALAI_P2P_LOGLEVEL`.

## Logging

Global flags, valid on every subcommand:

| Variable | Default | Values |
|---|---|---|
| `LOCALAI_LOG_LEVEL` | `info` | `error`, `warn`, `info`, `debug`, `trace` |
| `LOCALAI_LOG_FORMAT` | `default` | `default`, `text`, `json` |
| `LOCALAI_LOG_DEDUP` | on when stdout is a TTY | Collapses repeated lines |
| `LOCALAI_DEBUG` / `DEBUG` | `false` | Deprecated; **also disables panic recovery** |

For containers and Kubernetes: `LOCALAI_LOG_FORMAT=json` and
`LOCALAI_LOG_DEDUP=false`. Avoid `--debug`/`--log-level=debug` in production —
Echo's `Recover()` middleware is registered only when debug is off, so a panic in
a handler takes the process down instead of returning a 500.

## Runtime settings

A subset of configuration is mutable at runtime through `GET|POST /api/settings`
and persisted to `{ConfigDir}/runtime_settings.json`. It is re-applied at boot
with env and CLI winning over the file. `LOCALAI_DISABLE_RUNTIME_SETTINGS=true`
turns the mechanism off.

The config directory is watched with fsnotify and three files are hot-reloaded:

| File | Handler reloads |
|---|---|
| `api_keys.json` | Static API keys |
| `external_backends.json` | Externally managed gRPC backend registrations |
| `runtime_settings.json` | The runtime settings registry |

The `--localai-config-dir` help text mentions only the first two. The watcher
registers all three, and `application.New` reads `runtime_settings.json` at boot
(source-verified, v4.8.2) — the help string is incomplete.

Watchdog knobs are runtime-settable but **require a restart** to take effect
(`watchdog_enabled`, `watchdog_idle_enabled`, `watchdog_busy_enabled`, the two
timeouts, and the interval).

## Distributed mode

Multi-node operation adds roughly 30 more variables (`LOCALAI_DISTRIBUTED`,
`LOCALAI_NATS_*`, `LOCALAI_REGISTRATION_*`, `LOCALAI_STORAGE_*`,
`LOCALAI_MODEL_SCHEDULING*`) and requires PostgreSQL plus NATS. Two of them are
security-critical:

- The worker's HTTP file-transfer server **fails open** and serves read/write
  access to models, staging and data when no registration token is set. Set
  `LOCALAI_REGISTRATION_TOKEN` **and** `LOCALAI_REGISTRATION_REQUIRE_AUTH=true`.
- Upstream's own compose file states that authentication is required for
  distributed mode and must be backed by PostgreSQL.

The full distributed surface is out of scope for this page; see
[environment variables](../08-reference/environment-variables.md).

## Upstream references

- [`cmd/local-ai/main.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/cmd/local-ai/main.go) — dotenv load order, kong template variables. Validated against v4.8.2.
- [`core/cli/run.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/cli/run.go) — the flag/env surface and every default quoted here. Validated against v4.8.2.
- [`core/cli/context/context.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/cli/context/context.go) — global logging flags. Validated against v4.8.2.
- [`core/application/config_file_watcher.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/application/config_file_watcher.go) — the three hot-reloaded files. Validated against v4.8.2.
- [`core/config/runtime_settings_registry.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/config/runtime_settings_registry.go) — which settings are runtime-mutable and which need a restart. Validated against v4.8.2.
- [`core/http/auth/middleware.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/auth/middleware.go) — unconditional constant-time key comparison. Validated against v4.8.2.
- [`core/http/app.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/app.go) — CORS registration inversion, `Recover()` gating. Validated against v4.8.2.
- [`docker-compose.distributed.yaml`](https://github.com/mudler/LocalAI/blob/v4.8.2/docker-compose.distributed.yaml) — distributed auth requirement, `GODEBUG=netdns=go` workaround. Validated against v4.8.2.
- Assistant MCP tool count and agent-pool loopback URL: observed 2026-08-17 on `localai/localai:latest` reporting `v4.8.2 (5ff25d9d)`.
