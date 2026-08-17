# Glossary

Short definitions with **ownership** — which component is responsible for each concept. The
longer treatment of the overloaded terms is in
[terminology](../00-overview/terminology.md); this page is the quick lookup.

Where a term means something specific in this ecosystem that differs from general usage, that is
noted.

## A–C

**Action** — a tool implemented inside LocalAGI, executing **in-process**. A stock LocalAGI
reports **40**. Not MCP. *Owner: LocalAGI.*

**Agent** — a named configuration that can execute a reason/act/observe loop: a model, a system
prompt, tools, and optional knowledge. Persisted as JSON. *Owner: LocalAGI.*

**Agent loop** — the reason/act/observe cycle. **Not LocalAGI's code** — it lives in
[`mudler/cogito`](https://github.com/mudler/cogito), which both LocalAGI and LocalAI link.
*Owner: cogito.*

**Agent memory** — conversation content written back into the agent's **collection** as a
document. Not a separate subsystem; the same store as knowledge. *Owner: LocalRecall, written by
LocalAGI.*

**Agent state** — an agent's definition and status. The definition is JSON on disk; the status is
in memory. *Owner: LocalAGI.*

**Backend** — the engine that actually executes a model: llama.cpp, vLLM, whisper.cpp, MLX and
others. A **separate OS process** that LocalAI starts and speaks gRPC to. Downloaded as an OCI
artifact, not compiled in. *Owner: LocalAI.*

**BM25** — a lexical relevance function. In this stack it is available **only** in LocalRecall's
PostgreSQL engine, and requires the `pg_textsearch` extension. Good at exact identifiers, which
embeddings match poorly. *Owner: LocalRecall + PostgreSQL.*

**Chunk** — a fragment of a document, sized in **characters** (default 400), with optional
overlap. The unit that gets embedded and retrieved. *Owner: LocalRecall.*

**Chat Completions** — the OpenAI-compatible inference endpoint. **One model call.** *Owner:
LocalAI.*

**cogito** — the Go library implementing the agent loop, tool selection, forced reasoning, loop
detection and compaction. The fourth project, named in neither README prominently. *Owner: its
own repository.*

**Collection** — a named set of documents, chunks and vectors. For an agent, the name is
**derived from the lowercased agent name** and is not configurable. *Owner: LocalRecall.*

**Connector** — an integration that lets an external system trigger an agent: Slack, Discord,
Telegram, IRC, GitHub, email. A stock LocalAGI reports **9**. Attaching one means outsiders can
invoke the agent. *Owner: LocalAGI.*

**Context / context window** — the tokens a model sees in one call. Assembled per request from
the system prompt, conversation history, retrieved chunks and tool results. **Stored nowhere.**
*Owner: the caller or the agent loop.*

**Conversation history** — prior turns, held in an **in-memory map with a TTL** (1 hour
fallback), keyed by response ID. **Never persisted.** Expiry returns an empty conversation rather
than an error. *Owner: LocalAGI.*

## D–K

**Dimension** — the length of an embedding vector; a property of the model, not a parameter. 384
for the reference model. Fixed for the life of a collection. *Owner: the embedding model.*

**Document** — an ingested file. Stored **twice**: the original under `FILE_ASSETS`, and its
chunks in the vector store. *Owner: LocalRecall.*

**Embedding** — a vector representation of text. **LocalRecall does not compute embeddings** — it
calls an OpenAI-compatible `/v1/embeddings`. *Owner: LocalAI (or any compatible endpoint).*

**Function calling** — the model emitting a structured request to invoke a named tool. cogito
constrains tool **names** to a schema `enum`; **arguments are generated text**. *Owner: the model
+ cogito.*

**Gallery** — the catalogue LocalAI installs models and backends from. The **model** gallery is
YAML on `raw.githubusercontent.com`; the **backend** gallery is a container registry. They fail
independently. *Owner: LocalAI.*

**Hybrid search** — vector similarity combined with BM25 lexical scoring, with tunable weights.
PostgreSQL engine only. *Owner: LocalRecall.*

**Inference** — executing a model to produce output. *Owner: LocalAI.*

**Knowledge** — persisted information retrievable into model context. Physically the same store
as agent memory. *Owner: LocalRecall.*

**Knowledge base** — a collection used by an agent. Enabled per agent with `enable_kb`; **off by
default**, and failures log at DEBUG only. *Owner: LocalRecall, consumed by LocalAGI.*

## L–R

**LocalAGI** — the agent platform: definitions, persistence, HTTP API, web UI, scheduling,
connectors, tools, MCP wiring. **Not** the agent loop. Runs as a service or as a library inside
LocalAI.

**LocalAI** — the model runtime: inference, embeddings, audio, image, multimodal; backend
abstraction; model and backend acquisition; OpenAI-compatible APIs. A **leaf** in this
architecture — it calls nothing except its backends.

**LocalRecall** — the knowledge layer: ingestion, chunking, embedding coordination, vector
persistence, retrieval. **Not a database and not an embedder.**

**MCP (Model Context Protocol)** — a protocol for exposing tools to a model over stdio or HTTP.
A **transport and discovery** mechanism, **not** a decision-maker and **not** a permission
model. *Owner: external servers; LocalAGI is the client.*

**Model** — the neural network being executed. Qwen3, Gemma, Llama. Distinct from the **backend**
that runs it. *Owner: LocalAI.*

**Model server** — a process exposing models over HTTP. LocalAI is one; so is vLLM, so is OpenAI.
Substitutable, given OpenAI compatibility.

**pgvector / pgvectorscale** — PostgreSQL extensions for vector storage and indexing. Present in
LocalRecall's own PostgreSQL image alongside `pg_textsearch`. *Owner: PostgreSQL.*

**RAG (retrieval-augmented generation)** — retrieving relevant text and placing it in the model's
context. Here: retrieved chunks are formatted into **one system message** and prepended to the
conversation. *Owner: LocalRecall retrieves; LocalAGI assembles.*

**Reasoning** — model output about how to proceed, separate from the answer. `qwen3` emits
`<think>` blocks; `strip_thinking_tags` removes them. With forced reasoning, cogito requests
schema-validated reasoning as its own model call. *Owner: the model + cogito.*

**Responses API** — the agent entry point, `POST /v1/responses`. **`model` carries the agent
name.** Streaming is accepted and ignored; `usage` is always zero. *Owner: LocalAGI (and
LocalAI's agent pool).*

**Retrieval** — finding relevant chunks for a query. One embedding call plus one store query.
Measured at **29–37 ms**. Runs **once per request**, before the loop. *Owner: LocalRecall.*

## S–V

**Semantic search** — retrieval by vector similarity rather than keyword match. Note that
unrelated text still scores ~0.54 here, and **there is no relevance threshold** — top-*k* always
returns *k*. The response carries a `Similarity` field, observed as `0`. *Owner: LocalRecall.*

**Skill** — a packaged capability with front matter and resources, loadable by an agent.
*Owner: LocalAGI.*

**State** — ambiguous in this ecosystem; always qualify it. See **agent state**, **conversation
history**, **knowledge**, **agent memory** — four different things with three different
lifetimes.

**Tool** — anything an agent can invoke: a built-in action, an MCP tool, or a user-defined
function the client executes. The model chooses **which** and with **what arguments**; there is
no approval step. *Owner: varies.*

**Vector** — an array of floats representing text. 384 float32 values (~1.5 kB) for the reference
model, L2-normalized, so cosine similarity is a plain dot product. *Owner: produced by LocalAI,
stored by LocalRecall.*

**Vector engine** — LocalRecall's storage backend: `chromem` (a file), `postgres` (a database), or
`localai` (LocalAI's `/stores` API, partially implemented). *Owner: LocalRecall.*

**Vector store / vector database** — where vectors are persisted. **Not** LocalRecall itself,
which has no storage of its own. *Owner: the selected engine.*

## Terms that mislead

Collected because each one has cost someone an afternoon.

| Term | The misleading reading | What is true |
|---|---|---|
| "memory" | a distinct memory subsystem | a collection, written two ways; the **prompt itself** calls knowledge "memory" |
| `model` on `/v1/responses` | a model name | an **agent** name |
| "LocalRecall" | a vector database | ingestion and retrieval; it stores nothing and embeds nothing |
| "LocalAGI" | owner of the agent loop | the loop is **cogito** |
| "embedded" | no network calls | retrieval becomes in-process; **embedding stays HTTP** |
| `/readyz` returning 200 | ready to serve | the **listener** is up; there may be zero models |
| `bert-embeddings` | a BERT model | Llama-3.2-1B-Instruct with `embeddings: true` |
| `stream: true` on `/v1/responses` | streaming | accepted and **silently ignored** |
| `usage` in a Responses reply | token counts | hardcoded zeros |
| `LOCALAGI_TIMEOUT` | request timeout | **per model call**; a request is a loop |
| `max_results` omitted | a sensible default | **5** if ≥5 documents, else **1** |
| `update_interval: 0` on a source | never poll | **60 minutes** |
| MCP | a permission boundary | a transport; it has no permission model |
| "three services" | three processes | one to four, depending on configuration |

## Upstream references

- [LocalAGI `core/state/config.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/state/config.go) — agent, action, MCP and knowledge terminology. Validated against v2.9.0.
- [LocalAGI `core/agent/knowledgebase.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/agent/knowledgebase.go) — the "in memory" system message that conflates the terms.
- [LocalAGI `webui/collections/rag_provider.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/collections/rag_provider.go) — collection naming; memory as a document.
- [LocalRecall `rag/engine.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/engine.go) — the vector-engine contract. Validated against v0.6.4.
- [LocalRecall `pkg/chunk/chunking.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/pkg/chunk/chunking.go) — chunk semantics.
- [LocalAI `pkg/model/initializers.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/pkg/model/initializers.go) — model versus backend. Validated against v4.8.2.
- [`mudler/cogito`](https://github.com/mudler/cogito) — the agent loop.
- Action and connector counts, dimensions, similarity scores, retrieval latency and the default behaviours listed above: observed 2026-08-17, see [version matrix](../00-overview/version-matrix.md).
