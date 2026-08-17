# Skills

A skill is **data the model reads**. A tool is **code the model calls**. Keeping
those apart explains everything else on this page.

| | Skill | Tool / action |
|---|---|---|
| What it is | A directory with a `SKILL.md` plus optional `scripts/`, `references/`, `assets/` | A Go function with a JSON argument schema |
| How the model uses it | Asks for its text, reads it, follows it | Emits a tool call and gets a result back |
| Lifecycle | Created and edited at runtime, syncable from git | Compiled into the binary (or interpreted, for custom actions) |
| Where it lives | `<stateDir>/skills/` | `services/actions/`, `core/action/` |
| Implemented by | [skillserver](https://github.com/mudler/skillserver), a separate module | LocalAGI |

A skill can *contain* scripts, but the model reads them as text through a skill
tool; nothing executes them on the model's behalf.

## The format

Skills follow the [Agent Skills specification](https://agentskills.io).
`SKILL.md` carries YAML front matter (`skillserver/pkg/domain/skill.go:43-50`):

| Field | Required | Constraint |
|---|---|---|
| `name` | yes | 1–64 chars, `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` — no leading, trailing or consecutive hyphens |
| `description` | yes | — |
| `license` | no | — |
| `compatibility` | no | ≤ 500 characters |
| `metadata` | no | string map |
| `allowed-tools` | no | space-delimited string or a YAML list |

The resulting `Skill` value carries `Name`, `ID` (`repoName/skillName` for
git-sourced skills, otherwise `skillName`), `Content`, `Metadata`, `SourcePath`
and `ReadOnly` — which is true for anything that came from a git repository.

## Where they live and how they are indexed

Skills sit at a **fixed** path: `<LOCALAGI_STATE_DIR>/skills`
(`services/skills/service.go:19,39-41`). There is no variable for it.

`skilldomain.NewFileSystemManager(skillsDir, gitRepos)` builds the manager and
runs `RebuildIndex()`, which is slow enough that the service guards it with a
second mutex and a double-checked lazy singleton
(`services/skills/service.go:100-129`). The index is Bleve — the same library
behind the unrelated `memory` actions, and not the vector store.

Git repositories are registered through the API and stored alongside the skills
directory. `RefreshManagerFromConfig()` updates repositories in place rather than
recreating the manager, specifically to avoid blocking `ListSkills` during a sync
(`services/skills/service.go:45-72`).

Twenty-one HTTP routes cover this: skill CRUD, export/import, per-skill resource
CRUD, and git-repo add/update/delete/sync/toggle. They are registered
unconditionally and return **503** when the skills service is absent
(`webui/skills_handlers.go:69-71`). Skill names in the path are URL-decoded so
that `repo/skill` identifiers work.

## How a skill reaches the model

Both mechanisms are gated on `enable_skills` (`core/state/config.go:99`), off by
default.

### 1. A system prompt listing what exists

`GetSkillsPrompt` renders XML (`services/skills/prompt.go:19-26`):

```xml
<available_skills>
  <skill><name>…</name><description>…</description></skill>
</available_skills>
```

with an introduction, injected with role `system`. Overridable per agent through
`skills_prompt`.

**The default introduction is wrong.** It tells the model:

> "To request the skill, you need to use the `request_skill` tool."
> — `services/skills/prompt.go:16`

skillserver exposes no such tool. Its MCP tools are `list_skills`, `read_skill`,
`search_skills`, `list_skill_resources`, `read_skill_resource` and
`get_skill_resource_info` (`skillserver/pkg/mcp/server.go:27-91`). The README
names the real set correctly (`README.md:710`); only the prompt is wrong.

The practical effect: the model is instructed to call a tool it will not find in
its tool list. A model on the forced-reasoning path cannot emit the name at all —
the enum contains only real tools — so it either picks one of the real skill
tools anyway or gives up on skills for that turn. Either way, the instruction is
noise in the context of every skills-enabled agent. Override `skills_prompt` with
the real tool names if this matters to you.

### 2. An in-process MCP server

The skills tools are served by a genuine MCP server over an in-memory transport
pair (`services/skills/service.go:166-174`):

```go
serverTransport, clientTransport := mcp.NewInMemoryTransports()
s.mcpSrv = skillmcp.NewServer(mgr)
go func() { s.mcpSrv.RunWithTransport(ctx, serverTransport) }()
client := mcp.NewClient(&mcp.Implementation{Name: "LocalAGI", Version: "v1.0.0"}, nil)
session, err := client.Connect(ctx, clientTransport, nil)
```

No socket, no port, no HTTP handler — the "network" is a Go channel pair. The
session is a lazily created singleton **shared by every agent**, attached through
`WithMCPSession` (`core/state/pool.go:547-551`) and deliberately kept alive when
an agent is stopped or recreated (`core/agent/mcp.go:230-243`).

From cogito's point of view this is an MCP session like any other, so skill tools
go through the same selection, veto and execution path as a remote MCP tool. See
[MCP](mcp.md).

The seam is narrow on purpose: the pool depends on a two-method
`SkillsProvider` interface — `GetSkillsPrompt` and `GetMCPSession`
(`core/state/pool.go:26-29`) — which is exactly what a host application such as
LocalAI implements or reuses.

## Skills across the two deployments

In LocalAI v4.8.2 the same `services/skills` package is used
(`LocalAI/core/services/agentpool/agent_pool.go:198,260`), with skills stored
under LocalAI's own state directory and, per user, at
`<stateDir>/users/<uuid>/skills`. In distributed mode skill metadata lives in
PostgreSQL instead. The format and the MCP tool set are the same.

## Upstream references

- [`services/skills/service.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/services/skills/service.go) — fixed skills directory, lazy manager, in-memory MCP server. Validated against v2.9.0, 2026-08-17.
- [`services/skills/prompt.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/services/skills/prompt.go) — the XML prompt and the `request_skill` line. Validated against v2.9.0, 2026-08-17.
- [`core/state/pool.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/core/state/pool.go) — `SkillsProvider` interface, session attachment. Validated against v2.9.0, 2026-08-17.
- [`webui/skills_handlers.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/skills_handlers.go) — the 21 skill and git-repo routes. Validated against v2.9.0, 2026-08-17.
- [`README.md`](https://github.com/mudler/LocalAGI/blob/v2.9.0/README.md) — the correct skill tool list at line 710. Validated against v2.9.0, 2026-08-17.
- [skillserver `pkg/mcp/server.go`](https://github.com/mudler/skillserver/blob/main/pkg/mcp/server.go) — the six MCP tools actually exposed. Read at the pinned pseudo-version `v0.0.5-0.20260221145827`, 2026-08-17; link is to a moving branch because the module has no matching tag.
- [skillserver `pkg/domain/skill.go`](https://github.com/mudler/skillserver/blob/main/pkg/domain/skill.go) — metadata fields and the name regex. Same pin caveat.
- [Agent Skills specification](https://agentskills.io) — the format skillserver implements. Validated 2026-08-17.
