#!/usr/bin/env bash
#
# lint-docs.sh — structural and style checks for the handbook's own prose.
#
# These check the REPOSITORY, not the LocalAI stack. They must never be
# presented as integration tests.
#
#   ./scripts/lint-docs.sh          # all checks
#   ./scripts/lint-docs.sh --fix    # nothing is auto-fixable; lists offenders
#
# Exit 0 when clean, 1 when any check fails.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

FAILED=0

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_HEAD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_BAD=''; C_DIM=''; C_HEAD=''; C_OFF=''
fi

head_() { printf '\n%s== %s ==%s\n' "$C_HEAD" "$1" "$C_OFF"; }
pass_() { printf '  %sok%s    %s\n' "$C_OK" "$C_OFF" "$1"; }
fail_() { printf '  %sfail%s  %s\n' "$C_BAD" "$C_OFF" "$1"; FAILED=1; }
note_() { printf '        %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }

# Markdown files that are handbook content. .claude/ is private tooling.
mdfiles() {
  find . -name '*.md' \
    -not -path './.git/*' -not -path './.claude/*' \
    -not -path './site/*' -not -path './.venv/*' | sort
}

# ---------------------------------------------------------------------------
head_ "Marketing language"
# ---------------------------------------------------------------------------
# From CLAUDE.md's forbidden list. Matched case-insensitively on word
# boundaries. "leverage" is only forbidden as a verb, which a regex cannot
# determine, so it is reported for human judgement rather than failed on.
BANNED='seamless|unlock(s|ed|ing)?|powerful|revolutionary|game-changing|cutting-edge|effortless|robust|delve|elevate|in todays fast-paced|in today.s fast-paced'
hits=$(mdfiles | xargs grep -inE "\\b(${BANNED})\\b" 2>/dev/null | grep -vE '^\./(CLAUDE|CONTRIBUTING)\.md' || true)
if [ -n "$hits" ]; then
  fail_ "forbidden marketing words found"
  printf '%s\n' "$hits" | head -20
else
  pass_ "no forbidden marketing words"
fi

soft=$(mdfiles | xargs grep -inE '\bleverage\b' 2>/dev/null | grep -vE '^\./(CLAUDE|CONTRIBUTING)\.md' || true)
if [ -n "$soft" ]; then
  note_ "'leverage' present — check it is a noun, not a verb:"
  printf '%s\n' "$soft" | head -5
fi

# ---------------------------------------------------------------------------
head_ "Preamble phrases"
# ---------------------------------------------------------------------------
# A preamble ANNOUNCES what follows. Requiring the announcing verb avoids
# flagging legitimate sentences that merely refer to "this chapter".
hits=$(mdfiles | xargs grep -inE "[Ii]n this (section|chapter|page|document),? (we|you) ?('ll| will| are going to)|[Ww]e will (cover|discuss|explore|look at|examine) " 2>/dev/null | grep -vE '^\./(CLAUDE|CONTRIBUTING)\.md' || true)
if [ -n "$hits" ]; then
  fail_ "'in this section we will' style preamble found"
  printf '%s\n' "$hits" | head -10
else
  pass_ "no preambles"
fi

# ---------------------------------------------------------------------------
head_ "Upstream references section"
# ---------------------------------------------------------------------------
# Every technical page under docs/ must end with one. Index and landing pages
# are exempt: they cite nothing of their own.
EXEMPT='docs/index.md|docs/05-recipes/index.md'
missing=''
while IFS= read -r f; do
  case "$f" in
    ./docs/*) ;;
    *) continue ;;
  esac
  rel="${f#./}"
  if printf '%s' "$rel" | grep -qE "^(${EXEMPT})$"; then continue; fi
  grep -q '^## Upstream references' "$f" || missing="${missing}${rel}"$'\n'
done < <(mdfiles)

if [ -n "$missing" ]; then
  fail_ "pages without an '## Upstream references' section:"
  printf '%s' "$missing"
else
  pass_ "every technical page cites its upstream references"
fi

# ---------------------------------------------------------------------------
head_ "Recipe structure"
# ---------------------------------------------------------------------------
# The section order is fixed by .claude/skills/recipe-author. Check presence,
# not order — order is a review concern, absence is a defect.
REQUIRED_SECTIONS=(
  "## Goal" "## Architecture" "## What you will learn" "## Components"
  "## Prerequisites" "## Versions tested" "## Start the environment"
  "## Verify each dependency" "## Configure the system" "## Run the request"
  "## Expected result" "## What happened internally" "## Request flow"
  "## Persistent state" "## Logs worth inspecting" "## Failure modes"
  "## Troubleshooting" "## Cleanup" "## Variations" "## Upstream references"
)
recipe_bad=0
for f in docs/05-recipes/*.md; do
  [ "$(basename "$f")" = "index.md" ] && continue
  for s in "${REQUIRED_SECTIONS[@]}"; do
    if ! grep -qF "$s" "$f"; then
      fail_ "$f is missing '$s'"
      recipe_bad=1
    fi
  done
done
[ "$recipe_bad" = "0" ] && pass_ "all recipes carry every required section"

# ---------------------------------------------------------------------------
head_ "Tested blocks"
# ---------------------------------------------------------------------------
# A recipe must either carry a real `tested:` block or say explicitly that it
# was not validated. Silence is the defect this catches.
tb_bad=0
for f in docs/05-recipes/*.md; do
  [ "$(basename "$f")" = "index.md" ] && continue
  if grep -q '^tested:' "$f"; then
    grep -qE '^ *date: [0-9]{4}-[0-9]{2}-[0-9]{2}|^ *- pass: ' "$f" \
      || { fail_ "$f has a tested: block with no date"; tb_bad=1; }
  elif grep -qiE 'Not yet validated' "$f"; then
    : # explicitly marked — correct
  else
    fail_ "$f has neither a tested: block nor a 'Not yet validated' marker"
    tb_bad=1
  fi
done
[ "$tb_bad" = "0" ] && pass_ "every recipe states its validation status"

# ---------------------------------------------------------------------------
head_ "Code fences are tagged"
# ---------------------------------------------------------------------------
# An untagged fence loses syntax highlighting and, in recipes, hides whether a
# block is a command or output.
untagged=$(mdfiles | while IFS= read -r f; do
  awk -v F="$f" '
    /^[[:space:]]*(```|~~~)/ {
      # Track open/close: a closing fence has no language, so only flag opens.
      if (inb) { inb=0; next }
      inb=1
      line=$0
      sub(/^[[:space:]]*(```|~~~)/, "", line)
      if (line ~ /^[[:space:]]*$/) print F ":" NR ": untagged code fence"
    }
  ' "$f"
done)
if [ -n "$untagged" ]; then
  fail_ "untagged code fences found"
  printf '%s\n' "$untagged" | head -20
else
  pass_ "every code fence is tagged"
fi

# ---------------------------------------------------------------------------
head_ "Content files are tracked by git"
# ---------------------------------------------------------------------------
# The link checker reads the WORKING TREE, so a file that exists locally but was
# never committed passes locally and fails in CI. That happened: .gitignore
# listed an unanchored "AGENTS.md", and because git matches ignore rules
# case-insensitively when core.ignoreCase is true (the macOS default), it
# silently swallowed docs/02-localagi/agents.md — a real page, in the nav, linked
# from two others.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  untracked=''
  for d in docs notes examples kubernetes compose scripts; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do
      case "$f" in */.env) continue ;; esac
      git ls-files --error-unmatch "$f" >/dev/null 2>&1 || untracked="${untracked}${f}"$'\n'
    done < <(find "$d" -type f)
  done
  if [ -n "$untracked" ]; then
    fail_ "content files exist locally but are NOT tracked by git:"
    printf '%s' "$untracked"
    note_ "check: git check-ignore -v <path>"
  else
    pass_ "every content file is tracked"
  fi
else
  note_ "not a git repository — skipped"
fi

# ---------------------------------------------------------------------------
head_ "Internal links and anchors"
# ---------------------------------------------------------------------------
if python3 scripts/check-links.py > /tmp/lint-links.$$ 2>&1; then
  pass_ "$(head -1 /tmp/lint-links.$$)"
else
  fail_ "unresolved internal references"
  cat /tmp/lint-links.$$
fi
rm -f /tmp/lint-links.$$

# ---------------------------------------------------------------------------
head_ "Shell scripts"
# ---------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2046
  if shellcheck -S warning $(find . -name '*.sh' -not -path './.git/*' | sort); then
    pass_ "shellcheck clean at -S warning"
  else
    fail_ "shellcheck reported problems"
  fi
else
  note_ "shellcheck not installed — skipped (CI runs it)"
fi

# ---------------------------------------------------------------------------
head_ "Result"
# ---------------------------------------------------------------------------
if [ "$FAILED" = "0" ]; then
  printf '%sAll documentation checks passed.%s\n' "$C_OK" "$C_OFF"
else
  printf '%sDocumentation checks failed.%s\n' "$C_BAD" "$C_OFF"
  printf 'These are style and structure rules from CLAUDE.md and the recipe template.\n'
fi
exit "$FAILED"
