#!/usr/bin/env bash
# Install repo-local git hooks that strip Cursor Agent commit attribution.
# Safe to re-run. Only sets *local* core.hooksPath (never global).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ ! -d .git ]]; then
  echo "error: not a git working tree: $root" >&2
  exit 1
fi

chmod +x .githooks/strip-cursor-coauthor.sh \
  .githooks/prepare-commit-msg \
  .githooks/commit-msg

git config --local core.hooksPath .githooks
echo "Installed: core.hooksPath=.githooks (local)"
echo "Hooks strip Co-authored-by: Cursor <cursoragent@cursor.com> from commit messages."
echo "Also disable Cursor Attribution in IDE (Git & PRs / Agent) and CLI cli-config.json — see docs/agents/cursor-commit-attribution.md"
