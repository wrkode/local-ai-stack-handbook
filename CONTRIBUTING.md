# Contributing

This handbook's only real asset is that its claims are traceable. A contribution
that adds plausible-sounding prose makes the repository worse, even if the prose
happens to be correct.

## The evidence rule

Every architectural claim belongs to one of four tiers. Make the tier obvious
from the wording, and support it accordingly.

| Tier | Wording that signals it | Required support |
|------|------------------------|------------------|
| **Documented** | "Upstream documents…" | Link to the exact page or README anchor |
| **Source-verified** | "In v4.8.2, `X` calls `Y`" | `path/file.go:LINE`, pinned to a tag |
| **Tested** | "We observed…" | A `tested:` block from a run you performed |
| **Unverified** | "It is not established whether…" | Say what would settle it |

Three rules follow from this:

1. **Never promote a tier without doing the work.** Reading a README does not
   make a claim source-verified. Reading source does not make it tested.
2. **Version-stamp architectural claims.** This ecosystem restructures between
   minor releases. "LocalAI embeds LocalAGI" is not a fact without "as of
   v4.8.2".
3. **Pin citations to a tag or commit**, never to `master`. A link to a moving
   branch is not a citation.

If upstream documentation and upstream source disagree, document **both**, with
citations, and tell the reader which to believe and why. That discrepancy is
often the most useful paragraph on the page.

## What not to submit

- Pages that paraphrase upstream READMEs.
- Placeholder files created to fill out the directory tree. Fifteen good
  documents beat sixty stubs. If you cannot write a page accurately yet, do not
  create the file.
- `tested:` blocks for configurations you did not run.
- CI checks that appear to test the stack but do not. A test that always passes
  is worse than no test.
- Marketing language. See [Style](#style).

## Style

Senior platform-engineering register. Explain the mechanism, then the
consequence.

Banned words: *seamless, unlock, powerful, revolutionary, game-changing,
cutting-edge, effortless, robust, leverage* (as a verb), *delve, elevate*.

Banned structures: an introduction that restates the title; a summary that
restates the body; "in this section we will…"; lists of adjectives.

Assume the reader knows Linux, containers, HTTP and basic networking. Do not
assume they know LLM serving, agents, RAG, embeddings, MCP, or anything about
this ecosystem.

Prefer a table when the content is structural, and a diagram when the content is
about call direction, sequencing or process boundaries.

## Documentation mechanics

- `docs/` must stay readable as plain Markdown on GitHub. Use relative links
  **including** the `.md` extension so both GitHub and MkDocs resolve them.
- Every technical page ends with an `## Upstream references` section.
- Mermaid diagrams must label transport on every edge (`HTTP`, `gRPC`,
  `in-process`, `fs:`) and use one subgraph per OS process. Unverified edges are
  dashed and labelled as such.
- Recipes follow the fixed section order in
  [`docs/05-recipes/index.md`](docs/05-recipes/index.md). Do not reorder or omit
  sections.
- Code fences are language-tagged. Commands are copy-pasteable: no `$` prompt,
  no output inside the fence.

## Before you open a pull request

```bash
python3 scripts/check-links.py
```

```bash
mkdocs build --strict
```

If you touched shell scripts:

```bash
shellcheck -S warning $(git ls-files '*.sh')
```

If you touched a Compose file:

```bash
docker compose -f compose/<stack>/compose.yaml config --quiet
```

CI runs the same checks. `mkdocs build --strict` fails on unresolved internal
links and on files missing from the navigation, so a new page must be added to
`mkdocs.yml`.

## Adding a recipe

Recipes build progressively — each introduces exactly one new capability. If
your recipe introduces two new components at once, split it.

Start from the template and rules in
[`docs/05-recipes/index.md`](docs/05-recipes/index.md), and place the recipe at
the right position in the learning path rather than appending it to the end.

## Research notes

`notes/` holds numbered architecture notes: how a conclusion was reached,
including the dead ends. They are not tutorials, and they are allowed to be
inconclusive — an honest "we could not determine this" note is a legitimate
contribution and often becomes the seed of a documentation page later.

Number the next file sequentially and add it to
[`notes/README.md`](notes/README.md).

## Relationship to upstream

This repository is not affiliated with the LocalAI, LocalAGI or LocalRecall
projects. Bug reports about those projects belong in their own trackers, not
here.

Issues that **do** belong here: a claim in the handbook that is wrong, a command
that does not work, a configuration we describe that has since changed upstream,
or a question the handbook fails to answer.

## Licence

Contributions are accepted under the Apache License 2.0, matching
[`LICENSE`](LICENSE).
