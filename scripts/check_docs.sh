#!/usr/bin/env bash
#
# Documentation consistency check (see IMPROVEMENTS.md, 2026-08-17).
#
# Three failure modes this repo has actually hit, each cheap to detect and
# impossible to notice by eye once the docs grow:
#
#   1. AGENTS.md links a doc that does not exist -> an agent following the
#      "read this first" list silently starts work with missing context.
#   2. CLAUDE.md's short "Currently open TDs" table drifts from the full
#      registry in docs/TECH_DEBT.md -> a TD reads as open in one file and
#      Resolved in the other (this happened with TD-002 and TD-015).
#   3. The convention blocks AGENTS.md duplicates verbatim from CLAUDE.md
#      drift apart -> two contradictory copies of the Hard Rules.
#
# Pure bash + coreutils/awk: no npm install, no Python, nothing to cache, so
# the CI job stays a few seconds (TD-008: keep the workflow lightweight).
#
# Usage: scripts/check_docs.sh   (exit 0 = all good, 1 = at least one failure)

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

AGENTS="AGENTS.md"
CLAUDE="CLAUDE.md"
TECH_DEBT="docs/TECH_DEBT.md"

failures=0

fail() {
  printf '  ✗ %s\n' "$1"
  failures=$((failures + 1))
}

ok() {
  printf '  ✓ %s\n' "$1"
}

# Drop fenced code blocks so a path mentioned inside a shell example is never
# mistaken for a real link (CLAUDE.md's git commands contain such paths).
strip_fences() {
  awk '/^[[:space:]]*```/ { inblock = !inblock; next } !inblock' "$1"
}

require_file() {
  [ -f "$1" ] || { printf '✗ falta el archivo requerido: %s\n' "$1"; exit 1; }
}

require_file "$AGENTS"
require_file "$CLAUDE"
require_file "$TECH_DEBT"

# ---------------------------------------------------------------------------
# 1. Every .md linked from AGENTS.md exists
# ---------------------------------------------------------------------------
# Only real markdown links -- [text](path.md) -- are checked, deliberately.
# Bare or backticked filenames in prose are NOT links: AGENTS.md discusses
# AGENTS.legacy.md (deleted on purpose) in its decision note, and requiring
# that to exist would be wrong. Keeping the rule "a link must resolve" makes
# the check precise and needs no allowlist to maintain.
printf '1. Enlaces .md desde %s\n' "$AGENTS"

links=$(strip_fences "$AGENTS" \
  | grep -oE '\]\([^)]+\.md(#[^)]*)?\)' \
  | sed -E 's/^\]\(//; s/\)$//; s/#.*$//' \
  | sort -u)

if [ -z "$links" ]; then
  fail "no se encontró ningún enlace markdown a .md (¿se rompió el formato?)"
else
  while IFS= read -r link; do
    case "$link" in
      http://* | https://*) continue ;;
    esac
    if [ -f "$link" ]; then
      ok "$link"
    else
      fail "enlace roto: $link"
    fi
  done <<< "$links"
fi

# ---------------------------------------------------------------------------
# 2. CLAUDE.md's short open-TD table agrees with docs/TECH_DEBT.md
# ---------------------------------------------------------------------------
printf '\n2. Tabla corta de TDs (%s) vs registro completo (%s)\n' "$CLAUDE" "$TECH_DEBT"

# The short table lives between the "**Currently open TDs**" marker and the
# next horizontal rule.
short_tds=$(awk '
  /^\*\*Currently open TDs\*\*/ { inside = 1; next }
  inside && /^---$/             { exit }
  inside && /^\| TD-[0-9]+/     { split($0, f, "|"); gsub(/ /, "", f[2]); print f[2] }
' "$CLAUDE")

if [ -z "$short_tds" ]; then
  fail "no se encontró la tabla \"Currently open TDs\" en $CLAUDE"
else
  while IFS= read -r td; do
    # Status is the 4th field counted from the end (| ... | Status | Owner |
    # Created |), which survives a description containing extra pipes.
    status=$(awk -F'|' -v id="$td" '
      $0 ~ "^\\| " id " \\|" {
        if (NF < 6) { print "MALFORMED"; exit }
        s = $(NF - 3)
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        print s
        exit
      }
    ' "$TECH_DEBT")

    if [ -z "$status" ]; then
      fail "$td está en la tabla corta de $CLAUDE pero no existe en $TECH_DEBT"
    elif [ "$status" = "MALFORMED" ]; then
      fail "$td: fila con formato inesperado en $TECH_DEBT"
    elif [ "${status#Resolved}" != "$status" ]; then
      # Prefix match: "Partially resolved (...)" is still open, and must not
      # trip this. Only a status that *starts* with "Resolved" counts.
      fail "$td figura como abierto en $CLAUDE pero Resolved en $TECH_DEBT"
    else
      ok "$td abierto en ambos (\"${status:0:40}...\")"
    fi
  done <<< "$short_tds"
fi

# ---------------------------------------------------------------------------
# 3. Duplicated convention blocks are byte-identical in both files
# ---------------------------------------------------------------------------
printf '\n3. Bloques duplicados %s <-> %s\n' "$AGENTS" "$CLAUDE"

# HTML-comment markers rather than a heading-based diff: headings move, get
# renamed and get re-nested, and any of that silently changes what a
# positional diff compares. A marker pair is explicit about where a block
# starts and ends, is invisible in rendered markdown, and makes an
# accidentally-deleted marker a loud failure instead of a silent skip.
slugs_of() {
  grep -oE '<!-- sync-start: [a-z0-9-]+ -->' "$1" \
    | sed -E 's/<!-- sync-start: //; s/ -->//' \
    | sort
}

extract_block() {
  # $1 = file, $2 = slug
  awk -v slug="$2" '
    $0 == "<!-- sync-start: " slug " -->" { inside = 1; next }
    $0 == "<!-- sync-end: "   slug " -->" { inside = 0 }
    inside
  ' "$1"
}

agents_slugs=$(slugs_of "$AGENTS")
claude_slugs=$(slugs_of "$CLAUDE")

if [ -z "$agents_slugs" ]; then
  fail "no hay marcadores sync-start en $AGENTS"
elif [ "$agents_slugs" != "$claude_slugs" ]; then
  fail "los bloques marcados no coinciden entre ambos archivos:"
  diff <(echo "$agents_slugs") <(echo "$claude_slugs") \
    | sed 's/^/      /' >&2
else
  while IFS= read -r slug; do
    for f in "$AGENTS" "$CLAUDE"; do
      if ! grep -qF "<!-- sync-end: $slug -->" "$f"; then
        fail "$slug: falta el marcador sync-end en $f"
        continue 2
      fi
    done

    a_block=$(extract_block "$AGENTS" "$slug")
    c_block=$(extract_block "$CLAUDE" "$slug")

    if [ -z "$a_block" ]; then
      fail "$slug: bloque vacío (¿marcadores en orden invertido?)"
    elif [ "$a_block" = "$c_block" ]; then
      ok "$slug ($(printf '%s\n' "$a_block" | wc -l | tr -d ' ') líneas)"
    else
      fail "$slug: los bloques divergen"
      diff <(printf '%s\n' "$c_block") <(printf '%s\n' "$a_block") \
        | sed "s/^/      /" >&2
    fi
  done <<< "$agents_slugs"
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$failures" -eq 0 ]; then
  printf '✓ Documentación consistente.\n'
  exit 0
fi

printf '✗ %d comprobación(es) fallida(s).\n' "$failures"
printf 'Ver scripts/check_docs.sh para qué verifica cada bloque y por qué.\n'
exit 1
