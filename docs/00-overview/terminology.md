# Terminology

This ecosystem overloads words badly. "Memory" means at least five different
things depending on which page you are reading; "backend" means two. This page
fixes one definition per term and names the component that owns it.

Where a term is genuinely ambiguous upstream, that is stated rather than papered
over.

## Models and execution

### Model

The neural network being executed — weights plus the metadata describing how to
run them. Examples: Qwen, Gemma, Llama, Granite.

In LocalAI a model is also a *configuration*: a YAML file in the models directory
naming the weights file, the backend, the prompt template and default
parameters. Installing a model from the gallery writes both the weights and this
YAML.

**Owner:** LocalAI.

### Backend

**Ambiguous term. Two distinct meanings, both in active use.**

1. **LocalAI backend** — the runtime engine that executes a model: llama.cpp,
   vLLM, whisper.cpp, stable-diffusion, MLX. In LocalAI v4 these are *separate
   OS processes* that LocalAI starts and speaks gRPC to. They are installed as
   OCI artifacts from a container registry, not compiled into the binary.
   Example installed name: `cpu-llama-cpp`.

2. **LocalRecall vector backend** — the storage engine behind a collection:
   `chromem`, `postgres`, or `localai`. Selected by the `VECTOR_ENGINE`
   environment variable.

When someone says "the backend failed", ask which one.

**Owner:** LocalAI (1), LocalRecall (2).

### Model server / inference server

A process exposing models over an API. LocalAI is one. vLLM, Ollama and hosted
OpenAI endpoints are others. LocalAGI and LocalRecall are both clients of one;
neither is one.

### Inference

One forward pass through a model producing output. Stateless from the server's
perspective: the caller supplies the entire context each time.

**Owner:** LocalAI, delegated to a backend process.

### Runtime

Avoid this word unqualified — it is used upstream for both the model runtime
(LocalAI) and the agent runtime (cogito/LocalAGI). This handbook always
qualifies it.

## Agents

### Agent

A configured entity that pursues a goal by repeatedly calling a model, choosing
tools, observing results and deciding whether to continue. It has a name,
persisted configuration, and optionally its own knowledge collection, schedule
and connectors.

**Owner:** LocalAGI (the platform) — but see *agent loop*.

### Agent loop

The reason/act/observe cycle itself: ask the model what to do, execute the chosen
tool, feed the result back, repeat until the goal is met or an iteration limit is
hit.

**Owner:** [`github.com/mudler/cogito`](https://github.com/mudler/cogito), a
separate library. Both LocalAGI and LocalAI depend on it directly. This surprises
most readers: neither project implements its own agent loop.

### Reasoning

Model-generated text about what to do next, produced before a tool is selected.

In cogito this is not free text. When forced reasoning is enabled, the loop asks
the model for schema-validated JSON reasoning, then asks it to choose a tool from
a JSON-schema `enum` of real tool names, then generates that tool's arguments in
a third scoped call. This makes hallucinated tool names structurally impossible
and is why small models work at all in this stack.

### Iteration

One pass through the agent loop: one model call, optionally one tool execution.
Agents have iteration limits; hitting one is a common cause of "the agent stopped
without answering".

## Tools

### Tool

Something an agent can invoke that has an effect or returns information the model
does not have. Described to the model as a name, a description and a JSON schema
for its arguments.

### Action

LocalAGI's word for a **built-in tool compiled into the binary**, executing
in-process. A stock LocalAI v4.8.2 reports 40 of them.

"Action" and "tool" are used interchangeably upstream. In this handbook, *action*
means specifically an in-process built-in, and *tool* is the general category.

**Owner:** LocalAGI (`services/actions/`).

### Function calling

The model-level mechanism by which a model emits a structured request to invoke a
named tool. A property of the model and the API, not of the agent framework.

Function calling is *necessary* for tools but not *sufficient* for agency: it
produces a request, and something must decide whether to honour it and what to do
with the result. That something is the agent loop.

### MCP (Model Context Protocol)

A protocol for exposing tools across a process or trust boundary. Transports
include stdio (subprocess) and HTTP/SSE (remote).

Three clarifications that matter:

- **MCP is not an agent.** It carries capability, not judgement. The agent decides
  when and why a tool runs.
- **Direction matters.** An agent acting as an MCP *client* gains tools. LocalAI
  v4.8.2 also acts as an MCP *server*, exposing its own administrative surface —
  a stock container registers 36 such tools, writable by default.
- **MCP is a trust boundary.** Every MCP server given to an agent is something a
  model can invoke with arguments it chose.

### Skill

A packaged, reusable unit of agent capability following the
[skillserver](https://github.com/mudler/skillserver) format: instructions plus
resources, manageable through the UI, importable and syncable from git.

Distinct from an action: an action is compiled-in Go code; a skill is data,
created and edited at runtime.

**Owner:** LocalAGI (`services/skills/`), surfaced by LocalAI under
`/api/agents/skills`.

### Connector

An integration that lets an agent receive and send messages on an external
platform — Slack, Discord, Telegram, GitHub Issues, IRC. A stock LocalAI v4.8.2
reports 9.

A connector is an input/output channel, not a tool. It is how a request reaches
the agent, not something the agent decides to invoke.

**Owner:** LocalAGI.

## Knowledge and retrieval

### Collection

A named set of documents with their chunks and vectors — the unit of knowledge
organisation and the unit of isolation.

In agent deployments, collections are named **after the agent**. One agent, one
collection.

**Owner:** LocalRecall.

### Document / entry

One ingested file. Stored twice: the original asset on disk, and its chunks in
the vector store.

Only `.pdf`, `.txt` and `.md` are indexable. Other file types upload successfully
with `200 OK`, are listed, and are downloadable — but are never chunked, embedded
or searchable. This trap is covered in
[LocalRecall ingestion](../03-localrecall/ingestion.md).

### Chunk

A fragment of a document, sized to fit usefully in a context window and to
embed as a coherent unit.

LocalRecall's default chunk size is **400 bytes with zero overlap** — much
smaller than most RAG defaults. Chunking is byte-counted and word-aligned, and it
does not preserve paragraph structure.

**Owner:** LocalRecall (`pkg/chunk`).

### Embedding

A fixed-length vector of floats representing text such that semantically similar
text yields nearby vectors. Dimension is a property of the model.

**Generated by:** an OpenAI-compatible `/v1/embeddings` endpoint — normally
LocalAI. **Never by LocalRecall**, which has no model runtime at all.

The reference embedding model in this handbook, and the upstream default in both
LocalAI and LocalAGI, is `granite-embedding-107m-multilingual`: 384 dimensions,
returned already L2-normalized.

### Vector

The embedding, once stored. Persisted by LocalRecall's chosen engine: on-disk
gzipped files (chromem), PostgreSQL rows (postgres), or LocalAI's stores API.

### Semantic search

Retrieval by embedding the query and ranking stored chunks by vector similarity.

A caution the numbers justify: cosine values from a small embedding model are not
calibrated. Measured with the reference model, an unrelated sentence still scored
0.46 against a query that scored 0.70 against a genuinely relevant one. Only the
*ranking* is meaningful; a fixed similarity threshold will admit noise.

### Hybrid search

Combining dense vector similarity with lexical keyword matching (BM25), fusing
the two rankings.

In LocalRecall this is **real, and PostgreSQL-only**, implemented as Reciprocal
Rank Fusion. The chromem engine is dense-only. Note also that the score returned
differs by engine: chromem returns cosine similarity, the PostgreSQL hybrid path
returns an RRF score on a completely different scale. Do not compare them.

### RAG (Retrieval-Augmented Generation)

The pattern: retrieve relevant chunks, insert them into the model's context,
generate. Not a component — a technique the components implement.

### Knowledge base

The persisted, retrievable information available to an agent — in practice, its
collection.

**Owner:** LocalRecall.

## State and memory

This cluster causes the most confusion. Each of these is a **different thing**,
stored in a different place, with different lifetime. The
[memory versus knowledge](../07-deep-dives/memory-vs-knowledge.md) deep dive
covers them properly; these are the one-line definitions.

### Context / context window

The token sequence handed to the model for one inference call, and the maximum
size of it. Assembled fresh for every call by whoever is calling.

**Owner:** the caller. Not persisted by anyone.

### Conversation history

The prior turns of a dialogue.

Where this lives depends entirely on the API:

| API | Where history lives |
|---|---|
| `/v1/chat/completions` | **Nowhere.** The API is stateless; the client re-sends everything each call |
| `/v1/responses` | LocalAI, **in memory only**, with a TTL. Not on disk, not in a database |
| Agents (LocalAI) | Opt-in, and written **into the agent's knowledge collection** |
| Agents (standalone LocalAGI) | Opt-in, on disk, only if conversation logging is enabled |

The `/v1/responses` row is the one that catches people: response history does not
survive a restart.

### Agent state

An agent's persisted runtime condition — its configuration, character, scheduler
position. Written as JSON files in the agent state directory (`/data` in the
LocalAI container), or PostgreSQL rows in distributed mode.

Note that a separate, *transient* layer exists in memory with a short TTL and is
lost on restart.

**Owner:** LocalAGI's state package, stored by whichever process runs the pool.

### Short-term memory

Not a component. It means "what is in the context window right now". If someone
uses this phrase about a stored artefact, they mean conversation history.

### Long-term memory

**In this ecosystem, long-term agent memory *is* a knowledge collection.** When
an agent is configured to remember, its turns are written into the same
LocalRecall collection that holds its documents, and recalled by the same
similarity search. The `add_memory` and `search_memory` tools read and write it.

There is no separate memory subsystem in LocalRecall. The word "memory" in its
README is vocabulary, not architecture.

**One exception:** standalone LocalAGI additionally ships a `memory` *action*
backed by a Bleve full-text index on local disk — entirely separate from
LocalRecall, and not the same thing as the knowledge-base memory above.

### Knowledge versus memory

The distinction people expect — curated documents versus learned experience —
is a distinction of **intent, not of storage**. Both land in the same collection,
embedded by the same model, retrieved by the same query.

The practical consequence is a real one: an agent that writes its conversations
into its collection is polluting the same index it searches for documents.

## APIs

### Chat Completions API

`POST /v1/chat/completions`. Stateless. You send messages, you get a completion.
The client owns all history.

Use it for: direct inference, and any application that manages its own
conversation state.

**Served by:** LocalAI.

### Responses API

`POST /v1/responses`, plus `GET /v1/responses/{id}` and
`POST /v1/responses/{id}/cancel`. Server-side response storage, retrieval and
cancellation.

Both LocalAI and LocalAGI serve a Responses API. In LocalAI it is also the
**agent entry point**: a middleware inspects the `model` field, and if it names an
agent rather than a model, the request is routed into the agent runtime instead
of the inference pipeline. Same URL, entirely different execution path.

**Served by:** LocalAI and LocalAGI.

### Inference request versus agent request

- An **inference request** produces one model output. Bounded, one gRPC call to
  one backend, predictable latency.
- An **agent request** produces a *goal outcome*. It may issue many inference
  requests, retrieval queries and tool executions before returning. Latency is
  unbounded in principle and limited in practice by an iteration cap.

They can arrive at the same URL. See
[Responses versus Chat Completions](../07-deep-dives/responses-vs-chat-completions.md).

## Deployment

### Embedded / in-process

Code from one project linked into another's binary and called as a Go function.
No network hop.

Both LocalAGI-in-LocalAI and LocalRecall-in-LocalAGI are embedded by default.

### Loopback HTTP

A network call a process makes to itself. Distinct from in-process: it is a real
HTTP request, subject to authentication, visible in access logs and traces.

The embedded agent pool reaches inference this way, at `http://127.0.0.1:8080`.

### Standalone

Running a project as its own process with its own port and configuration.
Standalone LocalAGI and standalone LocalRecall both exist and are supported.

## Upstream references

- [LocalAI `core/config/model_config.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/config/model_config.go) — model configuration schema. Validated against v4.8.2.
- [LocalAI `core/http/routes/agents.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/http/routes/agents.go) — agents, skills and collections route groups.
- [LocalAGI `core/agent/knowledgebase.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/agent/knowledgebase.go) — `search_memory` / `add_memory`, conversation write-back. Validated against v2.9.0.
- [LocalAGI `services/actions/memory.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/services/actions/memory.go) — the separate Bleve-backed memory action.
- [LocalRecall `pkg/chunk/chunking.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/pkg/chunk/chunking.go) — chunk size and overlap defaults. Validated against v0.6.4.
- [LocalRecall `rag/engine/postgres.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine/postgres.go) — Reciprocal Rank Fusion hybrid search.
- [`github.com/mudler/cogito`](https://github.com/mudler/cogito) — agent loop, constrained tool selection.
- [`github.com/mudler/skillserver`](https://github.com/mudler/skillserver) — skill format.
- Embedding dimensions, normalization and similarity figures: observed 2026-08-17, see [version matrix](version-matrix.md).
