# Cursor commit attribution (Co-authored-by)

## Problem

Agent-created commits were getting this trailer injected automatically:

```text
Co-authored-by: Cursor <cursoragent@cursor.com>
```

Project user rules forbid that trailer. Recent examples included `dc309ec`, `ef16935`, `9dd7f38` (and others before a `commit-tree` rewrite of `ab41ad0`).

## Root cause

**Not** a repo hook, commit template, or `trailer.*` git config.

This clone had:

- `.git/hooks/` — only `*.sample` files (no active `prepare-commit-msg` / `commit-msg`)
- no `commit.template`
- no `core.hooksPath`
- no repo matches for `cursoragent@cursor.com`

Injection comes from **Cursor Agent attribution** when the agent runs `git commit` (typically via `--trailer`). On this machine it was enabled in CLI config:

```json
// ~/.cursor/cli-config.json
"attribution": {
  "attributeCommitsToAgent": true,
  "attributePRsToAgent": true
}
```

IDE Agent has a separate toggle (Settings → **Git & PRs** / **Agent** → **Attribution**). Opt-out is per surface; turning off one does not cover the other. Cloud/background agents may still attribute independently.

## Repo fix (durable)

Checked-in hooks under `.githooks/` strip the Cursor co-author line (and `Made-with: Cursor` if present) in both `prepare-commit-msg` and `commit-msg`.

Activate once per clone:

```bash
./scripts/install-git-hooks.sh
```

That sets **local** `core.hooksPath=.githooks` only (does not change global git config or `user.name` / `user.email`).

## Preferred: disable at source

1. **IDE:** Cursor Settings → Git & PRs (or Agent) → Attribution → turn off commit (and PR if undesired).
2. **CLI:** in `~/.cursor/cli-config.json` set:

```json
"attribution": {
  "attributeCommitsToAgent": false,
  "attributePRsToAgent": false
}
```

The hooks remain a safety net if attribution is left on or re-enabled.

## Workarounds without hooks

- Commit without Cursor’s trailer flag, or amend/strip before push.
- Last resort rewrite: `git commit-tree` / filter (do **not** rewrite shared history unless explicitly requested).

## Verify

```bash
./scripts/install-git-hooks.sh
git checkout -b _tmp/cursor-trailer-check
git commit --allow-empty -m "test: cursor trailer strip" \
  --trailer "Co-authored-by: Cursor <cursoragent@cursor.com>"
git log -1 --format=%B
# expect: no Co-authored-by line
git checkout -
git branch -D _tmp/cursor-trailer-check
```
