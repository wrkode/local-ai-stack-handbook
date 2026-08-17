# Ingestion

Two ways in, and only two: a multipart file upload, or an external source the
server polls. There is no third.

## Upload is multipart, file-only

```bash
curl -X POST http://localhost:8080/api/collections/handbook/upload \
  -F "file=@notes.md"
```

The form field must be named exactly `file`. The handler copies the upload to an
`os.CreateTemp` file, then renames it so its basename matches the original
filename — because the index key is derived from `filepath.Base` — stamps
`created_at` metadata, and calls `PersistentKB.Store`.

Response on success is `200` with the index key:

```json
{"success": true, "data": {
  "filename": "notes.md",
  "collection": "handbook",
  "key": "3f2a…-…/notes.md",
  "created_at": "2026-08-17T09:14:22Z"
}}
```

That `uuid/filename` key is the entry's identity everywhere else: it is the
`source` metadata on every chunk, the argument to entry deletion, and the join
key for `GetBySource`.

### Discrepancy: the README promises raw-text input

`README.md:22` describes the web UI as supporting file management **including
support for raw text inputs**.

There is no such thing at v0.6.4.

| Where it would be | What is actually there |
|---|---|
| The route table | 12 routes at `routes.go:177-188`; the only ingest route is multipart upload |
| The web UI Upload page | a collection picker and `<input type="file">`, posting a `FormData` with a real file (`static/js/collectionManager.js:329-341`). No textarea |
| `pkg/client` | `Store(collection, filePath string)` — takes a path, opens the file |

**Believe the code: raw-text ingestion is not available over HTTP.** To index a
string you must write it to a `.txt` file and upload that.

Why has this gone unnoticed upstream? Because the primary consumer routes around
it. LocalAGI's agent-memory write path takes free text, writes it to a temp file
named `<YYYY-MM-DD-HH-MM-SS>-<md5hex>.txt`, and calls `kb.Store(path, meta)`
**in-process** (`LocalAGI/webui/collections/rag_provider.go:29-52`). Embedded
callers never need the endpoint that standalone callers lack.

If you are a standalone caller, do the same thing the embedded one does: write a
temp file, upload it, delete it.

## The trap: `200 OK` does not mean searchable

**This is the single most important behaviour in the LocalRecall chapter.**

Only three extensions are indexable (`isChunkableFile`,
`rag/persistency.go:539-545`):

```go
switch strings.ToLower(filepath.Ext(path)) {
case ".pdf", ".txt", ".md":
    return true
}
return false
```

Anything else is **not rejected**. It is stored as a *raw-only* entry: the bytes
are copied into the asset directory, the entry gets a key, and the upload returns
`200 OK`. No chunks are created. No embeddings are requested. The document can
never appear in a search result — not now, not after a `Repopulate`, not ever,
until the file format itself gains support.

| Behaviour | Indexable (`.pdf`/`.txt`/`.md`) | Everything else |
|---|---|---|
| `POST .../upload` | `200 OK` | **`200 OK`** — identical |
| Appears in `GET .../entries` | yes | **yes** |
| Downloadable via `.../raw` | yes | **yes** |
| `GET .../entries/<name>` | text | **501 Not Implemented** |
| Appears in search results | yes | **never** |
| Any warning, log line or flag in the response | — | **none** |

The design is intentional — commit `96d6387` is "make it prominent that we store
even non indexable content" — but the *prominence* stops at the source comment.
Nothing in the API or the UI tells a user that their `.docx` is inert.

**A `.docx`, `.html`, `.csv`, `.json`, `.epub`, `.rtf`, `.pptx`, `.xlsx` or image
upload is a silent no-op for retrieval purposes.**

### How to detect it

The only signal exposed over HTTP is route 5. After every upload:

```bash
curl -s http://localhost:8080/api/collections/handbook/entries/notes.docx
```

A `501` with `"unsupported file type: .docx"` means the file is stored and
unsearchable. A `200` with a non-empty `content` and `chunk_count >= 1` means it
is indexed. Wire that check into your upload script; there is nothing better
available.

### Working around it

Convert before uploading. LocalRecall does no conversion of its own on the upload
path — no `pandoc`, no HTML-to-text, no OCR. Convert to `.txt` or `.md` in your
own pipeline.

The one exception is the external-sources path, which reaches a much wider format
surface. See [below](#external-sources-reach-formats-upload-cannot).

## The uppercase-extension bug

Two functions disagree about case, and the disagreement is reachable.

| Function | Line | Case handling |
|---|---|---|
| `isChunkableFile` | `rag/persistency.go:540` | `strings.ToLower(filepath.Ext(path))` |
| `fileToText` | `rag/persistency.go:683` | `filepath.Ext(fpath)` — **no lowering** |

So `REPORT.PDF` passes the chunkable gate, enters the extraction path, falls into
`fileToText`'s default branch, and errors with `unsupported file type: .PDF`.
`NOTES.MD` and `LOG.TXT` fail the same way.

This is a live bug at v0.6.4, derived from reading the two switch statements; it
has not been run here. What the caller sees depends on the path:

- `Store` returns the error, so the **upload fails** rather than storing a
  raw-only entry.
- `GetEntryFileContent` on an already-stored uppercase file maps to **501**.

**Rename to lowercase extensions before uploading.** A single `tr` in an upload
script removes an entire failure class:

```bash
name=$(basename "$f"); ext="${name##*.}"
curl -F "file=@$f;filename=${name%.*}.$(echo "$ext" | tr '[:upper:]' '[:lower:]')" ...
```

## Text extraction

`fileToText` (`rag/persistency.go:679-701`) dispatches on extension.

**`.txt` and `.md`** — a plain `io.ReadAll`. Markdown is **not parsed**: the raw
source is embedded verbatim, including `#` markers, table pipes, link syntax and
code fences. Those tokens consume part of every chunk's byte budget and are
embedded as if they were prose.

**`.pdf`** — `extractPDFText`, using `github.com/klippa-app/go-pdfium v1.19.2`
with the **WebAssembly** backend, run by an embedded `tetratelabs/wazero`
runtime.

The PDF library has been replaced twice in three months, and the reasons are
recorded in the code:

| Library | Fate |
|---|---|
| `dslipak/pdf` | no timeout, could block indefinitely |
| `go-fitz` / libmupdf via cgo | reverted — broke aarch64 LocalAI builds on glibc symbol mismatches |
| **go-pdfium / WASM** (current, v0.6.4) | no cgo, one binary for amd64 and arm64 |

That choice is why `CGO_ENABLED=0` and why the runtime image can be `FROM
scratch`.

Extraction mechanics:

- The PDFium pool is initialised lazily under a `sync.Once`, so importers that
  never touch a PDF do not pay the WASM startup cost.
- Pool config is `MinIdle: 1, MaxIdle: 1, MaxTotal: 4` — **at most four
  concurrent PDF extractions per process.** A fifth waits, with its own 30-second
  acquisition timeout.
- Extraction runs on a goroutine behind a wall-clock timeout, default **60
  seconds**, overridable via `LOCALRECALL_PDF_EXTRACT_TIMEOUT` (a Go duration like
  `2m`, or a bare integer meaning seconds). On timeout the caller returns
  immediately and **the goroutine leaks until PDFium finishes** — acknowledged in
  the source.
- Page text is joined with `\n\n`. Those separators are then destroyed by the
  chunker; see [chunking](chunking.md).
- Output is sanitised with `strings.ToValidUTF8(text, " ")` and `\x00` stripping,
  because PDFium can emit invalid UTF-8 from PDFs with custom CMaps and
  PostgreSQL rejects those bytes.

**There is no OCR.** Extraction is text-layer only. A scanned PDF yields empty
text, which produces one empty chunk, which is sent to the embedder as an empty
string — an entry that exists, reports a chunk, and matches nothing meaningful.
Check `chunk_count` and `content` length after uploading scanned material.

## External sources reach formats upload cannot

`POST /api/collections/:name/sources` registers a URL that the server re-fetches
on a schedule. `update_interval` is in **minutes** and defaults to 60 when below
1. The poller ticks every 60 seconds and fires any source whose age has reached
its interval.

Routing is by URL suffix (`rag/sources/router.go:12-30`):

| URL ends with | Fetcher | Result |
|---|---|---|
| `.git` | shallow depth-1 clone; optional base64 SSH key from `GIT_PRIVATE_KEY` | every allowlisted file concatenated |
| `sitemap.xml` | crawl every entry, join with newlines | one text blob |
| anything else | HTTP GET, 30s timeout, UA `LocalRecall/1.0 (…)`, `html2text` | page text |

The fetched text is written to a `.txt` temp file and stored through
`StoreOrReplace`, which deletes the previous chunks by `source` metadata and
re-stores. **That `.txt` step is what bypasses `isChunkableFile`.**

The git fetcher's allowlist is 40 extensions long — `.txt .md .go .py .js .ts
.html .css .json .yaml .yml .xml .sh .bash .c .cpp .h .hpp .java .rb .php .rs
.swift .kt .scala .sql .proto .toml .ini .conf .log .csv .tsv .rst .tex .adoc
.asciidoc .wiki` — with `--- File: <relpath> ---` markers between files. So a git
source can carry source code, HTML and CSV that a direct upload would refuse to
index. HTML is likewise reachable only through the sources path.

**If you need to index a format upload rejects, and it lives in a repository or
behind a URL, register it as a source instead of uploading it.**

Operational caveats, all from [architecture](architecture.md#the-source-manager):

- `last_update` is stamped **before** the fetch, so a failing source looks like a
  slow one.
- Failures are logged only; the API exposes no per-source status.
- Every restart re-fetches every source immediately.
- Two different URLs can sanitise to the same temp filename and overwrite one
  another.
- Under LocalAGI's in-process backend `GIT_PRIVATE_KEY` is never passed, so
  private-git sources cannot authenticate there.

## What ingestion writes

For one uploaded file, in order:

1. `<FILE_ASSETS>/<collection>/<uuid>/<original-filename>` — mode 0644, the
   original bytes, always, indexable or not.
2. If indexable: text extraction, then chunking, then one or more embedding calls
   (batching depends on the engine — see [embeddings](embeddings.md#batching-differs-by-engine)).
3. Chunks into the vector store with metadata `type="file"`,
   `source="<uuid>/<filename>"`, `file_name="<filename>"`, plus `created_at` from
   the upload handler or `url` from a source.

`<COLLECTION_DB_PATH>/collection-<name>.json` holds only the external-source
list. The document list is derived by **walking the asset directory**, not from
any index — which is why entries still list when the vector store is down, and
why deleting files under `FILE_ASSETS` out of band makes entries vanish while
their chunks remain.

## Upstream references

- [`routes.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/routes.go) — `uploadFile` at 405-470, temp-file rename at 446-450, source routes at 483-577. Source-verified against v0.6.4, validated 2026-08-17.
- [`rag/persistency.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/persistency.go) — `isChunkableFile` at 539-545, raw-only storage at 365-368, `fileToText` at 679-701 (no `ToLower` at 683), PDF pipeline at 549-677, metadata at 446-448. Validated 2026-08-17.
- [`rag/sources/git.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/sources/git.go) — 40-extension allowlist at 89-98, file markers at 71-73, SSH key handling at 32-45. Validated 2026-08-17.
- [`rag/sources/web.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/sources/web.go) — page fetch at 14-53, sitemap crawl at 55-64. Validated 2026-08-17.
- [`rag/source_manager.go`](https://github.com/mudler/LocalRecall/blob/v0.6.4/rag/source_manager.go) — `updateSource` at 124-172, `StoreOrReplace` call at 166. Validated 2026-08-17.
- [`static/js/collectionManager.js`](https://github.com/mudler/LocalRecall/blob/v0.6.4/static/js/collectionManager.js) — the Upload page's file-only `FormData` at 329-341. Validated 2026-08-17.
- [`README.md`](https://github.com/mudler/LocalRecall/blob/v0.6.4/README.md) — the raw-text-input claim at line 22. Validated 2026-08-17.
- [`go.mod`](https://github.com/mudler/LocalRecall/blob/v0.6.4/go.mod) — `klippa-app/go-pdfium v1.19.2` at line 9, `tetratelabs/wazero v1.11.0` at line 50. Validated 2026-08-17.
- [LocalAGI `webui/collections/rag_provider.go`](https://github.com/mudler/LocalAGI/blob/v2.9.0/webui/collections/rag_provider.go) — the temp-file-then-`Store` memory write at 29-52. Validated against v2.9.0, 2026-08-17.
