# Actions and tools

A **tool** is anything the model can invoke: a name, a description and a JSON
schema for its arguments. An **action** is LocalAGI's word for a tool implemented
in Go and compiled into the binary. Every action becomes a tool; not every tool
is an action — MCP tools and per-request user-defined tools are not.

The word to watch is *registry key*. What you write in an agent's `actions` list
is a registry key, and it is frequently **not** the name the model sees.

## What an action is, in code

```go
// core/types/actions.go:119-122
type Action interface {
    Run(ctx context.Context, sharedState *AgentSharedState, action ActionParams) (ActionResult, error)
    Definition() ActionDefinition
}
```

`ActionDefinition` (`core/types/actions.go:63-68`) carries `Name`,
`Description`, `Properties map[string]jsonschema.Definition` and `Required`.
`ToFunctionDefinition()` wraps them into an OpenAI function definition.
`ActionResult` (`:33-38`) returns `Result string`, an optional base64 image, and
`Metadata map[string]interface{}`.

The bridge to the loop is `cogitoWrapper` (`core/types/actions.go:92-116`):

```go
func (c *cogitoWrapper) Execute(args map[string]any) (string, any, error) {
    result, err := c.action.Run(ctx, c.sharedState, ActionParams(args))
    return result.Result, result, nil   // second value carries the whole ActionResult
}
```

That second return value is why action metadata survives: cogito hands it back as
`ToolStatus.ResultData`, and LocalAGI recovers it by type switch
(`core/agent/agent.go:1109-1117`). Connectors read the recovered keys —
`images_url`, `songs_paths`, `pdf_paths`, `urls`,
`telegram_message_sent` — to upload files alongside the text answer.

Native OpenAI-style `tools` / `tool_calls` are the only mechanism. LocalAGI's own
templates (`core/agent/templates.go`) still pass an `Actions []ActionDefinition`
field into templates that never reference it — dead scaffolding from an earlier
design where LocalAGI did its own tool prompting.

## The built-in registry

`services/actions.go` maps a registry key to a constructor. Below, **key** is
what goes in the agent config and **tool name** is what the model sees.

### Web and knowledge

| Key | Tool name | Required arguments | Config |
|---|---|---|---|
| `search` | `search_internet` | `query` | — (DuckDuckGo) |
| `browse` | `browse` | `url` | — (fetch + HTML to text) |
| `scraper` | `scrape` | `url` | — (full-site crawl) |
| `wikipedia` | `wikipedia` | `query` | — |

The `wikipedia` tool's `query` parameter is described to the model as *"The
website URL."* (`services/actions/wikipedia.go:45`) — a copy-paste defect that
the model reads on every call.

### GitHub — issues

All seven take `token`, `repository`, `owner` and an optional
`customActionName` as configuration. Each publishes a **narrow or wide schema**:
when `repository` and `owner` are pre-configured the tool schema omits them, so
the model has fewer arguments to get wrong.

| Key | Tool name | Arguments (narrow) |
|---|---|---|
| `github-issue-opener` | `create_github_issue` | `title`, `text` |
| `github-issue-reader` | `read_github_issue` | `issue_number` |
| `github-issue-editor` | `edit_github_issue` | `issue_number`, `title`, `description` |
| `github-issue-closer` | `close_github_issue` | `issue_number` |
| `github-issue-commenter` | `add_comment_to_github_issue` | `issue_number`, `comment` |
| `github-issue-labeler` | `add_label_to_github_issue` | `issue_number`, `label` |
| `github-issue-searcher` | `search_github_issue` | `query` |

### GitHub — pull requests

| Key | Tool name | Arguments (narrow) |
|---|---|---|
| `github-pr-reader` | `read_github_pr` | `pr_number` |
| `github-pr-commenter` | `comment_github_pr` | `pr_number`, `comment` |
| `github-pr-reviewer` | `review_github_pr` | `pr_number`, `review_comment`, `review_action`, `comments[]` |
| `github-pr-creator` | `create_github_pr` | `branch`, `title`, `body`, `files[]` |

`review_github_pr` submits APPROVE / REQUEST_CHANGES / COMMENT with inline
line comments. `create_github_pr` creates a branch, commits files and opens the
PR, optionally from a fork.

### GitHub — repository content

| Key | Tool name | Arguments (narrow) |
|---|---|---|
| `github-repository-get-content` | `get_github_repository_content` | `path` |
| `github-get-all-repository-content` | `get_all_github_repository_content` | `path` (**not marked required** on the narrow branch) |
| `github-repository-list-files` | `list_github_repository_files` | `path` |
| `github-repository-search-files` | `search_github_repository_files` | `path`, `searchPattern` |
| `github-repository-create-or-update-content` | `github_repository_create_or_update_content` | `path`, `content`, `commit_message`, plus `branch` when no default branch is configured |
| `github-readme` | `github_readme` | `repository`, `owner` (single schema, no narrow form) |

### Generation

| Key | Tool name | Arguments | Config |
|---|---|---|---|
| `generate_image` | `generate_image` | `prompt`, `size` enum | `apiKey` (required), `apiURL`, `model` |
| `generate_song` | `generate_song` | `caption`, plus `lyrics`, `bpm`, `keyscale`, `language`, `duration_seconds`, `model` | `apiURL`, `model`, `apiKey`, `outputDir`, `cleanOnStart` |
| `generate_pdf` | `generate_pdf` | `content`, plus `title`, `filename` | `outputDir` (required), `cleanOnStart` |

`generate_song` posts to LocalAI's `/sound-generation` extension, not an OpenAI
route. `generate_image`'s own description is the truncated string *"Generate
image with."*.

### Memory (Bleve full-text, not the vector store)

| Key | Default tool name | Arguments |
|---|---|---|
| `add_to_memory` | `add_to_memory` | `name`, `content` |
| `list_memory` | `list_memory` | — |
| `remove_from_memory` | `remove_from_memory` | `id` |
| `search_memory` | `search_memory` | `query` |

All four accept `custom_name` and `custom_description` config, so the model-facing
names are changeable. These write to a Bleve index and **never touch the
knowledge base** — see [memory](memory.md), which also covers the name collision
with the knowledge-base tool of the same name.

### Communication and integration

| Key | Tool name | Arguments | Config |
|---|---|---|---|
| `send-mail` | `send_email` | `to`, `subject`, `message` | `smtpHost`, `smtpPort`, `username`, `password`, `email` (all required) |
| `send-telegram-message` | `send_telegram_message` | `message` (+ `chat_id` if not preconfigured) | `token` (required), `chat_id`, name overrides |
| `twitter-post` | `post_tweet` | `text` | `token` (required), `noCharacterLimit` |
| `webhook` | `webhook` | `payload` (**no required fields declared**) | `url` (required), `method`, `contentType`, `payloadTemplate`, name overrides |
| `pikvm_power_control` | `pikvm_power_control` | `action` enum `on\|off\|off_hard\|reset_hard` | `hostname`, `username`, `password` (all required), `insecure` |

The `twitter-post` UI offers a `noCharacterLimit` toggle; the action reads
`noCharacterLimits` (plural). **The toggle does nothing**
(`services/actions/twitter_post.go:15` versus `:78`).

### Local and agent control

| Key | Tool name | Arguments | Notes |
|---|---|---|---|
| `shell-command` | `run_command` | `command` (+ `host`, `user` if not preconfigured) | Runs over SSH, either to a configured host or to the `sshbox` service |
| `call_agents` | **`call_agent`** | `agent_name` (enum of live agents), `message` | Blocking nested `Ask`; see the deadlock note in [architecture](architecture.md) |
| `counter` | `counter` | `name`, `adjustment` | A mutex-guarded in-memory map — **not persisted, lost on restart** |

`call_agent`'s definition is built at call time: it enumerates the live pool,
filters by `whitelist`/`blacklist`, excludes the calling agent, and puts the
resulting names in a JSON-schema `enum` with each agent's `description` in the
tool description.

### Scheduling

| Key | Tool name | Arguments |
|---|---|---|
| `set_recurring_reminder` | **`set_recurring_task`** | `message`, `cron_expr` (5-field cron, no seconds) |
| `set_onetime_reminder` | **`set_onetime_task`** | `message`, `delay` (accepts `1d`, `2d12h`) |
| `list_reminders` | **`list_tasks`** | — |
| `remove_reminder` | **`remove_task`** | `index` (1-based) |
| `set_reminder` | *(none — broken, see below)* | |

### Internal actions, added by the agent rather than configured

| Tool name | Added when | Source |
|---|---|---|
| `stop` | `can_stop_itself`, and the job is not scheduled | `core/action/noreply.go` |
| `send_message` | the job is scheduled, or during self-evaluation with `initiate_conversations` | `core/action/newconversation.go` |
| `update_state` | `hud` | `core/action/state.go` |
| `no_tool_to_call` | always, unless `disable_sink_state` | `core/agent/agent.go:1052-1059` |
| `search_memory`, `add_memory` | `kb_as_tools` | `core/agent/knowledgebase.go:200-206` |

## Four registry defects worth knowing before you debug

**1. `set_reminder` is advertised and cannot work.** The constant is in
`AvailableActions` (`services/actions.go:105`), so `GET /api/actions` returns it
and the UI offers it — but there is no `case` for it in the factory switch
(`:417-503`). Selecting it returns `"Action not found"` at agent construction.

**2. `set_recurring_reminder` and `set_onetime_reminder` are implemented but
unadvertised.** They exist in the factory switch (`:482-485`) and in the UI's
`DefaultActions` (`:292-301`) but not in `AvailableActions`. A client that
enumerates actions over the API will never see the two scheduling tools that
actually function.

**3. Registry keys are not tool names.** `call_agents` → `call_agent`,
`set_recurring_reminder` → `set_recurring_task`, `list_reminders` → `list_tasks`,
`remove_reminder` → `remove_task`. Anyone writing `pool.json` by hand hits this
immediately, and the `remove_task` description compounds it by telling the model
to *"use list_reminders to see the index"* — a tool name that does not exist
(`core/action/reminder.go:259`).

**4. No credential gating.** An action requiring a token declares it as a
`Required: true` config field and fails inside `Run()`. Nothing hides an
unusable action from the model, so an agent with a misconfigured GitHub action
will select it and get an error back as a tool result.

The three counts disagree with each other, which is the root of defects 1 and 2:
42 name constants, 39 entries in `AvailableActions`, 44 UI field groups, 41
factory cases (`services/actions.go:23-64, 73-114, 116-322, 417-503`).

## Custom actions: interpreted Go

`LOCALAGI_CUSTOM_ACTIONS_DIR` turns each `.go` file in a directory into an
action, executed by the [yaegi](https://github.com/traefik/yaegi) interpreter
**inside the LocalAGI process** (`core/action/custom.go`). Agent-configured
custom actions (registry key `custom`) carry their source in the config itself.

The script contract:

| Symbol | Signature | Required |
|---|---|---|
| `Run` | `func(map[string]interface{}) (string, map[string]interface{}, error)` | yes |
| `Definition` | `func() map[string][]string` — each value is `[jsonschemaType, description]` | yes |
| `Description` | `func() string` | optional; overridden by config |
| `RequiredFields` | `func() []string` | optional |
| `Init` | `func(string) error` — receives the `configuration` config value | optional |

Mechanics worth knowing:

- The interpreter is created with `Env: os.Environ()` and
  `GoPath: <customActionsDir>`, loading `stdlib.Symbols`
  (`core/action/custom.go:60-68`). Your script sees the host's environment.
- A `package` declaration in the file is stripped by regex and the code is
  re-evaluated under a generated package name (`:78-85`).
- The `Run` symbol is type-asserted **without checking**
  (`core/action/custom.go:106`). A signature mismatch panics rather than
  reporting a configuration error.
- `Definition` entries whose slice length is not 2 are skipped with a log line,
  so a malformed parameter silently disappears from the schema.

The `unsafe` config checkbox sets yaegi's `Unrestricted` mode
(`core/action/custom.go:62-67`). Combined with the unauthenticated-by-default
posture, an exposed LocalAGI accepts arbitrary Go over an HTTP API. The same
applies to `mcp_prepare_script`, which runs `/bin/bash -c` on agent construction.

Custom `.go` files in the same directory also become
[dynamic prompts](agents.md), keyed by filename, if they implement the prompt
interface.

## Running an action without an agent

```text
POST /api/action/:name/definition    → the JSON schema
POST /api/action/:name/run           → execute directly, 200-second timeout
GET  /api/actions                    → AvailableActions
```

Useful for checking credentials without waiting for a model to decide to call
something. Note the enumeration endpoint inherits defects 1 and 2 above.

## Upstream references

- [`core/types/actions.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/types/actions.go) — `Action`, `ActionDefinition`, `cogitoWrapper`, `ToCogitoTools`. Validated against v2.9.0, 2026-08-17.
- [`services/actions.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/services/actions.go) — the registry: name constants, `AvailableActions`, `DefaultActions`, the factory switch. Validated against v2.9.0, 2026-08-17.
- [`services/actions/`](https://github.com/mudler/LocalAGI/tree/v2.9.0/services/actions) — every built-in action implementation and its `Definition()`. Validated against v2.9.0, 2026-08-17.
- [`core/action/reminder.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/action/reminder.go) — the four scheduling tools and their real names. Validated against v2.9.0, 2026-08-17.
- [`core/action/custom.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/action/custom.go) — yaegi setup, script contract, `unsafe`. Validated against v2.9.0, 2026-08-17.
- [`core/agent/agent.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/agent/agent.go) — result-metadata recovery at 1109-1128, sink-state tool at 1052-1059. Validated against v2.9.0, 2026-08-17.
- [`webui/routes.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/routes.go) — direct action execution routes. Validated against v2.9.0, 2026-08-17.
