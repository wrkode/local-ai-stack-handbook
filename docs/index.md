# LocalAI Stack Handbook

An independent field manual for LocalAI, LocalAGI and LocalRecall.

!!! warning "Not official documentation"
    This handbook is not produced, endorsed or reviewed by the LocalAI, LocalAGI
    or LocalRecall projects. It is independently maintained. Every technical page
    ends with links to the exact upstream file, release or documentation page it
    was derived from; when this handbook and upstream disagree, upstream is
    authoritative and the disagreement is worth reporting.

## What this handbook is for

Documentation for these three projects is spread across three repositories, a
website, several sets of Docker examples, and a fourth project that neither
README names prominently. The result is that a competent engineer can read
everything available and still not be able to say which process owns agent state,
who computes an embedding, or what happens between a request arriving and a
response leaving.

This handbook answers those questions from first principles, and states how each
answer was obtained.

## Start here

If you read three pages, read these:

<div class="grid cards" markdown>

-   **[The ecosystem](00-overview/ecosystem.md)**

    What each project actually is, why there are three of them, and the fourth
    project — `cogito` — that owns the agent loop.

-   **[Architecture](00-overview/architecture.md)**

    The stack built up one component at a time. Every diagram labels its edges
    with the transport, so you can see which calls cross a process boundary.

-   **[Logical vs physical](00-overview/logical-vs-physical.md)**

    Three names, one to three processes. Which deployment shapes are actually
    supported, and what each one costs.

</div>

## The model, and its three errors

```text
LocalAI     = model / compute runtime
LocalAGI    = agent platform
LocalRecall = knowledge / retrieval layer
MCP         = external capability boundary
```

Correct about responsibilities, misleading about processes:

| The model implies | Actually |
|---|---|
| Three deployable services | One `local-ai` process can be all three. LocalAGI links LocalRecall as a library; LocalAI links both. |
| LocalAGI runs the agent loop | The loop is [`mudler/cogito`](https://github.com/mudler/cogito), a shared library. LocalAI links a much newer version of it than LocalAGI does. |
| LocalRecall is a vector database | It stores nothing itself and computes no embeddings. It calls an OpenAI-compatible embeddings endpoint and writes to a backend. |

## Learning path

Each step assumes only the ones before it.

| Step | Page | Answers |
|---|---|---|
| 1 | [Ecosystem](00-overview/ecosystem.md) | What are these projects, and why three? |
| 2 | [Architecture](00-overview/architecture.md) | How do they fit together? |
| 3 | [Logical vs physical](00-overview/logical-vs-physical.md) | Which is a service right now? |
| 4 | [Terminology](00-overview/terminology.md) | What do "memory", "agent", "knowledge" mean here? |
| 5 | [Recipe 1](05-recipes/localai-chat.md) → [Recipe 2](05-recipes/localai-embeddings.md) | Inference, then embeddings. |
| 6 | [Recipe 3](05-recipes/localrecall-rag.md) | Ingest and retrieve documents. |
| 7 | [Recipe 4](05-recipes/simple-agent.md) → [6](05-recipes/agent-with-knowledge.md) | An agent, then tools, then knowledge. |
| 8 | [Recipe 7](05-recipes/mcp-agent.md) → [9](05-recipes/multi-agent.md) | MCP, full stack, delegation. |
| 9 | [Deep dives](07-deep-dives/memory-vs-knowledge.md) | Why does it behave that way? |

## Questions this handbook answers directly

**Ownership**

- [Which project owns agents, inference and retrieval?](00-overview/project-boundaries.md)
- [Where does agent state live, and what is lost if it isn't persisted?](02-localagi/state.md)
- [Who creates embeddings, and who stores the vectors?](03-localrecall/embeddings.md)
- [What exactly is meant by "memory"?](07-deep-dives/memory-vs-knowledge.md)

**Interfaces**

- [Which API should an application call?](08-reference/api-map.md)
- [What is the Responses API for, and how does it differ from Chat Completions?](07-deep-dives/responses-vs-chat-completions.md)
- [How does LocalAGI talk to LocalAI, and to LocalRecall?](04-integration/overview.md)
- [Where does MCP fit, and where does it not?](02-localagi/mcp.md)

**Operations**

- [What happens between request and response?](04-integration/data-flow.md)
- [Which components can be separated, and when should they be?](04-integration/deployment-patterns.md)
- [What is required for production, and what is missing?](06-deployment/production.md)
- [How do I isolate which layer failed?](01-localai/troubleshooting.md)

## Evidence policy

Every architectural claim belongs to one of four tiers, stated explicitly
wherever it is not obvious:

| Tier | Support required |
|---|---|
| **Documented** | Link to the exact upstream page or README anchor |
| **Source-verified** | `path/to/file.go:LINE` at a stated commit or tag |
| **Tested** | A `tested:` block with date, versions and environment |
| **Unverified** | Said to be inference or an open question, in the prose |

A page that presents an inference as a fact is a defect. Report it.

## Versions

| Project | Version | Notes |
|---|---|---|
| LocalAI | `v4.8.2` | released 2026-08-07 |
| LocalAGI | `v2.9.0` | source tag only — **no published container image**; highest is `v2.8.1` |
| LocalRecall | `v0.6.4` | released 2026-07-19 |

Validated 2026-08-17 on `darwin/arm64` under Docker, CPU only. What was *not*
validated is recorded just as explicitly in the
[version matrix](00-overview/version-matrix.md).
