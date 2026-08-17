#!/usr/bin/env python3
"""Check internal Markdown links and heading anchors across the repository.

This checks only *internal* references: relative file links and in-page
anchors. External URLs are not fetched — a network check would make CI
non-deterministic and would fail on rate limits rather than on real defects.

Exit code 0 when clean, 1 when any reference is unresolvable.

    python3 scripts/check-links.py
"""

from __future__ import annotations

import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SKIP_DIRS = {".git", "site", ".venv", "venv", "node_modules", "__pycache__", ".claude"}

# [text](target) — target captured up to the closing paren or a title string.
# Skips image embeds (leading !) and reference-style definitions.
LINK_RE = re.compile(r"(?<!!)\[(?:[^\]]*)\]\(\s*([^)\s]+)(?:\s+\"[^\"]*\")?\s*\)")

# ATX headings, ignoring those inside fenced code blocks (handled below).
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")

FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})")

# Inline code spans. Stripped before link extraction so that regexes and shell
# snippets written inside backticks are not mistaken for Markdown links —
# `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` otherwise parses as [text](target).
INLINE_CODE_RE = re.compile(r"`+[^`]*`+")


def markdown_files() -> list[Path]:
    out = []
    for p in ROOT.rglob("*.md"):
        if any(part in SKIP_DIRS for part in p.relative_to(ROOT).parts):
            continue
        out.append(p)
    return sorted(out)


def strip_code_fences(text: str) -> list[tuple[int, str]]:
    """Return (line_number, line) for lines outside fenced code blocks."""
    lines: list[tuple[int, str]] = []
    fence: str | None = None
    for i, line in enumerate(text.splitlines(), start=1):
        m = FENCE_RE.match(line)
        if m:
            token = m.group(1)
            if fence is None:
                fence = token[0] * 3
                continue
            if line.strip().startswith(fence):
                fence = None
                continue
        if fence is None:
            lines.append((i, line))
    return lines


def slugify(heading: str) -> str:
    """Reproduce the GitHub/MkDocs heading-anchor slug.

    Both renderers lowercase, drop punctuation and join words with hyphens.
    Inline markdown (code spans, emphasis, links) is stripped first.
    """
    text = heading
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\*{1,3}([^*]+)\*{1,3}", r"\1", text)
    # Underscore emphasis only at word boundaries. A naive [*_] pattern eats
    # intra-word underscores, turning a heading like `OPENAI_BASE_URL is set`
    # into "openaibaseurl-is-set" and breaking every link to it.
    text = re.sub(r"(?<!\w)_{1,3}([^_]+)_{1,3}(?!\w)", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = unicodedata.normalize("NFKD", text)
    text = text.lower().strip()
    text = re.sub(r"[^\w\s-]", "", text)
    # Only whitespace collapses to hyphens. Underscores are PRESERVED — both
    # GitHub and MkDocs keep them, so a heading like `OPENAI_BASE_URL is set`
    # anchors as "openai_base_url-is-set", not "openai-base-url-is-set".
    text = re.sub(r"\s+", "-", text)
    return text.strip("-")


def anchors_for(path: Path) -> set[str]:
    found: set[str] = set()
    counts: dict[str, int] = {}
    for _, line in strip_code_fences(path.read_text(encoding="utf-8")):
        m = HEADING_RE.match(line)
        if not m:
            continue
        slug = slugify(m.group(2))
        if not slug:
            continue
        n = counts.get(slug, 0)
        counts[slug] = n + 1
        # Duplicate headings get -1, -2 … suffixes in both renderers.
        found.add(slug if n == 0 else f"{slug}-{n}")
    # Explicit anchors: <a id="x"> / {#x}
    raw = path.read_text(encoding="utf-8")
    found.update(re.findall(r'<a\s+(?:id|name)="([^"]+)"', raw))
    found.update(re.findall(r"\{#([A-Za-z0-9_-]+)\}", raw))
    return found


def main() -> int:
    files = markdown_files()
    if not files:
        print("no markdown files found")
        return 0

    anchor_cache: dict[Path, set[str]] = {}
    problems: list[str] = []
    checked = 0

    for path in files:
        rel = path.relative_to(ROOT)
        for lineno, line in strip_code_fences(path.read_text(encoding="utf-8")):
            for target in LINK_RE.findall(INLINE_CODE_RE.sub("", line)):
                if target.startswith(("http://", "https://", "mailto:", "tel:")):
                    continue
                checked += 1
                frag = ""
                if "#" in target:
                    target, frag = target.split("#", 1)

                if target == "":
                    dest = path
                else:
                    dest = (path.parent / target).resolve()

                if not dest.exists():
                    problems.append(
                        f"{rel}:{lineno}: missing target -> {target or '(self)'}"
                    )
                    continue

                if frag and dest.suffix == ".md":
                    if dest not in anchor_cache:
                        anchor_cache[dest] = anchors_for(dest)
                    if frag.lower() not in anchor_cache[dest]:
                        problems.append(
                            f"{rel}:{lineno}: missing anchor #{frag} in "
                            f"{dest.relative_to(ROOT)}"
                        )

    print(f"checked {checked} internal links across {len(files)} files")
    if problems:
        print(f"\n{len(problems)} unresolved reference(s):\n")
        for p in problems:
            print(f"  {p}")
        return 1
    print("all internal links resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
