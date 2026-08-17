# 005 — The memory model

**Question:** what does "memory" mean in this stack, and where does each kind live?

**Answer:** the word covers at least five distinct things with three different lifetimes. Two of
them share one physical store. The prompt the model sees calls the knowledge base "memory",
which is where most of the confusion originates.

The reader-facing version is
[memory vs knowledge](../docs/07-deep-dives/memory-vs-knowledge.md). This note records how the
picture was assembled.

## The five things

| Concept | Owner | Physical location | Lifetime |
|---|---|---|---|
| **LLM context** | assembled per request | the request body | one model call |
| **Conversation history** | LocalAGI `ConversationTracker` | **process memory, TTL'd** | ≤ 1 hour, lost on restart |
| **Agent definition** | LocalAGI pool | `<stateDir>` JSON | until deleted |
| **Agent memory** | LocalRecall collection | vector store | until reset |
| **Knowledge** | LocalRecall collection | **the same** vector store | until reset |

The fourth and fifth rows are the finding. They are not two systems.

## Agent memory is a document

`webui/collections/rag_provider.go:29-52`. When long-term memory writes something, it:

1. Writes the text to a temp file named `<yyyy-mm-dd-HH-MM-SS>-<md5-of-content>.txt`
2. Calls `kb.Store(f, meta)` — **the ordinary ingestion path**
3. Removes the temp directory

So a memory goes through the same chunker, the same embedding calls and the same vector store as
an uploaded PDF. It is distinguishable only by the shape of its generated filename.

Consequences, all of which follow mechanically:

| Consequence |
|---|
| `POST /api/collections/<agent>/reset` deletes the agent's memories along with the knowledge |
| Anything that can write the collection can write the agent's memory |
| `add_to_memory` / `remove_from_memory` are **tools the model can call** — an agent can rewrite its own memory |
| There is no separate memory scope, quota or retention policy |
| Memory competes with knowledge for the same top-*k* slots |

That last one is under-appreciated: with `kb_results: 3`, three retrieved chunks might all be
old conversation fragments rather than the document you ingested.

## The prompt itself conflates them

`core/agent/knowledgebase.go:94-101` builds the injected context as:

```go
systemMessage := openai.ChatCompletionMessage{
    Role:    "system",
    Content: fmt.Sprintf("Given the user input you have the following in memory:\n%s", formatResults),
}
conv = append([]openai.ChatCompletionMessage{systemMessage}, conv...)
```

Observed in a live agent's log, with a document that had just been uploaded:

```text
Given the user input you have the following in memory:
- The Zeppelin-7 telemetry bus uses a heartbeat interval of 4200 milliseconds. …
  (map[created_at:2026-08-17T15:42:42Z file_name:kb-fact.txt source:e040fb16-…/kb-fact.txt
   title:e040fb16-…/kb-fact.txt type:file])
```

**The model is told an ingested document is "in memory".** It has no way to distinguish
retrieved knowledge from recalled conversation, because nothing in the prompt marks the
difference.

Three further observations from that one log line:

- It is a **system message**, prepended to the front — instruction-adjacent authority, not a
  labelled document block.
- `fmt.Sprintf("%s (%+v)")` means **Go map syntax reaches the model**. `map[created_at:…]` is
  literally in the context window.
- There is no similarity score and no threshold, so relevance is not represented at all.

## Conversation history is the odd one out

The only one of the five that is never persisted. `core/conversations`:

- an in-memory `map[K][]openai.ChatCompletionMessage`
- keyed by response ID, with a last-message timestamp
- expiry returns an **empty conversation**, not an error
- fallback duration **1 hour** if `LOCALAGI_CONVERSATION_DURATION` is unset or unparseable
- other expired conversations are garbage-collected opportunistically on each read

Verified: an unknown `previous_response_id` returns 200 with no history and no warning. So
"expired", "never existed" and "valid but new" are indistinguishable.

`LOCALAGI_ENABLE_CONVERSATIONS_LOGGING=true` writes each turn to
`<stateDir>/conversations/<agent>-<timestamp>.json` — but nothing reads it back. It is an
**audit log, not state**. Worth being precise about, because its existence suggests durability
it does not provide.

## What we got wrong initially

Two corrections worth recording.

**We expected a memory subsystem.** The terminology, the `add_to_memory` action and the
`long_term_memory` flag all suggest one. There is none: there is a collection, and two ways to
write to it. Looking for a memory store and not finding one is the normal experience.

**We expected retrieval to be labelled.** The assumption was that retrieved chunks would arrive
as a distinct message type or with provenance. They arrive as one system message with a
stringified Go map. This matters for
[the security model](../docs/07-deep-dives/security-model.md): whatever is in the collection
speaks with instruction authority.

## The ownership table, verified

The table `docs/` refers back to. Every row checked against source, and the starred rows
observed at runtime.

| Concept | Owner | Location |
|---|---|---|
| LLM context | caller or agent loop | request body only |
| Conversation history | LocalAGI tracker | process memory, TTL'd |
| Agent definition | LocalAGI pool | `<stateDir>` JSON ★ |
| Agent runtime status | LocalAGI, memory | last 10 action results ★ |
| Agent memory | LocalRecall collection | vector store |
| Knowledge | LocalRecall collection | **same** vector store ★ |
| Original documents | LocalRecall assets | `FILE_ASSETS/<collection>/<uuid>/` ★ |
| **Embedding generation** | **LocalAI** | — ★ |
| Vector persistence | LocalRecall engine | chromem file / PostgreSQL ★ |

The two rows most often stated wrongly elsewhere: **LocalRecall does not generate embeddings**,
and **conversation history is not persisted**.

## Retrieval is not memory-aware

Two properties that make multi-turn retrieval worse than expected:

**The query is the latest user message, verbatim** (`knowledgebase.go:44`). No rewriting, no
history-aware condensation. A follow-up like "and the minimum?" is embedded literally.

**Retrieval runs once per request, before the loop.** Verified: two model calls, one search. So
an agent that discovers mid-loop that it needs different knowledge cannot go back for it —
unless `kb_as_tools` is enabled, which makes retrieval a tool the model may choose to call.

## Open questions

1. What does `enable_kb_compaction` / `kb_compaction_summarize` actually do to stored memories?
   The `KBCompactionClient` interface exists and we did not exercise it.
2. Is there any way to scope memory separately from knowledge? We found none.
3. Does `summary_long_term_memory` summarise before writing, and if so with which model? Not
   traced.
4. With `kb_results: 3`, is there any ordering preference between memory entries and ingested
   documents? Presumably pure similarity, but not verified.

## References

- `LocalAGI/webui/collections/rag_provider.go:29-52` — memory written as a timestamped, hashed
  temp file through `Store`; `:64-80` — `fmt.Sprintf("%s (%+v)")`; `:160` — collection name as
  the lowercased agent name
- `LocalAGI/core/agent/knowledgebase.go:19-31` — the three guards, DEBUG only; `:44` — verbatim
  query; `:94-101` — the "in memory" system message; `:113-124` — conversation logging
- `LocalAGI/core/conversations/` — the in-memory tracker and TTL semantics
- `LocalAGI/webui/options.go:42-50` — the 1 hour fallback
- `LocalAGI/core/state/config.go` — `long_term_memory`, `summary_long_term_memory`,
  `enable_kb_compaction`, `kb_compaction_summarize`, `kb_as_tools`, `kb_results`
- `LocalAGI/core/state/compaction.go` — `KBCompactionClient`
- `LocalRecall/rag/persistency.go` — the shared ingestion path
- Log excerpts, the retrieval trace and the model-call counts: observed 2026-08-17,
  [006](006-validation-log.md)
