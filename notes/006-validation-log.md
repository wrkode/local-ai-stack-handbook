# 006 — Validation log

What was actually executed on 2026-08-17, including everything that failed. This is the note
that backs the `tested:` blocks throughout `docs/`.

Two of the handbook's most useful findings came from things going wrong rather than from
reading code, which is the argument for keeping this log rather than only recording successes.

## Environment

```yaml
date: 2026-08-17
host: macOS 26.5.1, arm64 (Apple Silicon)
runtime: Docker Desktop 29.7.2
gpu: none — Docker on macOS has no Metal access
deployment: compose/ reference environment, Pattern B
versions:
  localai: v4.8.2 (5ff25d9d145e0a03a5b9a3559c620f1e1204ca6d)
  localagi: v2.8.1 (image)  # v2.9.0 has no published image
  localrecall: v0.6.4 + v0.6.4-postgresql
vector_engine: postgres
models:
  llm: qwen3-1.7b (Q4_K_M, 1,282,439,296 bytes)
  embeddings: granite-embedding-107m-multilingual (F16, 220,974,080 bytes)
```

## Failure 1 — the model gallery was unreachable

**The most valuable failure of the run**, because it produces a state that looks healthy.

`raw.githubusercontent.com` returned **HTTP 429** to this host, later 503. LocalAI's model
gallery is YAML hosted there, so **no** gallery entry resolved and both model installs failed.

Observed:

```text
ERROR failed to get gallery config for url error=failed to read url "https://raw.githubusercontent.com/mudler/LocalAI/master/gallery/qwen3.yaml", invalid status code 429
INFO  installing model model="qwen3-1.7b" license="apache-2.0"
ERROR [startup] failed installing model error=<nil> model="qwen3-1.7b"
ERROR error installing models error=…
INFO  core/startup process completed!
INFO  LocalAI is started and running address=":8080"
```

Three findings:

1. **`/readyz` returned 200 with zero models installed.** The process reported itself started
   and running. This is why `verify-stack.sh` treats "models resolvable" as a layer distinct
   from "process reachable", and why the handbook repeatedly says `/readyz` is not a readiness
   signal.
2. **`error=<nil>`** — a real error log line with an empty error. An upstream logging defect,
   and a recognisable signature of this failure.
3. **The backend gallery was unaffected.** `/backends/available` returned data throughout,
   because backends are OCI artifacts from a container registry rather than YAML on GitHub.

Confirmed from inside the container:

```text
raw.githubusercontent: 429
huggingface:           200
```

## Dead end — `/models/apply` with an inline `config_file`

`GalleryModel` has a `ConfigFile` field documented as "read in the situation where URL is
blank", so an inline base config looked like the natural gallery bypass.

Attempted: `POST /models/apply` with `name`, a full `config_file`, and a `files` array
carrying the `huggingface://` URI. Result:

```json
{"error":"Get \"\": unsupported protocol scheme \"\"","processed":true}
```

Something on that path still fetches the URL even when `config_file` is supplied. **Not
pursued further** — a working alternative existed. Recorded so nobody else spends the attempt.

*(Unverified whether this is a defect or a misuse of the field.)*

## What worked instead — manual installation

1. Install the backend through the API, which was unaffected:

    ```text
    POST /backends/apply {"id":"llama-cpp"}  ->  completed
    ```

    Produced **two** directories: `llama-cpp` and `cpu-llama-cpp`. LocalAI selects a
    hardware-appropriate variant, so seeing two is normal.

2. Download the GGUFs from Hugging Face directly, using the URIs from the local clone's
   `gallery/index.yaml`, rewritten as `resolve/main` URLs.

3. Write model YAMLs by hand, copying the gallery's own `config_file` for the `qwen3` family.

4. Restart. `/readyz` returned 200 after **~60 s**; `/v1/models` then listed both models.

This is the sequence documented in
[Recipe 1's variations](../docs/05-recipes/localai-chat.md#variations).

### A correction it produced

The gallery's shared `qwen3` `config_file` sets **`context_size: 8192`**, and the
`qwen3-1.7b` entry overrides only `parameters.model`. The effective context window on a stock
install is therefore **8,192**, not the model's native 32,768.

`docs/00-overview/version-matrix.md` said 32,768 and was **corrected**.

## Failure 2: LocalAGI v2.8.1 differs from v2.9.0

Discovered by accident: `GET /api/collections` on LocalAGI returned

```text
Cannot GET /api/collections
```

The routes exist in the v2.9.0 source that had been read. Cloning the **v2.8.1** tag settled
it:

| Check | v2.9.0 | v2.8.1 |
|---|---|---|
| Files importing `mudler/localrecall` | several | **0** |
| `localrecall` in `go.mod` | yes | **absent** |
| `webui/collections*.go` | present | **absent** |
| `/api/collections` routes | 11 | **none** |
| cogito | `v0.9.5-0.20260315…` | `v0.9.1-0.20260216…` |

So the in-process knowledge layer and the collections management API are **v2.9.0-source-only
features that have never shipped as an image** — `quay.io/mudler/localagi:v2.9.0` does not
exist, independently re-verified against the quay tag list (highest tag: `v2.8.1`).

Consequences, now documented across the handbook:

- On any runnable LocalAGI, retrieval is **always** HTTP to a separate LocalRecall.
- `LOCALAGI_LOCALRAG_URL` is **required**, not an opt-in.
- Collections must be managed against LocalRecall directly.

`docs/04-integration/localagi-localrecall.md` originally described the in-process path as "the
default" and was **corrected** with a prominent version warning.

## Failure 3 — an invalid test that looked like a result

Worth recording because the wrong conclusion was briefly reached.

To test agent behaviour with the knowledge layer down, `docker compose stop localrecall` was
run **from the repository root**, where there is no compose file, with stderr redirected. It
silently did nothing. The agent then answered correctly, and the first reading was "the agent
somehow still has knowledge".

`docker ps` showed LocalRecall still running. Re-run from `compose/`, the real result was very
different — see below.

**Method note:** always assert the precondition of a negative test. A test that cannot fail is
not evidence.

## Finding — knowledge fails open, and loudly enough to alert on

With LocalRecall genuinely stopped, an agent that had answered "4200 milliseconds" from a
document instead answered:

```text
The Zeppelin-7 telemetry bus uses a heartbeat interval of **10 seconds**
to maintain communication reliability.
```

HTTP 200, `status: completed`, `error: null`. **Availability preserved, correctness destroyed.**

The log did report it, at **INFO**:

```text
INFO Error finding similar strings inside KB: error="Post \"http://localrecall:8080/api/collections/full-stack-probe/search\": dial tcp: lookup localrecall on 127.0.0.11:53: no such host"
INFO [Knowledge Base Lookup] No similar strings found in KB
ERROR Observable completed without any progress id=6 name=job
```

This **corrected** an earlier claim in `docs/04-integration/deployment-patterns.md` that the
failure was "logged at debug only". The distinction is now documented precisely:

| Failure | Log level | Visible by default |
|---|---|---|
| Knowledge service unreachable | **INFO** | yes |
| Knowledge disabled by config (three guards) | **DEBUG** | no |

Both return 200 with an unreliable answer; only the first leaves a default-level trace.

## The retrieval trace

The measurement that turned the architecture diagram into evidence. Agent `kb-probe`,
`enable_kb` and `kb_auto_search` on, asked about a fact existing only in its collection.

LocalAGI:

```text
15:42:53.667 INFO [Knowledge Base Lookup] Last user message agent=kb-probe
15:42:53.705 INFO [Knowledge Base Lookup] Found similar strings in KB agent=kb-probe
  results="- The Zeppelin-7 telemetry bus uses a heartbeat interval of 4200 milliseconds. …
    (map[created_at:2026-08-17T15:42:42Z file_name:kb-fact.txt source:e040fb16-…/kb-fact.txt
     title:e040fb16-…/kb-fact.txt type:file]) \n"
```

LocalRecall, same instant:

```json
{"time":"2026-08-17T15:42:53.705Z","remote_ip":"172.18.0.5","method":"POST",
 "uri":"/api/collections/kb-probe/search","user_agent":"Go-http-client/1.1",
 "status":200,"latency_human":"37.190542ms"}
```

Confirmed empirically rather than by reading code:

- The collection **is** the lowercased agent name.
- The query **is** the latest user message, verbatim.
- The result format **is** `fmt.Sprintf("%s (%+v)")` — **Go map syntax reaches the model**.
- The hop is real: `172.18.0.5` is the LocalAGI container.
- Cost: **37.19 ms** of a 2.27 s request.

## Finding — a correct tool call, narrated incorrectly

Prompt: *"Increase the counter named apples by 7, then tell me its value."*

Agent history, newest first:

```text
Action taken: counter  Parameters: {"adjustment":0,"name":"apples"}  Result: Current value of counter 'apples' is 7
Action taken: counter  Parameters: {"adjustment":7,"name":"apples"}  Result: Created counter 'apples' with initial value 7
```

Reply: *"The counter 'apples' was increased by 7 to **14**. Its current value is 14."*

| Layer | Correct? |
|---|---|
| Tool selection, arguments, execution, results | yes |
| The model's prose about the results | **no** |

The agent behaved correctly; the 1.7B model's summary did not. Hence the handbook's rule:
`/api/agent/:name/status` is ground truth, the reply is a summary written by the weakest
component.

Related, **not traced**: a direct `POST /api/action/counter/run` for the same counter name
reported `initial value 0`, so a direct action run does not share state with the agent's
invocations. The scoping mechanism was not established.

## Finding — an unknown `previous_response_id` does not error

```text
previous_response_id: "does-not-exist-at-all"
-> 200, "I don't have access to personal information such as favorite colors."
```

No error, no warning. Consistent with the source: `GetConversation` returns an empty
conversation for unknown or expired keys. So valid-but-new, expired, and never-existed are
**indistinguishable** to a client.

Also confirmed: chaining works, and each reply returns a **new** UUID
(`b9ec1e4d-…` → `00c6abcf-…`). The response `id` is a **bare UUID**, not `resp_…`, and
`previous_response_id` is echoed back as `null` even when sent.

## Finding — observability is thinner than expected

| Probe | Result |
|---|---|
| LocalAI `/metrics` | 200, **44 metric families** |
| …of which application-specific | **1** (`api_call`) — the other 43 are Go runtime and process |
| LocalAGI `/metrics` | **404** |
| LocalRecall `/metrics` | **404** |
| LocalAI `/api/traces/summary` | 200, but `total: 0` after dozens of requests |
| LocalRecall access log `id` field | present and **empty** — no request-ID propagation |
| Agent `usage` | all zeros, matching `// TODO: calculate actual usage` |

`/api/traces/summary` is therefore **not** an HTTP request tracer. What populates it was not
established; likely agent jobs in the distributed path, which this environment does not use.

## Finding — LocalAI's MCP server is narrower than assumed

```text
INFO LocalAI Assistant in-memory MCP server initialised tools=36 read_only=false
```

Probed `/mcp`, `/api/mcp`, `/mcp/sse` — **all 404**. So it is in-memory, backing LocalAI's own
Assistant, with no default external HTTP path.

This **corrected** wording in `docs/00-overview/architecture.md` and
`docs/04-integration/overview.md`, both of which had said it exposed an administration surface
"to any MCP client". `read_only=false` remains significant: the Assistant is a model-driven
agent with 36 writable tools over the runtime.

## Measurements

| Operation | Result |
|---|---|
| Embedding dimensions | **384** |
| Embedding magnitude | **0.9999999536** — L2-normalized to float32 precision |
| Similarity: paraphrases | **0.868** |
| Similarity: unrelated | **0.540** — the floor is not zero |
| Chat completion, incl. model load | 4 s |
| LocalRecall ingest (207 bytes, 1 chunk) | 34.9 ms |
| LocalRecall search, direct | 30.4 ms |
| Retrieval inside an agent request | 29–37 ms |
| Agent, no tools | 2–3 s |
| Agent, knowledge only | 2.27 s |
| Agent, knowledge + 1 tool, 2 model calls | 24.1 s |
| Agent, 1 tool, 3 model calls | **38.7 s** |
| LocalAGI action / connector counts | **40 / 9** |
| PostgreSQL extensions | `plpgsql`, `pg_textsearch`, `vector`, `vectorscale` |
| Volume: agent state | **6.1 kB** |
| Volume: models | 1.503 GB |
| Volume: postgres | 66.23 MB for one document — a baseline, not data |

The similarity floor of 0.54 is the number that most changed how the handbook describes
retrieval: combined with the absence of any relevance threshold, it means top-*k* always
returns *k* results, however irrelevant.

## Finding: `max_tokens` too low returns an *empty* answer

Found while writing `examples/01-localai/run.sh`, which originally used
`max_tokens: 128`.

| `max_tokens` | `finish_reason` | `content` | completion tokens |
|---|---|---|---|
| 128 | `length` | **`''` — empty** | 128 |
| 600 | `stop` | one correct sentence | **371** |

`qwen3-1.7b` is reasoning-tuned and the thinking counts against the budget, so a low
`max_tokens` is not a short answer — it is **no answer**. It needed **371 completion tokens to
produce one sentence**.

`reasoning_content` was **absent** from the response in both cases, so those tokens are consumed
without being exposed — despite the gallery config's `use_jinja: true` comment describing native
classification of `<think>` blocks into `reasoning_content`. *(Why it is absent was not
established.)*

Documented in [Recipe 1](../docs/05-recipes/localai-chat.md#run-the-request).

## Correction: search results *do* carry a `Similarity` field

An early draft said no similarity score is returned. Running
`examples/03-localrecall/run.sh` showed the field exists:

```json
{"ID":"1","Metadata":{…},"Embedding":null,"Similarity":0,"Content":"The Zeppelin-7 …"}
```

Present, and **observed as `0`** on the PostgreSQL engine. The practical conclusion is unchanged
— you still cannot tell how good a match was — but the claim was imprecise and was corrected in
Recipe 3, the storage map and the glossary. *(Whether other engines populate it was not
tested.)*

## Defect in our own toolchain: an impossible pin

`requirements-docs.txt` pinned `pymdown-extensions==11.0.1` with a comment claiming it had been
verified against PyPI. **That version does not exist** — the highest is `10.21.3`. The documented
install sequence would have failed for every reader.

Corrected to `10.21.3`, after which `mkdocs build --strict` completed in 2.22 s with no
warnings. The other three pins were genuine.

A pin is a testable claim. This one had not been tested, and the comment asserting otherwise made
it worse.

## What the examples validated

Every script under `examples/` was executed against the live stack, which is what promotes the
recipes' commands from "derived" to "run":

| Example | Result |
|---|---|
| `01-localai` | pass — and surfaced the `max_tokens` finding above |
| `02-embeddings` | pass — 384 dims, magnitude 0.9999999536, 0.868 vs 0.540 |
| `03-localrecall` | pass — full round trip; surfaced the `Similarity` correction |
| `04-agent` | pass — chaining works; unknown id returns 200 with no history |
| `05-agent-tools` | pass — two correct tool calls; **this run the narration was also correct**, unlike the earlier one |
| `06-agent-memory` | pass — retrieval hop 32.18 ms, timestamps matched on both sides |
| `07-mcp` | **not run** — no MCP server; templates only, and the README says so |
| `08-full-stack` | pass — `adjustment: 42`, **2 model calls**, **1 retrieval call** |

Example 05 is worth noting: the same prompt that earlier produced *"increased by 7 to 14"*
produced a correct summary this time. **The narration error is non-deterministic**, which makes
it worse to rely on, not better.

Example 08 confirmed the boundary arithmetic directly: one client request, two model calls, one
retrieval call — so **retrieval happens once per request, not once per iteration.**

## Bugs found in our own tooling by running it

Recorded because they are the reason `verify-stack.sh` can be trusted.

| Bug | Fix |
|---|---|
| macOS bash 3.2 + `set -u` + `"${empty_array[@]}"` → `unbound variable` | `${arr[@]+"${arr[@]}"}` |
| `wc -l` undercounts a final line with no trailing newline | `grep -c '.'` |
| Greedy `sed` on `"id":"…"` captures the **last** id (`msg_…`), not the response id | `jq -r '.id'` |
| `check-links.py`: `[*_]` emphasis regex ate intra-word underscores | word-boundary-only underscore emphasis |
| `check-links.py`: underscores collapsed to hyphens in slugs | only whitespace collapses |
| `check-links.py`: inline code parsed as links | strip code spans before link extraction |

The third bug is instructive: it briefly produced what looked like a real finding
("`previous_response_id` doesn't work") that was purely an extraction error.

## Not executed

Recorded so the gaps are explicit. Every page describing these is source-verified, not tested.

| Configuration | Status |
|---|---|
| LocalAGI v2.9.0 in any form | no published image; not built from source |
| Embedded in-process knowledge layer | absent from v2.8.1 |
| LocalAGI `/api/collections` | absent from v2.8.1 |
| `chromem` engine | only `postgres` was exercised |
| Hybrid search weight tuning | engine used; weights not varied |
| MCP servers, any kind | not executed |
| Multi-agent delegation | not executed |
| Long-term memory write-back | observed disabled |
| Any GPU configuration | none available under Docker on macOS |
| Kubernetes | not executed |
| linux/amd64 | not executed |
| Distributed mode (NATS) | not executed |
| Multiple replicas of anything | not executed |

## Open questions

1. What populates `/api/traces/summary`? It stayed at zero throughout.
2. Why does `/models/apply` with an inline `config_file` and no `url` still fetch a URL?
3. Where is `counter` state scoped, and why does a direct action run not share it with the
   agent's invocations?
4. Is an A→B→A delegation cycle prevented? Self-calls are excluded; cycles were not tested.
5. What does `LOCALAI_AUTH` / `LOCALAI_AUTH_DATABASE_URL` / `LOCALAI_AUTH_HMAC_SECRET`
   actually provide? It suggests more than a shared bearer key and is undocumented in the
   material reviewed.
6. Does `vectorscale`'s presence mean DiskANN indexes are used, or merely available?
