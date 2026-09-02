#!/usr/bin/env bash
# Fail when any `file:line` in the ARCHITECTURE.md §3 anatomy table no longer points at the line
# that declares its symbol. PLAN.md §11: "every edit pass that shifts line numbers re-derives
# every file:line before commit".
#
# The table §3 holds is parsed by column, so the shape is part of the contract:
#
#     | Concern | Symbol | Declared at | Notes |
#     |---|---|---|---|
#     | Refresh lifecycle | `RefreshCoordinator` | `Sources/BranchBarCore/RefreshCoordinator.swift:8` | … |
#
# For every data row the script reads the named line of the named file and asserts that the
# backticked symbol appears on it as a whole word. Every stale row is listed before the script
# exits non-zero, so one run names every fix rather than the first one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ROOT/ARCHITECTURE.md"
SECTION="## §3"
HEADER='| Concern | Symbol | Declared at | Notes |'

[ -f "$DOC" ] || { echo "doc-refs: missing $DOC" >&2; exit 1; }

BLOCK="$(awk -v section="$SECTION" '
    index($0, section) == 1 { inside = 1; next }
    inside && /^## / { inside = 0 }
    inside { print }
' "$DOC")"

[ -n "$BLOCK" ] || { echo "doc-refs: $DOC has no '$SECTION' section" >&2; exit 1; }

printf '%s\n' "$BLOCK" | grep -qF "$HEADER" || {
    echo "doc-refs: the §3 table header must be exactly:" >&2
    echo "  $HEADER" >&2
    exit 1
}

rows=0
stale=0

# Data rows only: the header itself and the |---|---| separator carry no reference.
while IFS= read -r line; do
    [ "$line" = "$HEADER" ] && continue
    case "$line" in
        '|'*) ;;
        *) continue ;;
    esac
    # The |---|---| separator carries no letters and so no claim about the code.
    case "$line" in
        *[A-Za-z]*) ;;
        *) continue ;;
    esac

    symbol="$(printf '%s' "$line" | awk -F'|' '{ print $3 }' | tr -d ' `')"
    reference="$(printf '%s' "$line" | awk -F'|' '{ print $4 }' | tr -d ' `')"
    concern="$(printf '%s' "$line" | awk -F'|' '{ print $2 }' | sed 's/^ *//; s/ *$//')"

    # A row with no reference is a section divider inside the table, not a claim about the code.
    [ -n "$reference" ] || continue
    rows=$((rows + 1))

    file="${reference%:*}"
    number="${reference##*:}"

    if [ -z "$symbol" ]; then
        echo "doc-refs: STALE  $concern: no backticked symbol in the Symbol column" >&2
        stale=$((stale + 1))
        continue
    fi
    case "$number" in
        ''|*[!0-9]*)
            echo "doc-refs: STALE  $concern: '$reference' is not a file:line reference" >&2
            stale=$((stale + 1))
            continue
            ;;
    esac
    if [ ! -f "$ROOT/$file" ]; then
        echo "doc-refs: STALE  $concern: $file does not exist" >&2
        stale=$((stale + 1))
        continue
    fi

    text="$(sed -n "${number}p" "$ROOT/$file")"
    if [ -z "$text" ]; then
        echo "doc-refs: STALE  $symbol: $file has no line $number" >&2
        stale=$((stale + 1))
        continue
    fi
    if ! printf '%s\n' "$text" | grep -qw -- "$symbol"; then
        echo "doc-refs: STALE  $symbol: $file:$number reads '$(printf '%s' "$text" | sed 's/^ *//')'" >&2
        stale=$((stale + 1))
    fi
done <<EOF
$BLOCK
EOF

if [ "$rows" -eq 0 ]; then
    echo "doc-refs: the §3 table has no rows to check" >&2
    exit 1
fi

if [ "$stale" -gt 0 ]; then
    echo "doc-refs: $stale of $rows anatomy rows are stale; re-derive them and run again" >&2
    exit 1
fi

echo "doc-refs: $rows anatomy rows in ARCHITECTURE.md §3 point at their symbols"
