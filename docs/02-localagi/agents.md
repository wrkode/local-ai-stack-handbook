# Defining an agent

An agent is one entry in `pool.json`: a `state.AgentConfig` value keyed by name.
The web form, the import/export files and the REST API all produce the same
struct (`core/state/config.go:55-117`). Nothing about an agent exists outside it
except its runtime state, which the agent writes itself
(see [state](state.md)).

## The configuration schema

### Identity and models

| JSON key | Type | Notes |
|---|---|---|
| `name` | string | Also the filename stem and the knowledge-collection name |
| `description` | string | Shown to *other* agents in the `call_agent` tool description |
| `model` | string | Overrides `LOCALAGI_MODEL` for this agent |
| `multimodal_model` | string | Used to describe images before reasoning |
| `transcription_model`, `transcription_language` | string | Audio input |
| `tts_model` | string | Audio output |
| `api_url`, `api_key` | string | Overrides the pool's model server — read the trap below |
| `local_rag_url`, `local_rag_api_key` | string | Per-agent remote LocalRecall |
| `random_identity` | bool | Generate a `Character` with the LLM at construction |
| `identity_guidance` | string | Steers that generation |
| `last_message_duration` | string | Connector-level conversation window |

### Sub-configurations

Each is a list of `{type-or-name, config}` pairs where `config` is itself a JSON
**string**, parsed by the individual action or connector:

| JSON key | Element shape | Registry |
|---|---|---|
| `actions` | `{name, config}` | [tools](tools.md) |
| `connectors` | `{type, config}` | Slack, Telegram, Discord, IRC, Matrix, email, GitHub issues/PRs, Twitter |
| `dynamic_prompts` | `{type, config}` | `custom` (yaegi) or `memory` (Bleve listing) |
| `filters` | `{type, config}` | `regex` or `classifier` |
| `mcp_servers` | `{url, token}` | [MCP](mcp.md) |
| `mcp_stdio_servers` | `{name, cmd, args[], env[]}` **or** a Claude-Desktop-style JSON string | [MCP](mcp.md) |
| `mcp_prepare_script` | string | `/bin/bash -c` run before stdio servers start |

### Behaviour flags and tuning

Defaults below are the ones the UI form declares (`core/state/config.go`), which
is what a form-created agent gets. An agent created by POSTing raw JSON gets Go
zero values for anything it omits — the two are not the same.

| JSON key | Type | UI default | Effect |
|---|---|---|---|
| `hud` | bool | false | Injects the character/state block, and enables the `update_state` tool |
| `system_prompt` | string | "" | Prepended as a system message |
| `permanent_goal` | string | "" | Rendered into the HUD |
| `standalone_job` | bool | false | **Required for periodic autonomous runs to happen at all** |
| `periodic_runs` | string | "" → `10m` | Inner-monologue interval |
| `inner_monologue_template` | string | "" | Overrides the periodic prompt |
| `initiate_conversations` | bool | false | Allows `send_message` during self-evaluation |
| `can_stop_itself` | bool | false | Adds the `stop` tool |
| `enable_planning` | bool | false | cogito `EnableAutoPlan` |
| `plan_reviewer_model` | string | "" | A second model for plan review |
| `enable_evaluation` | bool | false | cogito plan re-evaluation |
| `max_evaluation_loops` | int | **2** | The iteration cap — see [agent loop](agent-loop.md) |
| `max_attempts` | int | 1 | Retries per tool call |
| `loop_detection` | int | 5 | Repeat-window size; 0 disables |
| `enable_reasoning` | bool | false | cogito `WithForceReasoning` |
| `enable_reasoning_tool` | bool | **true** | cogito `WithForceReasoningTool` |
| `enable_guided_tools` | bool | false | cogito `EnableGuidedTools` |
| `disable_sink_state` | bool | false | Removes the `no_tool_to_call` escape hatch |
| `strip_thinking_tags` | bool | false | Strips `<think>` blocks from the final answer |
| `enable_auto_compaction` | bool | false | cogito context compaction |
| `auto_compaction_threshold` | int | 4096 | Tokens |
| `parallel_jobs` | int | **5** | Worker goroutines per agent |
| `cancel_previous_on_new_message` | *bool | true | Cancels the in-flight job for the same conversation |
| `enable_kb` | bool | false | Attach a knowledge collection |
| `kb_results` | int | 5 | Chunks recalled per query |
| `kb_auto_search` | bool | true | Recall on every user message |
| `kb_as_tools` | bool | false | Expose `search_memory` / `add_memory` |
| `long_term_memory` | bool | false | Write conversations back into the collection |
| `summary_long_term_memory` | bool | false | Write an LLM summary instead |
| `conversation_storage_mode` | string | `user_only` | `user_only`, `user_and_assistant`, `whole_conversation` |
| `enable_kb_compaction` | bool | false | Periodic merge of old entries |
| `kb_compaction_interval` | string | `daily` | `daily`, `weekly`, `monthly` |
| `kb_compaction_summarize` | bool | true | Summarise while compacting |
| `enable_skills` | bool | false | Attach the skills MCP session and prompt |
| `skills_prompt` | string | "" | Overrides the skills prompt |
| `scheduler_poll_interval` | string | `30s` | Task scheduler tick |
| `scheduler_task_template` | string | "" | Overrides the scheduled-task wrapper prompt |

Five integer fields — `max_evaluation_loops`, `max_attempts`, `parallel_jobs`,
`kb_results`, `loop_detection` — are decoded through `parseIntField`, which
accepts an `int`, a `float64` or a numeric **string**, because the form-encoded
UI sends strings (`core/state/config.go:14-27, 610-614`).

`loop_detection` is the exception that only looks like it works.
`a.LoopDetection = parseIntField(aux.LoopDetection)` reads a field that is not
declared as an `interface{}` shadow in the `aux` struct
(`core/state/config.go:594-601`), so it resolves to the already-decoded `int` and
`parseIntField` returns it unchanged. Sending `"loop_detection": "5"` as a
string would fail to decode where the other four succeed. **Not established at
runtime**; the asymmetry is plain in the source.

## Agent CRUD

| Method | Path | Handler |
|---|---|---|
| `GET` | `/api/agents` | list with counts and statuses |
| `POST` | `/api/agent/create` | `(*App).Create` |
| `GET` | `/api/agent/:name` | `{"active": !paused}` |
| `GET` | `/api/agent/:name/config` | the `AgentConfig` |
| `PUT` | `/api/agent/:name/config` | update — **stops and recreates the agent** |
| `DELETE` | `/api/agent/:name` | remove |
| `PUT` | `/api/agent/:name/pause` | pause; queued jobs are rejected |
| `PUT` | `/api/agent/:name/start` | resume |
| `GET` | `/api/agent/:name/status` | rolling window of the last ~10 action results |
| `GET`/`DELETE` | `/api/agent/:name/observables` | the 500-entry observation ring |
| `GET` | `/api/meta/agent/config` | field metadata that drives the UI form |
| `GET` | `/settings/export/:name` | download the agent JSON |
| `POST` | `/settings/import` | multipart upload of the same |

`GET /api/agent/config/metadata` is a second registration of the same handler as
`/api/meta/agent/config` (`webui/routes.go:90,93`). Only the latter is in the
README.

Updating a config calls `pool.RecreateAgent` (`webui/app.go:197`), which stops
the running agent and rebuilds it. That is also the only way to refresh an
agent's MCP tool list — see [MCP](mcp.md).

Agent names are sanitised before being used as filenames: `/` and space become
`_` (`core/state/pool.go:192-195`). That call happens in `CreateAgent`
(`core/state/pool.go:211`) but **not** in `RecreateAgent`
(`core/state/pool.go:224`) or `StartAgentStandalone`
(`core/state/pool.go:199`). A name containing a slash therefore behaves
differently depending on which path created the agent.

## Two agent groups

`POST /api/agent/group/generateProfiles` asks the LLM to invent a set of agent
profiles from a description; `POST /api/agent/group/create` instantiates them
together (`webui/app.go:700,750`). Both are ordinary `AgentConfig` writers —
there is no group abstraction at runtime, just several agents created at once.

## Per-agent model overrides, and what they do not cover

`startAgentWithConfig` resolves every model and endpoint field as *agent config
if set, else pool default*, and writes the resolved value back into the stored
config when the agent had none (`core/state/pool.go:302-349`). Setting
`api_url` on one agent therefore points its reasoning traffic at a different
server than the rest of the pool.

Three things do **not** follow it:

**1. Embeddings do not follow `api_url`.** The in-process knowledge backend
builds one OpenAI client at process start, from the pool-wide
`LOCALAGI_LLM_API_URL`, and hands it to every collection
(`webui/collections/inprocess.go:263-265`). Per-agent `api_url` is only passed
to `WithLLMAPIURL` (`core/state/pool.go:401`). So an agent pointed at a hosted
provider reasons against that provider while its collection is still embedded by
whatever the process was started with. If the two use different embedding
models, retrieval quality degrades without an error anywhere.

**2. LocalAI's embedded agents behave differently, and worse.** LocalAI's native
executor derives its knowledge endpoint from the *same* per-agent URL:

```go
// LocalAI core/services/agents/executor.go:84-92 (v4.8.2)
if cfg.APIURL != "" { effectiveURL = cfg.APIURL }
endpoint := effectiveURL + "/v1"
```

and then uses `effectiveURL` for `KBAutoSearchPrompt` and `KBStoreContent`
(`executor.go:99-100,172`), which are HTTP calls to
`/api/agents/collections/<name>/search` on that host. Point an agent at
`https://api.openai.com/v1` and those calls 404. The failure is logged as a
warning and an **empty context is returned** (`knowledge.go:109-113`) — the
agent keeps answering, with no knowledge and no error the caller can see.

**3. The URL convention differs between the two runtimes.** LocalAI's native
executor appends `/v1` to whatever you configure; LocalAGI's cogito client does
not. The same `api_url` value is therefore wrong in one of the two places. See
[troubleshooting](troubleshooting.md).

## Which tools an agent actually sees

Not everything configured. `availableActions` (`core/agent/actions.go:148-177`)
assembles the list per job:

| Condition | Adds |
|---|---|
| always | every configured action from the registry |
| `job.Metadata["type"] == "scheduled"`, or `initiate_conversations` during self-evaluation | `send_message` |
| `hud` | `update_state` |
| `can_stop_itself`, and the job is not scheduled | `stop` |
| per-job `UserTools` from a `/v1/responses` request | those tool definitions |
| `kb_as_tools` | `search_memory`, `add_memory` |
| MCP servers configured | their tools, supplied to cogito directly |

Note the branch structure: a job marked `scheduled` gets `send_message` but
**cannot** get `stop` — the `NewStop()` call in that branch is commented out
(`core/agent/actions.go:157-159`). A scheduled agent that decides it is finished
has no tool to say so; it stops by running out of iterations.

## Upstream references

- [`core/state/config.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/state/config.go) — `AgentConfig`, `UnmarshalJSON`, `NewAgentConfigMeta` and every UI default. Validated against v2.9.0, 2026-08-17.
- [`core/state/pool.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/state/pool.go) — `startAgentWithConfig` field resolution, name sanitisation, CRUD methods. Validated against v2.9.0, 2026-08-17.
- [`core/agent/actions.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/agent/actions.go) — per-job action assembly. Validated against v2.9.0, 2026-08-17.
- [`webui/routes.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/routes.go) and [`webui/app.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/app.go) — agent CRUD routes and handlers. Validated against v2.9.0, 2026-08-17.
- [`webui/collections/inprocess.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/collections/inprocess.go) — the single process-wide embedding client. Validated against v2.9.0, 2026-08-17.
- [LocalAI `core/services/agents/executor.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/services/agents/executor.go) — per-agent URL reused for knowledge calls, `/v1` appended. Validated against v4.8.2, 2026-08-17.
- [LocalAI `core/services/agents/knowledge.go`](https://github.com/mudler/LocalAI/blob/v4.8.2/core/services/agents/knowledge.go) — knowledge failure returns empty context. Validated against v4.8.2, 2026-08-17.
