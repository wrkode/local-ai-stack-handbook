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
| `POST` | `/api/agents/import` | import a config — **201**; empty body gives 400 |
| `GET` | `/api/agents/{name}/export` | the config, as import expects it |
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

## Binding an agent to a collection

There is **no way to point an agent at a collection of your choosing.** The 57-field
config has no collection reference, and the agent form in the WebUI contains no
collection control at all — zero occurrences of the word.

The binding is implicit: **an agent reads the collection named after itself,
lowercased.**

Verified with two canaries. An agent named `AutoResearchAgent`, with one document in
a collection named `AutoResearchAgent` and a different document in
`autoresearchagent`:

```text
[Knowledge Base Lookup] Found similar strings in KB agent="AutoResearchAgent"
  results="- The lowercase canary is LOWERCASE-3390. (file_name:c-lower.txt ...)"
```

It read the **lowercase** one. Both exist as separate directories under
`/data/assets/`, so the mixed-case collection is not an alias — it is a decoy that
is created and then never read.

This matters because the UI will happily create the mixed-case collection for you.
Upload your documents into it and retrieval stays empty forever, with the
`nResults` error below as the only clue.

So to attach an existing collection to an agent, one of:

| Approach | Cost |
|---|---|
| Name the agent after the collection, lowercased | none — the collection must already be lowercase |
| Re-upload the documents into the agent's own lowercased collection | duplicate storage |
| Rename the collection | **no rename API exists**, and delete is a no-op |

The first is the only clean one. An agent named `vquasar` reads collection `vquasar`
immediately, no copying — verified answering from a 3-document collection.

## `long_term_memory` can crash the whole server

The most serious thing found in this pass. With `long_term_memory` and
`summary_long_term_memory` enabled, the agent writes each conversation back to its
knowledge base, summarizing first. When the conversation exceeds the model's context
the summarization fails — and the error path dereferences a nil pointer:

```text
INFO  Saving conversation agent="AutoResearchAgent" conversation size=4
ERROR Error summarizing conversation error=rpc error: code = Internal desc =
      request (14899 tokens) exceeds the available context size (8192 tokens)
panic: runtime error: invalid memory address or nil pointer dereference
[signal SIGSEGV: segmentation violation code=0x1 addr=0x10 pc=0xf9ab63]
LocalAGI/core/agent.(*Agent).saveCurrentConversation
    core/agent/knowledgebase.go:147
```

`saveCurrentConversation` at `knowledgebase.go:147`, reached from `consumeJob`. The
process exits **2** and Kubernetes restarts the pod, so this is not one agent
failing — **the entire LocalAI server goes down**, every model unloaded, every other
agent interrupted. Reachable from an ordinary chat turn, after the answer has already
been returned successfully.

RAG makes it likelier, not less: retrieved chunks inflate the conversation, so a
knowledge-backed agent reaches the context limit sooner than a bare one. Observed on
a 4B model at 8192 context after **four** messages.

Mitigations, in order of preference:

| Fix | Effect |
|---|---|
| `summary_long_term_memory: false` | no summarization call, so the nil path is never reached |
| `long_term_memory: false` | no write-back at all |
| Raise the model's context in its YAML | postpones it; does not remove the bug |

**Persist `/data` before you enable long-term memory.** Without the PVC this crash
takes every agent and collection with it. With it, a crash mid-session lost nothing:
three agents and six collections came back intact.

## `can_stop_itself` turns answers into errors

An agent with `can_stop_itself: true` may conclude the conversation instead of
replying, which surfaces through `/v1/responses` as a server error rather than as a
graceful ending:

```text
{"error":{"message":"interrupted via ToolCallCallback","type":"server_error"}}
```

Preceded in the log by the model's own reasoning — *"Since this query requires access
to data I cannot provide, I must conclude the conversation."* Setting
`can_stop_itself: false` produced a normal answer to the identical prompt with
nothing else changed.

Note the interaction with the `nResults` bug: an agent that cannot retrieve decides it
lacks the data, stops itself, and returns a `server_error`. Two separate defects
compounding into a symptom that looks like neither.

## Ingest raw URLs, not rendered pages

A collection built from GitHub *blob* URLs stores the page furniture, not the
document. Retrieved chunks looked like:

```text
Breadcrumbs * vquasar / docs / prerequisites.md Copy path Blame More file actions
Latest commit History Copy raw file Download raw file Outline Edit and raw actions
```

With `MAX_CHUNKING_SIZE=400`, navigation boilerplate consumes whole chunks and the
answer degrades to naming the file it could not read. Ingest
`raw.githubusercontent.com/...` rather than `github.com/.../blob/...`.

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

## Importing an agent

`POST /api/agents/import` with an exported config body. Verified: **201**.

```bash
curl -s "$L/api/agents/<name>/export" -o agent.json
# edit "name" in agent.json first — see below
curl -s -X POST "$L/api/agents/import" \
  -H 'Content-Type: application/json' --data-binary @agent.json
```

The body is the same 57-field object `GET /api/agents/{name}/export` produces. An
empty body returns `400`, which is the quickest way to confirm the route exists.

**Change `name` before importing.** The exported file carries the source agent's
name, so importing it unedited recreates the same name rather than a copy.

**Import does not bring knowledge with it.** Collections bind to agents *by name*,
and the config contains no collection reference. An agent imported under a new name
gets a freshly auto-created, **empty** collection — and then hits the `kb_results`
error above and denies all knowledge:

```text
INFO Error finding similar strings inside KB: error=nResults must be <= the number
     of documents in the collection
INFO [Knowledge Base Lookup] No similar strings found in KB agent="imported-probe"
```

Observed exactly that on a fresh import. Re-upload the documents under the new
agent's name to fix it.

### Where the button is in the UI

On `/app/agents`, in the page header, next to **Create Agent**. Two reasons it is
easy to miss:

It is a `<label class="btn btn-secondary">` wrapping a hidden
`<input type="file" accept=".json">` — not a `<button>`. It is styled as a
secondary (grey) control beside the primary blue one, and carries only the
`fa-file-import` icon plus the `actions.import` label.

It is **not** feature-gated — no flag hides it. The only conditional control in that
header is the **Agent Hub** link, which renders solely when the agent hub URL is set.
So a missing import control means a stale page, not a disabled feature; reload after
enabling the pool.

There is also a second copy inside the zero-agents empty state, and there the CSS
class is misplaced — `agents-import-input` sits on the `<input>` rather than the
`<label>`, while the rule is:

```css
.agents-import-input input[type=file] { display: none }
```

The selector needs the class on an *ancestor*, so in the empty state it does not
match and the raw native file picker renders instead of a styled button. With zero
agents, what you see does not look like an import button at all.

Import mode cannot be deep-linked. `/app/agents/new` shows "Create Agent"; the
"Import Agent" title appears only when router navigation state carries
`importedConfig`, which is set by that file input's `onChange`. There is no URL for it.

## Deleting a collection reports success and does nothing

```text
DELETE /api/agents/collections?name=pattern-a-probe  ->  200 {"status":"ok"}
GET    /api/agents/collections                       ->  still listed
GET    /api/agents/collections/pattern-a-probe/entries -> {"count":1,...}
POST   .../search                                    ->  returns the content
```

Repeated twice, with the document still retrievable afterwards. Agent deletion
(`DELETE /api/agents/{name}`) does work; **collection deletion is a silent no-op.**

Treat this as a data-retention problem, not a tidiness one: if you delete a
collection because it holds sensitive or poisoned content, it is still there and
still searchable, and the API told you it was gone.

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
