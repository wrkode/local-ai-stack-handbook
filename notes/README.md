# Research notes

These are **not** tutorials. They record how a conclusion in `docs/` was reached: what was
looked at, what was tried, what failed, and what remains unresolved.

They exist because the handbook's claims are only as good as their derivation, and because a
dead end is information. When someone re-verifies this material against a newer version, these
notes are what makes that possible without repeating the whole investigation.

## Conventions

| Rule | Why |
|---|---|
| Numbered, never renumbered | pages in `docs/` cite them by number |
| Dead ends are kept, not deleted | knowing what does *not* work saves the next person the attempt |
| Every claim carries its tier | documented / source-verified / tested / unverified |
| Open questions stay open | an unresolved question recorded honestly beats a guessed answer |
| Written against pinned versions | LocalAI `v4.8.2`, LocalAGI `v2.9.0` source and `v2.8.1` image, LocalRecall `v0.6.4` |

## The notes

| # | Note | Question it answers |
|---|---|---|
| 001 | [Logical versus physical](001-logical-vs-physical.md) | Are these three services or three libraries? |
| 002 | [LocalAGI embedding](002-localagi-embedding.md) | What exactly does LocalAI embed, and which version? |
| 003 | [LocalRecall: library or service](003-localrecall-library-vs-service.md) | Both — and the published image changes the answer |
| 004 | [The Responses API](004-responses-api.md) | Why an agent uses it, and where it diverges from OpenAI |
| 005 | [The memory model](005-memory-model.md) | What "memory" means, and where each kind lives |
| 006 | [Validation log](006-validation-log.md) | What we actually ran, including the failures |

## Reading order

001 first — it establishes the distinction the rest depend on. 006 is a log rather than an
argument and can be read at any point; it is where the reproduced failures live.

## Method

For each question:

1. Read the upstream README and documentation.
2. Read the source at the pinned tag. Record `file:line`.
3. Where docs and source disagree, **document both** and say which to believe.
4. Run it. Record the observed output verbatim, including errors.
5. Where something could not be run, say so and leave the claim source-verified.

Step 4 is the one that produced the most surprising results — see 006. Two of the handbook's
most useful findings came from things going wrong rather than from reading code.

## Evidence tiers

| Tier | Support required |
|---|---|
| **Documented** | a link to the exact upstream page or README anchor |
| **Source-verified** | `path/to/file.go:LINE` at a stated tag |
| **Tested** | a `tested:` block with date, versions and environment |
| **Unverified** | stated as inference or an open question, in the prose |

A page that presents an inference as a fact is a defect. See
[CONTRIBUTING](../CONTRIBUTING.md).
