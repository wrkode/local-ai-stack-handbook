# 001 — Logical versus physical architecture

**Question:** are LocalAI, LocalAGI and LocalRecall three services, three libraries, or
something else?

**Answer:** they are three *logical layers* that map onto one, two, three or four processes
depending on configuration — and the mapping is not a deployment preference, it is decided by
which versions you can actually run.

This is the note the rest depend on.

## What we looked at

| Source | What it settled |
|---|---|
| `LocalAI/go.mod` | LocalAI **imports** LocalAGI and LocalRecall as Go modules |
| `LocalAGI/go.mod` (v2.9.0) | LocalAGI **imports** LocalRecall |
| `LocalAGI/go.mod` (v2.8.1) | LocalAGI **does not** import LocalRecall at all |
| `LocalAGI/webui/routes.go:219-227` | in-process vs HTTP collections backend, one variable |
| `LocalAGI/cmd/serve.go:113-120` | in-process vs HTTP retrieval provider, same variable |
| `LocalAGI/webui/collections/rag_provider.go:155` | a comment naming LocalAI as an external consumer |
| Running containers | which processes actually exist |

The `rag_provider.go` comment is worth quoting because it settles intent rather than
mechanism:

```go
// RAGProviderFromState returns a RAG provider function from a State.
// External consumers (e.g. LocalAI) can call NewInProcessBackend to get the state,
// then pass it here to create a RAG provider for the agent pool.
```

LocalAGI is *designed* to be embedded. The library form is not an accident of packaging.

## The conclusion

**The logical boundaries are real and stable. The process boundaries are configuration.**

Responsibilities do not move: model execution is always LocalAI's, the agent loop is always
cogito's, chunking and vector persistence are always LocalRecall's code. What varies is
whether a boundary is a network hop or a Go function call.

That is why the handbook keeps the two words apart, and why every architecture diagram in
`docs/` labels its edges with the transport.

## The pattern that surprised us

Even in the fully integrated single-container deployment, the agent pool reaches inference
over **HTTP on 127.0.0.1**, and the knowledge layer reaches embeddings the same way. Observed
in a stock container's log:

```text
INFO Agent pool started (standalone/LocalAGI mode) stateDir="//data" apiURL="http://127.0.0.1:8080"
```

So "all in one container" still contains real HTTP boundaries. They hit the auth middleware,
they appear in the access log, and they can fail independently. This is also why LocalAI
starts its agent pool **after** the HTTP listener is accepting connections — starting it first
would deadlock, because knowledge-base backends call the embeddings API on the same process.

A logical boundary preserved as a physical one, deliberately.

## Where the mapping is decided for you

This is the part that changed after we tried to run it (see [006](006-validation-log.md)).

| Layer | Embedded form exists? | In a runnable image? |
|---|---|---|
| LocalAGI inside LocalAI | yes | **yes** — LocalAI v4.8.2 |
| LocalRecall inside LocalAI | yes | **yes** — LocalAI v4.8.2 |
| LocalRecall inside LocalAGI | yes, in v2.9.0 source | **no** — v2.8.1 is the newest image and does not import it |

So the embedded-knowledge story is true of LocalAI today and **not** of any LocalAGI you can
pull. Standalone LocalAGI always talks to LocalRecall over HTTP.

## Version skew is the hidden cost of embedding

Because LocalAI vendors the other two, its `go.mod` — not you — decides their versions:

| Embedded component | Pinned as |
|---|---|
| LocalAGI | `v0.0.0-20260606071251-14aed1ae4336` — an untagged commit |
| LocalRecall | `v0.6.3` |
| cogito | `v0.11.1-0.20260721122412-6eece18a6bb6` |

Two consequences worth stating:

**LocalAI cannot consume LocalAGI's releases at all.** LocalAGI's module path has no `/v2`
suffix, so Go cannot resolve its `v2.x` tags. LocalAI can only pin raw commits from `main`.
The embedded agent platform therefore tracks an untagged commit, never a release.

**The cogito split is the one that changes behaviour.** LocalAI v4.8.2 links a cogito from
2026-07-21; LocalAGI v2.9.0 links one from 2026-03-15; LocalAGI v2.8.1 links one from
2026-02-16. Roughly five months between the extremes. "Agent behaviour" is therefore not one
thing — it depends on which binary is running the loop.

## What this means for the handbook

- Never say "LocalAGI the service" without qualification.
- Always name the transport on a diagram edge.
- State which deployment shape a claim applies to.
- Distinguish "exists in source" from "exists in an image".

## Open question

Whether LocalAI's embedded LocalAGI commit includes the in-process LocalRecall path that
v2.9.0 has, or predates it. `14aed1ae4336` is dated 2026-06-06, after v2.9.0's 2026-05-08
release, so it probably does — but we did not verify the commit's contents. LocalAI's own
`/api/agents/collections` routes exist, which is consistent with it.

## References

- `LocalAI/go.mod` — pinned LocalAGI, LocalRecall and cogito versions
- `LocalAI/core/cli/run.go` — startup ordering; the agent pool started after the listener
- `LocalAI/core/http/routes/agents.go` — `/api/agents/collections` route group
- `LocalAGI/webui/routes.go:217-227`, `LocalAGI/cmd/serve.go:113-120` — the two forks
- `LocalAGI/webui/collections/rag_provider.go:152-156` — the embedding-intent comment
- `LocalAGI/go.mod` at v2.9.0 and v2.8.1 — the divergence
- Startup log and image inventory: observed 2026-08-17, [006](006-validation-log.md)
