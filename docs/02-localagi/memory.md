# The three memories

"Memory" names three unrelated subsystems in LocalAGI. They have different
storage, different lifetimes, different write paths and — in one case —
identically named tools. Sorting them out is the difference between "the agent
forgot" being a bug report and a configuration question.

| | (a) Internal state memories | (b) Knowledge base | (c) `memory` actions |
|---|---|---|---|
| Storage | `<name>.state.json` | LocalRecall collection (chromem / postgres / LocalAI stores) | A Bleve full-text index on local disk |
| Written by | The model, via `update_state` | Automatic conversation write-back, or the `add_memory` tool | The `add_to_memory` tool |
| Read by | Prompt injection (HUD) | Similarity search before the loop, or the `search_memory` tool | The `list_memory` / `search_memory` tools, and a dynamic prompt |
| Enabled by | `hud` | `enable_kb` | Adding the actions to the agent |
| Retrieval | none — always injected in full | vector similarity | full-text query |
| Survives restart | yes | yes | yes |
| Related to the other two | no | no | no |

Only (b) is what the handbook and the wider ecosystem mean by "long-term
memory". The deep dive is
[memory versus knowledge](../07-deep-dives/memory-vs-knowledge.md).

## (a) LLM-authored state memories

`AgentInternalState.Memories` is a list of strings the model writes by calling
`update_state`, whose schema also carries `goal`, `now_doing`, `doing_next` and
`done_history` and marks **nothing as required**
(`core/action/state.go:26-57`).

The write path is LocalAGI's tool callback: it unmarshals the arguments into a
`types.AgentInternalState`, replaces the agent's current state and persists the
file (`core/agent/agent.go:1236-1284`).

The read path is the HUD template
(`core/agent/templates.go:99-105`), which renders `Short-term Memory:` followed
by every entry, along with the character block and the permanent goal.

Three consequences:

- **`update_state` only exists when `hud` is enabled**
  (`core/agent/actions.go:154-155,166-167,172-174`). Without the HUD there is no
  tool, no file, and nothing to inspect.
- There is no retrieval. Every memory is in the prompt on every call, so the
  list grows the context linearly and nothing prunes it.
- The content is whatever the model decided to write. It is not derived from the
  conversation by any deterministic rule.

## (b) The knowledge base — this is "long-term memory"

Attached per agent when `enable_kb` is set, as **one collection named after the
agent** (`core/state/pool.go:556`). The backing store is LocalRecall, linked
in-process by default; setting `LOCALAGI_LOCALRAG_URL` switches to a remote
LocalRecall over HTTP (`cmd/serve.go:113-120`).

The interface between them is four methods (`core/agent/agent.go:84-89`):

```go
type RAGDB interface {
    Store(s string) error
    Reset() error
    Search(s string, similarEntries int) ([]string, error)
    Count() int
}
```

### Reading

**Automatic recall** (`core/agent/knowledgebase.go:17-111`) runs before the loop
when `enable_kb` and `kb_auto_search` are both on. It searches with the latest
user message, takes `kb_results` chunks (default 5) and prepends them as a system
message beginning *"Given the user input you have the following in memory"*.

**Tool recall** (`kb_as_tools`) adds two tools instead
(`core/agent/knowledgebase.go:200-303`):

| Tool | Argument | Effect |
|---|---|---|
| `search_memory` | `query` | Similarity search over the collection |
| `add_memory` | `content` | Writes a new entry into the collection |

There is no `search_knowledge_base` tool. The knowledge base is addressed as
"memory" throughout the model-facing surface, which is where most of the
confusion originates.

**A default worth knowing:** if neither `kb_auto_search` nor `kb_as_tools` is
set, the pool forces auto-search on (`core/state/pool.go:563-567`) for backwards
compatibility. An agent with `enable_kb: true` and nothing else searches on every
message.

### Writing

`saveCurrentConversation` (`core/agent/knowledgebase.go:126-183`) runs as a job
finalizer and writes back only when `long_term_memory` or
`summary_long_term_memory` is set:

| Mode | What is stored |
|---|---|
| `summary_long_term_memory` | One LLM-generated summary of the turn — *"Summarize the conversation below, keep the highlights as a bullet list"* |
| `conversation_storage_mode: user_only` (default) | Only the user messages |
| `conversation_storage_mode: user_and_assistant` | Each user and assistant message as a separate entry |
| `conversation_storage_mode: whole_conversation` | The flattened transcript as one blob |

The summary path calls the LLM directly through cogito's `Ask`, not through the
tool loop.

The important architectural consequence, stated plainly: **an agent with
long-term memory writes its conversations into the same collection it searches
for documents.** Same index, same embedding model, same query. Curated knowledge
and chat history compete for the same `kb_results` slots.

### Compaction

With `enable_kb_compaction`, a goroutine per agent
(`core/state/pool.go:682-684`) runs `RunCompaction`
(`core/state/compaction.go:133-210`) immediately at startup and then every 24
hours, 7 days or 30 days depending on `kb_compaction_interval`.

It groups entries by a leading `YYYY-MM-DD` in the filename into daily, ISO-week
or monthly buckets, concatenates each group, optionally summarises it with a
plain chat completion, stores the result as `summary-<key>.txt` and **deletes the
originals**. Entries already named `summary-…` are skipped, so the process is
idempotent across runs but not reversible.

Compaction is lossy by design. On a collection holding both uploaded documents
and conversation write-back, it summarises both together.

## (c) The `memory` action pack — Bleve, and unrelated to everything above

Four actions backed by a Bleve full-text index
(`services/actions/memory.go`), storing
`MemoryEntry{ID, Name, Content, CreatedAt}`:

| Registry key | Default tool name | Argument |
|---|---|---|
| `add_to_memory` | `add_to_memory` | `name`, `content` |
| `list_memory` | `list_memory` | — |
| `remove_from_memory` | `remove_from_memory` | `id` |
| `search_memory` | `search_memory` | `query` |

No vectors, no embeddings, no LocalRecall — a text index on disk. There is a
module-level index cache guarded by a mutex, because opening the same Bleve path
twice deadlocks on its file lock (`services/actions/memory.go:18-23`).

A matching **dynamic prompt** (`DynamicPromptMemory`) injects the listing from
`list_memory` into the agent's prompt (`services/prompts.go:139-144`), which is
the closest thing in the codebase to (a) built out of (c).

### The name collision

`search_memory` exists twice:

- `core/agent/knowledgebase.go:252` — vector search over the LocalRecall
  collection, added by `kb_as_tools`.
- `services/actions/memory.go:361` — full-text search over the Bleve index,
  added by the `search_memory` registry key.

Enabling both gives one agent two identically named tools backed by different
stores. Whether cogito's tool resolution picks the first, the last, or errors is
**not established** — it depends on `tools.Find` semantics in the pinned cogito,
which was not traced. The safe move is to rename the Bleve one via
`custom_name`, which all four memory actions support.

## Choosing

| You want | Use |
|---|---|
| The agent to recall uploaded documents | `enable_kb` with `kb_auto_search` |
| The agent to decide when to look things up | `enable_kb` with `kb_as_tools` |
| The agent to remember past conversations | `long_term_memory` — and accept that it pollutes the document index |
| Compact, model-curated notes about a task in progress | `hud` — accepting they are always in the prompt |
| Exact-match recall of user-supplied facts, keyword-style | the `memory` actions (Bleve) |

## Upstream references

- [`core/agent/knowledgebase.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/agent/knowledgebase.go) — automatic recall, `search_memory` / `add_memory`, write-back modes. Validated against v2.9.0, 2026-08-17.
- [`core/agent/agent.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/agent/agent.go) — the `RAGDB` interface, the `update_state` write path. Validated against v2.9.0, 2026-08-17.
- [`core/action/state.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/action/state.go) — the `memories` property of `update_state`. Validated against v2.9.0, 2026-08-17.
- [`core/agent/templates.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/agent/templates.go) — the HUD template rendering short-term memory. Validated against v2.9.0, 2026-08-17.
- [`core/state/compaction.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/state/compaction.go) — bucketing, summarisation, deletion of originals. Validated against v2.9.0, 2026-08-17.
- [`core/state/pool.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/state/pool.go) — collection naming, the forced auto-search default, compaction ticker. Validated against v2.9.0, 2026-08-17.
- [`services/actions/memory.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/services/actions/memory.go) — the Bleve actions and the index cache. Validated against v2.9.0, 2026-08-17.
- [`webui/collections/rag_provider.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/collections/rag_provider.go) — the in-process LocalRecall adapter. Validated against v2.9.0, 2026-08-17.
