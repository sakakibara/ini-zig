#!/bin/bash
# Differential harness: compare ini-zig output against reference tools.
#
# Usage: tools/run_differential.sh [generic|gitconfig]
# Default: runs both dialects.
#
# Prerequisites:
#   - zig-out/bin/differential (built via: zig build install)
#   - python3 with configparser (stdlib)
#   - git (for gitconfig dialect only)
#
# Output: MATCH / MISMATCH / SKIP lines to stdout.
# Exit 1 if any MISMATCH is found.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CORPUS="$REPO_ROOT/tests/corpus"
DIFF="$REPO_ROOT/zig-out/bin/differential"
ORACLE="$REPO_ROOT/tools/configparser_oracle.py"

if [ ! -x "$DIFF" ]; then
  echo "ERROR: differential binary not found at $DIFF"
  echo "Build it with: zig build install"
  exit 1
fi

DIALECT="${1:-all}"
MISMATCHES=0

# Python helper: normalize git --list output to sorted "key = escaped_value" lines.
# Handles multi-line values (decoded newlines) and bare keys (no = sign).
GIT_NORMALIZER=$(cat <<'PYEOF'
import sys

def esc(v):
    return v.replace('\\','\\\\').replace('\n','\\n').replace('\t','\\t')

raw = sys.stdin.read()
entries = []
cur_key = None
cur_val_parts = []

def flush():
    global cur_key, cur_val_parts
    if cur_key is not None:
        val = '\n'.join(cur_val_parts)
        entries.append((cur_key, esc(val)))
        cur_key = None
        cur_val_parts = []

for line in raw.splitlines():
    if '=' in line:
        flush()
        k, _, v = line.partition('=')
        cur_key = k
        cur_val_parts = [v]
    elif cur_key is not None:
        # continuation of a multi-line decoded value
        cur_val_parts.append(line)
    elif line.strip():
        flush()
        entries.append((line.strip(), ''))
flush()

# Stable sort by path; preserves insertion order for equal paths (multi-value keys).
entries.sort(key=lambda kv: kv[0])
for k, v in entries:
    print(f'{k} = {v}')
PYEOF
)

run_generic() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP (python3 not found): generic section"
    return 0
  fi
  echo "=== generic/valid ==="
  for f in "$CORPUS/generic/valid"/*.ini; do
    name="$(basename "$f")"
    our="$("$DIFF" generic "$f")"
    py_out="$(python3 "$ORACLE" "$f" 2>/tmp/_py_err)"
    py_exit=$?
    py_err="$(cat /tmp/_py_err)"
    if echo "$py_err" | grep -q "SKIP"; then
      echo "SKIP (configparser no global-key support): $name"
      continue
    fi
    if [ "$py_exit" -ne 0 ]; then
      echo "PY_ERROR: $name: $py_err"
      MISMATCHES=$((MISMATCHES + 1))
      continue
    fi
    diff_out="$(diff <(printf '%s\n' "$our") <(printf '%s\n' "$py_out") || true)"
    if [ -z "$diff_out" ]; then
      echo "MATCH: $name"
    else
      echo "MISMATCH: $name"
      printf '%s\n' "$diff_out"
      MISMATCHES=$((MISMATCHES + 1))
    fi
  done
}

run_gitconfig() {
  if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP (git or python3 not found): gitconfig section"
    return 0
  fi
  echo "=== gitconfig/valid ==="
  for f in "$CORPUS/gitconfig/valid"/*.gitconfig; do
    name="$(basename "$f")"
    our="$("$DIFF" gitconfig "$f")"
    git_raw="$(git config --list --file "$f" 2>/dev/null || true)"
    git_norm="$(printf '%s\n' "$git_raw" | python3 -c "$GIT_NORMALIZER")"
    diff_out="$(diff <(printf '%s\n' "$our") <(printf '%s\n' "$git_norm") || true)"
    if [ -z "$diff_out" ]; then
      echo "MATCH: $name"
    else
      echo "MISMATCH: $name"
      printf '%s\n' "$diff_out"
      MISMATCHES=$((MISMATCHES + 1))
    fi
  done
}

case "$DIALECT" in
  generic) run_generic ;;
  gitconfig) run_gitconfig ;;
  all) run_generic; run_gitconfig ;;
  *) echo "unknown dialect: $DIALECT"; exit 1 ;;
esac

if [ "$MISMATCHES" -gt 0 ]; then
  echo "RESULT: $MISMATCHES mismatch(es) found"
  exit 1
else
  echo "RESULT: all fixtures match"
fi
