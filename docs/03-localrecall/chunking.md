# Chunking

One strategy, 191 lines, no configuration beyond two numbers. Extracted text is
split into fixed-size pieces measured in **bytes**, aligned to word boundaries,
with optional overlap.

Defaults: **400 bytes, 0 overlap.** Both are unusually small compared with
mainstream RAG defaults, and both are process-global.

## The algorithm

`pkg/chunk/chunking.go`, entered from `chunkFile` (`rag/persistency.go:703-713`):

```go
opts := chunk.Options{MaxSize: maxchunksize, Overlap: chunkOverlap, SplitLongWords: true}
chunks := chunk.SplitParagraphIntoChunksWithOptions(content, opts)
```

Step by step:

1. `strings.Fields(paragraph)` splits the whole document on **any** whitespace.
2. Words are appended greedily while `currentChunk.Len() + 1 + len(word) <= MaxSize`.
3. On overflow the chunk is flushed and a new one starts, optionally prefixed with
   an overlap tail.
4. A word longer than `MaxSize` is hard-split into `MaxSize`-byte pieces when
   `SplitLongWords` is true — it is hardcoded true.

It is **not** recursive, **not** separator-aware, and **not** token-based. There
is no sentence detection, no heading awareness, no markdown parsing, no code-block
protection.

## The function name is wrong

`SplitParagraphIntoChunks` does no paragraph handling whatsoever.

`strings.Fields` is the reason. It treats every run of whitespace — spaces,
single newlines, blank lines, tabs, indentation — identically, and the words are
re-joined with a single space. Everything structural is gone before the first
chunk boundary is chosen:

| Input structure | After `strings.Fields` |
|---|---|
| Paragraph breaks (`\n\n`) | one space |
| Markdown heading on its own line | inline text, `#` retained as a token |
| Markdown table rows | one run-on line of `|`-separated cells |
| Code indentation | collapsed |
| PDF page separators (`\n\n`, inserted by the extractor) | one space |
| List items | run together |

The project's own test acknowledges the gap: `chunk_test.go:45-49` is named
"should split on paragraph boundaries when possible" and asserts only
`ToNot(BeEmpty())`. It does not test paragraph behaviour, because there is none.

Two practical consequences:

- **A chunk boundary can land anywhere**, including mid-sentence and between a
  heading and the text it introduces. At 400 bytes with zero overlap, a heading
  frequently ends up in a different chunk from its own content — so a query
  matching the heading retrieves a fragment that does not contain the answer, and
  a query matching the answer retrieves a fragment with no indication of what it
  is about.
- **Markdown syntax is embedded as content.** `#`, `|`, `` ``` `` and link
  brackets all consume the byte budget and all get embedded. For heavily
  formatted documents a meaningful fraction of every chunk is punctuation.

## Bytes, not characters

`MaxSize` is compared against `len()` on a Go string, which is **bytes**.

The effect on a multilingual corpus is direct, and this matters because the
ecosystem's default embedding model is *multilingual*
(`granite-embedding-107m-multilingual`):

| Script | Bytes per character (UTF-8) | Effective characters in a 400-byte chunk |
|---|---|---|
| ASCII English | 1 | ~400 |
| Latin with accents, Greek, Cyrillic | 2 | ~200 |
| CJK, Devanagari | 3 | ~133 |
| Emoji, some symbols | 4 | ~100 |

A Japanese or Chinese corpus therefore gets chunks roughly **one third** the
semantic size of an English one at the same setting. If your corpus is not
predominantly ASCII, raising `MAX_CHUNKING_SIZE` proportionally is the first
tuning move to make.

There is a related sharp edge: `splitLongString` slices bytes, so hard-splitting
a long non-ASCII word can **split a multi-byte rune** and produce invalid UTF-8
inside a chunk. The PDF path and the PostgreSQL insert path both sanitise invalid
UTF-8 afterwards, so this is mitigated for PDFs and for PostgreSQL — but **not**
for a `.txt` or `.md` file going into chromem.

## Overlap

Zero by default. When set, `overlapTail` walks words backwards from the
just-flushed chunk, accumulating whole words plus their spaces while the running
length stays within the overlap budget, and prepends the result to the next
chunk.

Two properties worth knowing:

- Overlap is **word-aligned and never exceeds the configured bytes**.
- It is **best-effort**: the tail is prepended only if it plus the next word still
  fits within `MaxSize`. Otherwise it is dropped silently. You cannot rely on
  every boundary having overlap.

Clamping: `Overlap >= MaxSize` becomes `MaxSize - 1`; a negative value becomes 0.

Overlap is a recent feature (PR #41, shipped around v0.6.0). Its default of zero
is the single most consequential retrieval-quality setting in LocalRecall, because
with 400-byte chunks and no overlap, any fact spanning a boundary exists in
**neither** chunk in complete form.

## Configuration

| Knob | Default | Set by | Notes |
|---|---|---|---|
| chunk size | **400** bytes | `MAX_CHUNKING_SIZE` | parse error → process exits at startup |
| overlap | **0** bytes | `CHUNK_OVERLAP` | parse error → process exits at startup |
| `SplitLongWords` | `true` | — | hardcoded, not configurable |

Both are parsed with `strconv.Atoi` and call `e.Logger.Fatal` on failure, so
`MAX_CHUNKING_SIZE=400k` kills the process rather than falling back. There is no
range validation: `0` is accepted, then clamped to 1 inside the chunker,
producing one chunk per byte.

### Changing the configuration

The values are **process-global**, captured once at startup and baked into every
`PersistentKB`. There is no per-collection chunk configuration anywhere in the
API or the library constructors.

**Changing them does not re-chunk anything that already exists.** A collection
ingested at 400 bytes keeps 400-byte chunks after you set 1200. Two ways to
apply new settings:

1. **Reset and re-upload.** Note that reset is really delete — see
   [collections](collections.md#the-complete-route-table), route 8 — so you need
   your originals elsewhere, or you must download them via `.../raw` first.
2. **Trigger a `Repopulate`.** It re-chunks and re-embeds every chunkable file on
   disk using the *current* settings. It is not exposed as an endpoint; it fires
   on an embedding-dimension mismatch at collection open, and on entry removal
   when `LOCALRECALL_REPOPULATE_DELETE=true`. Both are side effects of other
   operations, so treat this as a mechanism to be aware of rather than a tool to
   reach for.

## What size should you use?

There is no measured recommendation here — nothing in this chapter was executed.
What the code establishes is the shape of the trade-off:

| Setting | Effect | Cost |
|---|---|---|
| Larger `MAX_CHUNKING_SIZE` | more context per hit; fewer boundary-straddling facts; fewer embedding calls (materially cheaper on chromem, which sends **one HTTP request per chunk**) | each vector represents more, diluting topical specificity; more of the context window consumed per retrieved chunk |
| Non-zero `CHUNK_OVERLAP` | facts spanning a boundary survive in at least one chunk | duplicate text inflates the store and can return near-identical hits, wasting top-K slots |
| Default 400 / 0 | maximal precision per vector; smallest possible retrieval unit | ~60-100 English words per chunk, ~100 tokens — often less than one paragraph |

A defensible starting point for prose in English is a chunk size in the low
thousands of bytes with an overlap of roughly 10-15% of it, then measuring. For
non-ASCII corpora, scale the byte figure by the bytes-per-character table above.
Whatever you pick, decide it **before** first ingest — retrofitting means a reset.

One detail to keep in mind while tuning top-K: `GET .../entries/:entry`
deliberately re-extracts text from the file on disk rather than concatenating
chunks, precisely so overlap does not appear duplicated. So a healthy-looking
entry-content response tells you nothing about your chunk settings. Use
`chunk_count` from that same response for that.

## Edge case: the empty file

`SplitParagraphIntoChunks("")` returns `[]string{""}` — a one-element slice
holding an empty string, not an empty slice.

`PersistentKB.store` guards with `len(pieces) == 0` → `"no chunks generated for
file"`. An empty file produces **one** chunk, so it passes the guard, and an empty
string is sent to the embedder and stored as a vector. The same applies to a
scanned PDF with no text layer. Neither errors; both create an entry that
occupies a top-K slot and means nothing.

## Upstream references

- [`pkg/chunk/chunking.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/pkg/chunk/chunking.go) — `Options` at 8-16, clamping at 69-78, `strings.Fields` at 99, greedy accumulation at 129-147, overlap prepend at 149-157, `splitLongString` at 20-34, empty-input return at 82-84. Source-verified against v0.6.4, validated 2026-08-17.
- [`pkg/chunk/chunk_test.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/pkg/chunk/chunk_test.go) — the empty-input expectation at 20-25 and the non-assertion at 45-49. Validated 2026-08-17.
- [`rag/persistency.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/persistency.go) — `chunkFile` at 703-713 with `SplitLongWords: true`; `Repopulate` at 249; the `no chunks generated` guard at 450-452. Validated 2026-08-17.
- [`main.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/main.go) — defaults `chunkingSize := 400` at 72 and `overlap := 0` at 81; fatal parse handling at 73-88. Validated 2026-08-17.
- [LocalRecall PR #41](https://github.com/mudler/LocalRecall/pull/41) — chunk overlap and entry fetch. Validated 2026-08-17.
