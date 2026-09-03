#!/usr/bin/env bash
# Strip Cursor Agent commit attribution trailers from a commit message file.
# Invoked by prepare-commit-msg / commit-msg. See docs/agents/cursor-commit-attribution.md.
set -euo pipefail

msg_file="${1:-}"
if [[ -z "$msg_file" || ! -f "$msg_file" ]]; then
  exit 0
fi

tmp="$(mktemp)"
# Portable: no GNU/BSD sed -i differences.
grep -v -E \
  -e '^[[:space:]]*Co-authored-by:[[:space:]]*Cursor[[:space:]]*<cursoragent@cursor\.com>[[:space:]]*$' \
  -e '^[[:space:]]*Made-with:[[:space:]]*Cursor[[:space:]]*$' \
  "$msg_file" >"$tmp" || true
mv "$tmp" "$msg_file"
