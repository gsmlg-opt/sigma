# Sigma Code Review Remediation

Date: 2026-06-25

Scope: follow-up implementation for the 2026-06-25 security/correctness review. Work was done on `codex/fix-review-findings` using subagent-driven implementation, with spec review and code-quality review after each task.

## Verification

- `devenv shell -- mix test` passed: 80 tests, 0 failures.
- `devenv shell -- mix format --check-formatted` passed.
- `devenv shell -- mix compile --warnings-as-errors` passed.
- `MIX_ENV=prod SECRET_KEY_BASE=... PHX_SERVER=true PORT=4599 devenv shell -- mix eval 'IO.inspect(Application.get_env(:sigma_web, Sigma.Web.Endpoint)[:server])'` passed and printed `true`.
- `mcp__gitnexus.detect_changes(scope: "compare", base_ref: "main")` returned no changed symbols due the current Sigma/GitNexus indexing limitation; direct diffs, subagent reviews, and Mix verification were used as the source of truth.

Known verification noise: full web tests still emit existing Phoenix LiveView missing-form-id warnings in `HomeLive`, `ProjectSettingsLive`, and `SessionLive`. The new worktree-name form warning from this branch was fixed.

## Fixed In This Branch

| Finding | Status | Commit |
| --- | --- | --- |
| [P1] Production config cannot load | Fixed by adding `config/prod.exs` and enabling production endpoint server config through runtime env. | `bd4f39b` |
| [P2] Release runtime config does not enable the HTTP server | Fixed with `server: System.get_env("PHX_SERVER", "true") in ["1", "true", "TRUE"]`. | `bd4f39b` |
| [P1] Distinct repositories can share the same session directory | Fixed with bijective URL-safe Base64 repository storage keys plus legacy migration handling. | `6e97f3a` |
| [P1] Project path save can move sessions before failing | Fixed by validating destination conflicts before moving session storage and handling migration conflicts. | `6e97f3a` |
| [P1] Repository routes trust arbitrary Base64 paths | Fixed by resolving repository routes through `RepoManager` before side effects in repository, session, new-session, hooks, settings, and skills LiveViews. | `b31bb8b`, `d87f30f` |
| [P1] Session identity collides across repositories | Fixed by qualifying LiveView session/log topics and log buffers with repository identity. | `e1f6757` |
| [P1] Fork/rename loses session metadata | Fixed with metadata-aware session file operations for rename, delete, fork, and repository-list deletes. | `922e11d`, `8c9f3f7` |
| [P2] Session rename/delete/fork trust client-provided path fragments | Fixed with basename-only session id validation and server-side session file helpers, including RepositoryLive delete events. | `922e11d`, `8c9f3f7` |
| [P1] Worktree session creation ignores git failure and accepts escaping names | Fixed by validating branch/name/path/root/final target, checking `git worktree add`, and writing session files only after success. | `323d86b` |

## Implementation Notes

### Production Config

`config/prod.exs` now exists, so `MIX_ENV=prod` no longer fails while importing environment config. `runtime.exs` now sets the endpoint server flag from `PHX_SERVER`, defaulting to enabled for production releases.

### Repository Storage Keys

Repository session directories now use a collision-safe Base64 URL key. The migration code keeps legacy directory discovery and handles conflicts instead of silently merging unrelated repositories.

### Route Gating

Repository-scoped LiveViews reject invalid, unknown, or unregistered repository route params before creating session directories, starting session processes, listing sessions, opening shell surfaces, reading project skills, reading/saving project hooks, or showing project settings.

### Log And PubSub Identity

Live session topics and log buffers are now repository-qualified. Runtime session ids remain stable for routes and persisted records, while log/session PubSub identity includes the repository key to avoid cross-repo event leakage.

### Session File Operations

`Sigma.Session.SessionFiles` centralizes `.jsonl` plus `.meta.json` operations. Rename, delete, fork, and repository-list deletes now validate session ids, move or remove metadata with JSONL, preserve metadata on partial failure, and avoid overwriting existing records.

### Worktree Creation

`NewSessionLive` now fails closed for worktree sessions:

- missing, forged, or stale branches are rejected before `git worktree add`
- names must be basename-only and match the allowed character set
- expanded paths must remain under `<repo>/.trees`
- symlinked or non-directory `.trees` roots are rejected
- existing final target paths, including symlinks, are rejected by exclusive `File.mkdir/1`
- `git worktree add` status is checked before writing metadata or JSONL
- tests cover invalid names, missing/forged/stale branches, git failure, success, symlinked roots, and symlinked final targets

Residual note: filesystem validation is fail-closed for pre-existing symlinks and existing target paths, but it is not intended to be a fully race-free defense against a same-user process actively swapping paths between checks.

## Still Open From The Review

These original review findings were not in this fix plan and remain open:

- [P1] Secrets are saved with default file permissions.
- [P1] Missing permission policy silently allows tools.
- [P1] Glob inputs bypass the cwd sandbox.
- [P1] Permission hooks can fail open on stdin/timeout.
- [P1] Parallel tool batches can block forever.
- [P1] Agent tool-use loop has no round budget.
- [P2] JSONL replay interns untrusted strings as atoms.
- [P2] CRLF-framed SSE is not decoded.
- [P2] Persisted system messages can crash provider transformation.
- [P2] Malformed streamed tool JSON becomes executable empty args.
- [P2] Persistence callback failures can tear down the session subtree.
- [P2] PostToolUse halt outcomes are ignored.
- [P2] Bash and hook output collection is unbounded.
- [P3] Source parity contract depends on absent `./source`.

## Commits

- `bd4f39b` - `fix(config): add production boot config`
- `6e97f3a` - `fix(session): make repository storage keys collision-safe`
- `b31bb8b` - `fix(web): gate repository routes through registry`
- `e1f6757` - `fix(session): qualify live session log routing`
- `922e11d` - `fix(session): make session files metadata-aware`
- `323d86b` - `fix(session): fail closed on worktree creation`
- `d87f30f` - `fix(web): gate project routes through repo registry`
- `8c9f3f7` - `fix(web): delete repository sessions safely`
