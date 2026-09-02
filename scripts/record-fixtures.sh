#!/bin/bash
# Records every frozen invocation in PLAN.md §5 against real repos, so no model ever
# transcribes git or gh output (PLAN.md §3: "Fixtures are recorded, not transcribed").
#
# Run it with `make record-fixtures`. It rewrites Tests/BranchBarCoreTests/Fixtures/recorded-*
# and nothing else; `synthetic-*` files are hand-written and are never touched here.
#
# It exits non-zero when an invocation that must produce rows produces empty stdout, printing
# the offending command — that is Gate 1.1's criterion, and it is why a frozen command that
# silently stopped returning rows (as `git reflog show --` does) cannot survive a re-record.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/Tests/BranchBarCoreTests/Fixtures"
mkdir -p "$FIXTURES"

# PLAN.md §2: /usr/bin/git 2.39.5 is what NYT will have. Homebrew's 2.52 is on Hannah's PATH
# and is deliberately not used, so the fixtures match the oldest supported git.
GIT="${BRANCHBAR_RECORD_GIT:-/usr/bin/git}"
GH="${BRANCHBAR_RECORD_GH:-$(command -v gh || true)}"

# The two repos PLAN.md §7 names. Repo A has 3 local branches, many origin/claude/* refs, and
# 17 PRs; repo B is this one, whose origin/main reflog has push lines from its first push.
REPO_A="${BRANCHBAR_RECORD_REPO_A:-$HOME/hannah-personal-agent}"
REPO_B="${BRANCHBAR_RECORD_REPO_B:-$ROOT}"
GH_SLUG="${BRANCHBAR_RECORD_SLUG:-github.com/hannahstulberg/hannah-personal-agent}"
GH_HOST="${BRANCHBAR_RECORD_HOST:-github.com}"
# A head that is known to have a PR, so the per-head fallback fixture has rows.
GH_HEAD="${BRANCHBAR_RECORD_HEAD:-allison-bachelorette-itinerary-pdf}"

JSON_FIELDS='number,url,state,isDraft,reviewDecision,mergedAt,updatedAt,baseRefName,headRefName,headRefOid,headRepositoryOwner,mergeCommit'

FAILURES=()
WRITTEN=0

fail() { FAILURES+=("$1"); printf 'FAIL  %s\n' "$1" >&2; }
note() { printf '      %s\n' "$1"; }

# record <output file> <"rows"|"may-be-empty"> <command...>
#
# stdout is redirected straight into the fixture so the bytes are exactly what the command
# wrote, trailing newline included: a parser that only ever sees a fixture with the newline
# stripped is not tested against what git actually prints.
record() {
  local name="$1"; local out="$FIXTURES/$1"; shift
  local expectation="$1"; shift
  local status

  "$@" > "$out" 2>/dev/null
  status=$?
  WRITTEN=$((WRITTEN + 1))

  local shown="$*"
  local bytes
  bytes="$(wc -c < "$out" | tr -d ' ')"

  if [ "$expectation" = "rows" ]; then
    if [ $status -ne 0 ]; then
      fail "exit $status, expected rows: $shown"
      return
    fi
    # An empty stdout where a row is expected is a Gate 1.1 failure, not a warning. For the
    # --json invocations the empty answer is the two-byte `[]`, so check that shape too;
    # otherwise a per-head query that silently stopped matching would record a useless fixture.
    if [ "$bytes" -eq 0 ]; then
      fail "empty stdout, expected rows: $shown"
      return
    fi
    if [ "$(tr -d '[:space:]' < "$out")" = "[]" ]; then
      fail "empty JSON array, expected rows: $shown"
      return
    fi
  fi
  note "$(printf '%-58s %6s bytes  %s' "$name" "$bytes" "$shown")"
}

# copy_reflog <output file> <repo> <ref path under logs/refs/remotes/> <"required"|"optional">
copy_reflog() {
  local out="$FIXTURES/$1" repo="$2" ref="$3" requirement="$4"
  local common src
  common="$("$GIT" -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  src="$common/logs/refs/remotes/$ref"
  if [ ! -f "$src" ]; then
    if [ "$requirement" = "required" ]; then fail "reflog file missing: $src"; fi
    note "$(printf '%-58s (absent, not recorded)' "$1")"
    return
  fi
  cp "$src" "$out"
  WRITTEN=$((WRITTEN + 1))
  note "$(printf '%-58s %6s bytes  %s' "$1" "$(wc -c < "$out" | tr -d ' ')" "$src")"
}

if [ ! -x "$GIT" ]; then
  echo "record-fixtures: $GIT is not executable; set BRANCHBAR_RECORD_GIT" >&2
  exit 1
fi

echo "record-fixtures"
echo "  git : $GIT  ($("$GIT" --version))"
echo "  gh  : ${GH:-<not found>}  $([ -n "$GH" ] && "$GH" --version 2>/dev/null | head -1)"
echo

# PLAN.md §5 git env. LC_ALL=C keeps the output parseable; GIT_OPTIONAL_LOCKS=0 stops a read
# from taking index.lock while the user is mid-commit in another tool.
export LC_ALL=C GIT_OPTIONAL_LOCKS=0

for pair in "hannah-personal-agent:$REPO_A" "branchbar:$REPO_B"; do
  label="${pair%%:*}"
  repo="${pair#*:}"
  echo "  --- $label ($repo)"
  if [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then
    fail "not a git repo: $repo"
    continue
  fi

  record "recorded-$label-for-each-ref-heads.txt" rows \
    "$GIT" -C "$repo" for-each-ref \
    --format='%(refname)%1f%(objectname)%1f%(committerdate:unix)%1f%(upstream:short)%1f%(upstream:remotename)%1f%(upstream:track,nobracket)%1f%(HEAD)' \
    -- refs/heads

  record "recorded-$label-worktree-list.txt" rows \
    "$GIT" -C "$repo" worktree list --porcelain

  record "recorded-$label-for-each-ref-remotes.txt" rows \
    "$GIT" -C "$repo" for-each-ref \
    --format='%(refname)%1f%(objectname)%1f%(committerdate:unix)' \
    -- refs/remotes/

  record "recorded-$label-rev-parse.txt" rows \
    "$GIT" -C "$repo" rev-parse --path-format=absolute --git-common-dir --show-toplevel

  record "recorded-$label-config-remote-origin-url.txt" rows \
    "$GIT" -C "$repo" config --get remote.origin.url

  # The secondary fallback. NO `--` separator: with one, 2.39.5 and 2.52 both return zero rows
  # and exit 0 (CLAUDE.md "Rules that came from real bugs"). An empty result here would mean the
  # separator crept back in.
  record "recorded-$label-reflog-show-origin-main.txt" rows \
    "$GIT" -C "$repo" reflog show --date=unix --format='%gd%x1f%gs%x1f%H' refs/remotes/origin/main
  echo
done

echo "  --- reflog files (what this clone observed)"
# Has `update by push` lines.
copy_reflog "recorded-reflog-hannah-personal-agent-origin-main.txt" "$REPO_A" "origin/main" required
# Exists and is 0 bytes — the case that made "reflog files can exist and be empty" a rule.
copy_reflog "recorded-reflog-hannah-personal-agent-origin-updates-3-29-26.txt" "$REPO_A" "origin/updates-3-29-26" required
copy_reflog "recorded-reflog-branchbar-origin-main.txt" "$REPO_B" "origin/main" required
echo

if [ -z "$GH" ]; then
  fail "gh not found; the gh fixtures were not recorded"
else
  echo "  --- gh ($GH_SLUG)"
  # PLAN.md §5 gh env, frozen after the codex review: a GUI-launched gh must never prompt,
  # never page, never colorize, and never check for updates.
  export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_PAGER=cat NO_COLOR=1 CLICOLOR=0

  record "recorded-gh-auth-status-$GH_HOST.txt" rows \
    "$GH" auth status --hostname "$GH_HOST"

  record "recorded-gh-pr-list-hannah-personal-agent.json" rows \
    "$GH" pr list --repo "$GH_SLUG" --state all --limit 100 --json "$JSON_FIELDS"

  record "recorded-gh-pr-list-head-hannah-personal-agent.json" rows \
    "$GH" pr list --repo "$GH_SLUG" --state all --head "$GH_HEAD" --limit 5 --json "$JSON_FIELDS"

  # Gate 1.1 allows `[]` here: an author with no open PRs is a real, honest answer.
  record "recorded-gh-pr-list-author-me-hannah-personal-agent.json" may-be-empty \
    "$GH" pr list --repo "$GH_SLUG" --state open --author @me --limit 100 --json "$JSON_FIELDS"
  echo
fi

# `gh auth status` writes its report to stderr, not stdout, so the `rows` check above cannot
# see it. Re-record it merged, and require the merged file to be non-empty.
if [ -n "$GH" ]; then
  "$GH" auth status --hostname "$GH_HOST" > "$FIXTURES/recorded-gh-auth-status-$GH_HOST.txt" 2>&1
  if [ ! -s "$FIXTURES/recorded-gh-auth-status-$GH_HOST.txt" ]; then
    fail "empty output: gh auth status --hostname $GH_HOST"
  fi
fi

echo "recorded $WRITTEN file(s) into $FIXTURES"
if [ ${#FAILURES[@]} -gt 0 ]; then
  echo
  echo "record-fixtures FAILED (${#FAILURES[@]}):" >&2
  for f in "${FAILURES[@]}"; do echo "  - $f" >&2; done
  exit 1
fi
echo "all frozen invocations returned the documented shape"
