# Installing LocalRecall

Standalone LocalRecall is a single static binary in a `scratch` container. It
binds `:8080`, needs a writable `/tmp`, and needs a reachable OpenAI-compatible
embeddings endpoint before it can index anything.

If you are running LocalAI or LocalAGI, you already have LocalRecall — it is
linked into those binaries. Install it separately only when you want a shared
knowledge service, a separate scaling unit, or the web UI. See
[overview](overview.md#who-consumes-it-which-way).

## Images

Registry: `quay.io/mudler/localrecall`. Two images are built from one workflow,
both `linux/amd64` and `linux/arm64`.

| Image | Built from | Tag shape |
|---|---|---|
| Application | `Dockerfile` | `v0.6.4`, plus `latest` (semver builds set `latest=auto`) |
| PostgreSQL | `Dockerfile.pgsql` | `v0.6.4-postgresql` |

**Discrepancy (#9).** `README.md:156` tells you to pull
`quay.io/mudler/localrecall:latest-postgresql`. The workflow sets `latest=false`
for that image (`.github/workflows/image.yml:98`), and commit `910990d` is
literally "Disable latest images for postgresql", so `latest-postgresql` comes
only from the *branch* rule, not from releases. **Pin the version tag:**
`v0.6.4-postgresql`.

## Minimal standalone run

```bash
docker run --rm -p 8080:8080 \
  -e OPENAI_BASE_URL=http://localai:8080 \
  -e OPENAI_API_KEY=sk-anything \
  -e EMBEDDING_MODEL=granite-embedding-107m-multilingual \
  -e COLLECTION_DB_PATH=/db \
  -e FILE_ASSETS=/assets \
  -v localrecall-db:/db -v localrecall-assets:/assets \
  quay.io/mudler/localrecall:v0.6.4
```

Three of those are not optional in practice, whatever the README's env table
implies:

- **`OPENAI_BASE_URL`** — `main.go:61` overwrites go-openai's default
  unconditionally, so leaving it unset yields a bare relative `/embeddings` URL
  and every embedding call fails. Full explanation in
  [embeddings](embeddings.md#openai_base_url-is-effectively-mandatory).
- **`EMBEDDING_MODEL`** — no default at all (`main.go:17`). Unset means an empty
  model name on the wire, which LocalAI rejects. There is no startup validation.
- **`COLLECTION_DB_PATH` / `FILE_ASSETS`** — default to `./collections` and
  `./assets` *relative to the process working directory*. In a `scratch`
  container that is `/`. Mount them explicitly or you will lose the collection
  registry and every uploaded original on container replacement, **including
  under the PostgreSQL engine** (see discrepancy #5 below).

## `docker-compose.yml`

The shipped compose file brings up three services and — worth noticing —
**defaults to the PostgreSQL engine, not the binary's chromem default**.

| Service | Image | Ports | Notable settings |
|---|---|---|---|
| `localai` | `quay.io/go-skynet/local-ai:latest` | 8081 → 8080 | `command: [granite-embedding-107m-multilingual]`, `MODELS_PATH=/models`, `BACKENDS_PATH=/backends` |
| `postgres` | built from `Dockerfile.pgsql` | 5432 | `pg_isready -U localrecall` healthcheck every 10s |
| `ragserver` | built from `Dockerfile` | 8080 | `depends_on: postgres: service_healthy` |

`ragserver` environment (`docker-compose.yml:41-50`): `COLLECTION_DB_PATH=/db`,
`FILE_ASSETS=/assets`, `EMBEDDING_MODEL=granite-embedding-107m-multilingual`,
`OPENAI_API_KEY=sk-1234567890`, `OPENAI_BASE_URL=http://localai:8080`,
`VECTOR_ENGINE=postgres`,
`DATABASE_URL=postgresql://localrecall:localrecall@postgres:5432/localrecall?sslmode=disable`,
and both hybrid weights at `0.5`. Named volumes: `models`, `backends`, `images`,
`postgres_data`, `db`, `assets`.

Two details that bite:

- `OPENAI_BASE_URL=http://localai:8080` has **no `/v1`**. That works only because
  LocalAI registers un-prefixed aliases alongside `/v1/...`. Substituting any
  other OpenAI-compatible server means appending `/v1` yourself.
- **Discrepancy (#3).** `README.md:216` claims `.env` file support and says the
  compose file is configured for it. There is no dotenv library in `go.mod`, no
  env-file loading in `main.go`, and the `env_file: ".env"` line at
  `docker-compose.yml:40` is **commented out**. Pass variables explicitly.

## `Dockerfile` — why `scratch` works

Two stages. Builder is `golang:1.26` running `make build`; runtime is
`FROM scratch` copying only the binary, `/etc/ssl` and `/tmp`.

That is possible because `CGO_ENABLED?=0` (`Makefile:3`) and because PDF
extraction is PDFium compiled to **WebAssembly**, run by an embedded wazero
runtime — no cgo, no libmupdf, no glibc symbol matching. The copied `/tmp` is not
cosmetic: the upload handler and the source manager both call `os.CreateTemp`.

The image has **no non-root `USER` and no `HEALTHCHECK`**. There is also no
health endpoint to point one at; the project's own readiness probe polls
`GET /api/collections` (`Makefile:185`).

**Discrepancy (#7).** `README.md:71` says Go 1.16 or higher. `go.mod:3` requires
`go 1.25.0` and the builder image is `golang:1.26`. CI still pins `^1.22`, which
resolves to the latest 1.x and therefore happens to work.

## `Dockerfile.pgsql`

Not a `postgres:` derivative — a from-scratch build on `ubuntu:24.04`, because
LocalRecall needs three extensions that no stock image carries together.

| Component | How it gets in | Why |
|---|---|---|
| PostgreSQL 18 | PGDG apt repo | base |
| `postgresql-18-pgvector` | apt | the `VECTOR(n)` column type and `<=>` |
| `postgresql-18-timescaledb` | apt | preload dependency |
| `pg_textsearch` | **built from source, pinned to `v1.3.1`** | the `bm25` index access method and `<@>` operator — [storage](storage.md) explains why it is mandatory |
| `pgvectorscale` | built from source via Rust / cargo-pgrx | DiskANN index; optional, falls back to pgvector |

The `pg_textsearch` pin is a v0.6.4 change (commit `d5f4a99`). The comment
records why: building from the moving `main` branch shipped an unreproducible
"1.0.0-dev" whose BM25 index could wedge `INSERT`s on a buffer-content lock and
stall the whole vector store. That same incident produced the connection-timeout
environment variables below.

The `pgvectorscale` build is acknowledged in-file as flaky — it can fail with
SIGILL in some Docker environments, in which case the system falls back to
pgvector. It also clones `main` rather than a tag, contradicting its own adjacent
advice to pin for production.

Runtime shape: `postgres` user pinned to **UID/GID 999** for Kubernetes volume
permissions (set `fsGroup: 999`), `PGDATA=/var/lib/postgresql/data`, defaults
`POSTGRES_DB/USER/PASSWORD = localrecall`, `EXPOSE 5432`, `USER postgres`.

`internal/postgres-init.sh` runs `initdb` with `--auth-local=trust
--auth-host=md5 --encoding=UTF8 --locale=C`, appends
`shared_preload_libraries = 'timescaledb,pg_textsearch'` and
`timescaledb.license = 'timescale'`, restarts to load them, then flips local auth
to `md5`. It **grants the application user `SUPERUSER`**, because the Go code runs
`CREATE EXTENSION` at runtime. That is a deliberate trade and a notable security
posture — if you supply your own PostgreSQL, pre-create the extensions and grant
less.

It also has a fallback that initialises into `/tmp` when `$PGDATA` is not
writable, warning that data will be lost on restart. If you see that warning, fix
the volume permissions rather than proceeding.

`internal/init.sql` is a Go-template file that nothing in the repository renders.
Vestigial; ignore it.

## Environment variables

Sixteen runtime variables. Defaults are applied in `main.go`'s `init()`.

| Variable | Default | Effect |
|---|---|---|
| `COLLECTION_DB_PATH` | `collections` | `collection-*.json` state for **every** engine, and the chromem store root |
| `FILE_ASSETS` | `assets` | root for uploaded originals |
| `EMBEDDING_MODEL` | **none** | model name sent to `/embeddings`; unvalidated |
| `OPENAI_BASE_URL` | **none — effectively required** | base URL; `/embeddings` is appended |
| `OPENAI_API_KEY` | none | bearer token for the embeddings endpoint |
| `LISTENING_ADDRESS` | `:8080` | Echo bind address |
| `VECTOR_ENGINE` | `chromem` | `chromem` \| `postgres` \| `localai` |
| `MAX_CHUNKING_SIZE` | `400` | chunk size in **bytes**; a parse error is fatal at startup |
| `CHUNK_OVERLAP` | `0` | overlap in bytes, word-aligned; a parse error is fatal |
| `API_KEYS` | none (auth **off**) | comma-separated bearer keys, constant-time compared |
| `GIT_PRIVATE_KEY` | none | **base64-encoded** SSH key for private git sources |
| `DATABASE_URL` | none — required for `postgres` | pgx connection string |
| `HYBRID_SEARCH_BM25_WEIGHT` | `0.5` | RRF weight, BM25 arm |
| `HYBRID_SEARCH_VECTOR_WEIGHT` | `0.5` | RRF weight, vector arm |
| `BM25_TEXT_CONFIG` | `english` | text-search config for the BM25 index; **undocumented**, v0.6.4 |
| `POSTGRES_LOCK_TIMEOUT` | `30s` | per-connection `lock_timeout`; `0`/`off` disables |
| `POSTGRES_IDLE_IN_TRANSACTION_TIMEOUT` | `300s` | per-connection idle-in-transaction timeout |
| `POSTGRES_STATEMENT_TIMEOUT` | unset | per-connection `statement_timeout`; index builds exempt |
| `LOCALRECALL_REPOPULATE_DELETE` | unset | **undocumented.** `"true"` makes `RemoveEntry` re-chunk and re-embed the entire collection |
| `LOCALRECALL_PDF_EXTRACT_TIMEOUT` | `60s` | **undocumented.** Go duration or bare integer seconds |

**Discrepancy (#6).** The README env table (`README.md:194-212`) omits the last
three entirely.

**Discrepancy (#5).** `README.md:196` describes `COLLECTION_DB_PATH` as being
"(for Chromem engine)". It is used by **every** engine, including PostgreSQL, to
hold `collection-<name>.json` (`rag/collection.go:70`). A PostgreSQL deployment
that omits it silently writes to `./collections`; losing that directory loses the
external-source registry and the collection list even though the vectors survive
in the database. **Persist `COLLECTION_DB_PATH` and `FILE_ASSETS` regardless of
engine.**

Two variables abort the process on a bad value rather than falling back:
`MAX_CHUNKING_SIZE=400k` and `CHUNK_OVERLAP=none` both call `e.Logger.Fatal` at
startup. There is no range validation either — `MAX_CHUNKING_SIZE=0` is accepted
and clamped to 1 byte inside the chunker, producing one chunk per byte.

## Authentication

Off by default. With `API_KEYS` unset **the entire REST surface, including the web
UI and every collection, is unauthenticated.** That is a material fact for any
deployment where LocalRecall is a separate service on a shared network.

When `API_KEYS` is set, an Echo middleware reads `Authorization`, strips a
`Bearer ` prefix, and compares each configured key with
`crypto/subtle.ConstantTimeCompare`. Because `e.Use` applies globally, the web UI
sits behind the key too — which in a browser means the UI will not load without a
proxy that injects the header.

## The web UI

`GET /` and `GET /static/*`, served from an `embed.FS`. Two hand-written source
files, no bundler: `static/index.html` and `static/js/collectionManager.js`,
using Alpine.js for state. Five hash-routed pages — Search, Collections, Upload,
Sources, Entries — exercising 11 of the 12 API routes (only
`GET /entries/:entry/raw` has no button). Dark mode persists to `localStorage`.

### The UI contradicts the "fully local" claim

**Discrepancy (#2), and the one most likely to matter operationally.**

`README.md:58` states that LocalRecall operates offline without external cloud
dependencies. `static/index.html:7-10` loads **four** assets from **three public
CDNs**:

| Asset | Host |
|---|---|
| Alpine.js 3.x | `cdn.jsdelivr.net` |
| SweetAlert2 11 | `cdn.jsdelivr.net` |
| Tailwind (JIT browser build) | `cdn.tailwindcss.com` |
| Font Awesome 6.5.1 | `cdnjs.cloudflare.com` |

Only `collectionManager.js` is served from the binary.

Believe the code. **The API is offline-capable; the web UI is not.** On an
air-gapped host the page loads unstyled and non-interactive — Alpine never
initialises, so nothing renders. There is no build flag or environment variable
to vendor these locally at v0.6.4.

Workarounds, in order of preference: use the HTTP API directly and skip the UI;
or front LocalRecall with a reverse proxy that serves local copies of the four
assets at the CDN paths. Neither is supported upstream.

Second-order consequence: each of those hosts sees a request carrying your
LocalRecall deployment's referrer whenever an operator opens the UI. If that
matters in your environment, do not expose the UI.

## Verifying an install

There is no health endpoint. The project's own probe is
`GET /api/collections`, which returns `200` with an empty list on a fresh
install and does not touch the embeddings backend.

That means a `200` there proves the HTTP server is up and the state directory is
readable, and **nothing else**. To prove the embeddings path works you must create
a collection (`POST /api/collections` returns `502` with `"Vector backend
unavailable"` when the engine cannot be constructed) and upload a `.txt` file.
See [collections](collections.md) for the request shapes and
[troubleshooting](troubleshooting.md) for what each failure means.

## Upstream references

- [`Dockerfile`](https://github.com/mudler/LocalRecall/blob/v0.6.4/Dockerfile) — `golang:1.26` builder, `FROM scratch` runtime, `EXPOSE 8080`. Source-verified against v0.6.4, validated 2026-08-17.
- [`Dockerfile.pgsql`](https://github.com/mudler/LocalRecall/blob/v0.6.4/Dockerfile.pgsql) — PostgreSQL 18, `PG_TEXTSEARCH_VERSION=v1.3.1` pin, pgvectorscale build, UID 999. Validated 2026-08-17.
- [`docker-compose.yml`](https://github.com/mudler/LocalRecall/blob/v0.6.4/docker-compose.yml) — three services; `VECTOR_ENGINE=postgres`; commented-out `env_file` at line 40. Validated 2026-08-17.
- [`main.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/main.go) — all environment reads at 15-30, defaults in `init()` at 32-53, fatal parse errors at 77 and 86. Validated 2026-08-17.
- [`routes.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/routes.go) — auth middleware at 158-175, `DATABASE_URL` at 103. Validated 2026-08-17.
- [`static/index.html`](https://github.com/mudler/LocalRecall/blob/v0.6.4/static/index.html) — the four CDN `<script>`/`<link>` tags at lines 7-10. Validated 2026-08-17.
- [`internal/postgres-init.sh`](https://github.com/mudler/LocalRecall/blob/v0.6.4/internal/postgres-init.sh) — `shared_preload_libraries`, the `SUPERUSER` grant, the `/tmp` fallback. Validated 2026-08-17.
- [`Makefile`](https://github.com/mudler/LocalRecall/blob/v0.6.4/Makefile) — `CGO_ENABLED?=0` at line 3; readiness probe against `/api/collections` at line 185. Validated 2026-08-17.
- [`.github/workflows/image.yml`](https://github.com/mudler/LocalRecall/blob/v0.6.4/.github/workflows/image.yml) — tag rules, `latest=false` for the postgres image at line 98. Validated 2026-08-17.
- [`README.md`](https://github.com/mudler/LocalRecall/blob/v0.6.4/README.md) — the "fully local" claim (58), `.env` claim (216), Go version (71), env table (194-212), `latest-postgresql` (156). Validated 2026-08-17.
