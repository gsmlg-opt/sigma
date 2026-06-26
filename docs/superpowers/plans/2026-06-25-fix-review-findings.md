# Fix Review Findings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve the security, correctness, and release findings documented in `review.md`.

**Architecture:** Split the work into small, independently testable patches. Fix release/runtime issues first, then establish safe repository/session identity primitives, then harden tool execution and provider/runtime edge cases. Avoid broad UI redesigns and keep existing LiveView and DuskMoon patterns.

**Tech Stack:** Elixir umbrella, Phoenix LiveView, ExUnit, BEAM/OTP supervisors, `devenv shell -- mix ...`, existing `Sigma.Session`, `Sigma.Web`, `Sigma.Coding`, `Sigma.Tools`, `Sigma.Ai`, and `Sigma.Agent` modules.

---

## Execution Notes

- Work in a dedicated worktree before editing code:

```bash
git worktree add .trees/codex/fix-review-findings -b codex/fix-review-findings
cd .trees/codex/fix-review-findings
```

- Commit each task or small task group separately.
- Use `devenv shell -- mix ...`; bare `mix` is not available in the parent shell.
- Keep `review.md` as the source of truth for why each change exists.
- Run `npx gitnexus analyze` after larger code edits if GitNexus reports staleness.

## Task 1: Fix production boot configuration

**Findings covered:** production config missing, release HTTP server not enabled.

**Files:**
- Create: `config/prod.exs`
- Modify: `config/runtime.exs`
- Test: add a focused release/config smoke test if practical, otherwise document the exact prod commands in this task.

- [ ] Add `config/prod.exs` with production-safe endpoint and logger defaults. Keep secrets in `runtime.exs`.

```elixir
import Config

config :sigma_web, Sigma.Web.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  check_origin: false

config :logger, level: :info
```

- [ ] Update `config/runtime.exs` so prod releases start the endpoint server when `PHX_SERVER=true` or unconditionally for release usage.

```elixir
if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by running: mix phx.gen.secret
      """

  config :sigma_web, Sigma.Web.Endpoint,
    server: System.get_env("PHX_SERVER", "true") in ["1", "true", "TRUE"],
    http: [
      port: String.to_integer(System.get_env("PORT") || "4580"),
      transport_options: [socket_opts: [:inet6]]
    ],
    secret_key_base: secret_key_base
end
```

- [ ] Verify the missing-file failure is gone.

```bash
SECRET_KEY_BASE="$(devenv shell -- mix phx.gen.secret)" MIX_ENV=prod devenv shell -- mix eval ':ok'
```

Expected: exits 0.

- [ ] Verify production compile.

```bash
SECRET_KEY_BASE="$(devenv shell -- mix phx.gen.secret)" MIX_ENV=prod devenv shell -- mix compile
```

Expected: exits 0.

- [ ] Run regression suite.

```bash
devenv shell -- mix test
```

Expected: 0 failures.

## Task 2: Make repository session storage keys collision-safe

**Findings covered:** distinct repositories can share the same session directory.

**Files:**
- Modify: `apps/sigma_session/lib/sigma_session/config_manager.ex`
- Test: `apps/sigma_session/test/sigma_session/config_manager_test.exs`

- [ ] Add tests proving the current path examples do not collide.

```elixir
test "sessions_dir uses a collision-safe repository key" do
  first = ConfigManager.sessions_dir("/tmp/a-b")
  second = ConfigManager.sessions_dir("/tmp/a/b")

  assert first != second
end
```

- [ ] Add a URL-safe Base64 repository key helper.

```elixir
def repository_key(cwd) when is_binary(cwd) do
  cwd
  |> Path.expand()
  |> Base.url_encode64(padding: false)
end
```

- [ ] Change `sessions_dir/1` to use the new key for new writes.

```elixir
def sessions_dir(cwd) do
  Path.join(sessions_root(), repository_key(cwd))
end
```

- [ ] Preserve read access to legacy directories with an explicit migration helper.

```elixir
def legacy_sessions_dir(cwd), do: Path.join(sessions_root(), pi_safe_path(cwd))

def ensure_sessions_dir(cwd) do
  new_dir = sessions_dir(cwd)
  old_dir = legacy_sessions_dir(cwd)

  cond do
    File.dir?(new_dir) ->
      File.mkdir_p!(new_dir)
      new_dir

    File.dir?(old_dir) ->
      File.mkdir_p!(Path.dirname(new_dir))
      File.rename(old_dir, new_dir)
      new_dir

    true ->
      File.mkdir_p!(new_dir)
      new_dir
  end
end
```

- [ ] Replace direct create-and-write call sites that are meant to initialize storage with `ensure_sessions_dir/1`; keep pure path lookups on `sessions_dir/1`.

Expected call sites to inspect:
- `apps/sigma_web/lib/sigma_web/live/repository_live.ex`
- `apps/sigma_web/lib/sigma_web/live/session_live.ex`
- `apps/sigma_web/lib/sigma_web/live/new_session_live.ex`
- `apps/sigma_web/lib/sigma_web/live/project_settings_live.ex`

- [ ] Run focused tests.

```bash
devenv shell -- mix test apps/sigma_session/test/sigma_session/config_manager_test.exs apps/sigma_web/test/sigma_web/live/repository_live_test.exs apps/sigma_web/test/sigma_web/live/session_live_test.exs
```

Expected: 0 failures.

## Task 3: Gate repository routes through the repo registry

**Findings covered:** repository routes trust arbitrary Base64 paths.

**Files:**
- Modify: `apps/sigma_web/lib/sigma_web/live/repository_live.ex`
- Modify: `apps/sigma_web/lib/sigma_web/live/session_live.ex`
- Modify: `apps/sigma_web/lib/sigma_web/live/new_session_live.ex`
- Test: `apps/sigma_web/test/sigma_web/live/repository_live_test.exs`
- Test: `apps/sigma_web/test/sigma_web/live/session_live_test.exs`
- Test: `apps/sigma_web/test/sigma_web/live/new_session_live_test.exs`

- [ ] Add route tests for an existing local path that has not been added through `RepoManager.add_repo/2`.

```elixir
test "rejects unregistered repository route", %{conn: conn} do
  path = System.tmp_dir!()
  encoded = Base.url_encode64(path, padding: false)

  {:error, {:redirect, %{to: "/"}}} = live(conn, "/repository/#{encoded}")
end
```

- [ ] Add a small private helper in each LiveView or a shared web helper if repetition grows.

```elixir
defp fetch_registered_repo(encoded_repository) do
  with {:ok, workdir} <- Base.url_decode64(encoded_repository, padding: false),
       %{} = repo <- RepoManager.get_repo(workdir) do
    {:ok, Path.expand(repo["path"]), repo}
  else
    _ -> {:error, :unknown_repository}
  end
end
```

- [ ] Use the helper at the top of each repository route mount before creating session directories, starting agents, or opening shells.

- [ ] Redirect unknown repositories to `/` with a clear flash.

- [ ] Run focused tests.

```bash
devenv shell -- mix test apps/sigma_web/test/sigma_web/live/repository_live_test.exs apps/sigma_web/test/sigma_web/live/session_live_test.exs apps/sigma_web/test/sigma_web/live/new_session_live_test.exs
```

Expected: 0 failures.

## Task 4: Use repository-qualified session and log identities

**Findings covered:** session identity collides across repositories.

**Files:**
- Modify: `apps/sigma_web/lib/sigma_web/live/session_live.ex`
- Modify: `apps/sigma_logs/lib/sigma_logs.ex`
- Modify: `apps/sigma_logs/lib/sigma_logs/buffer_supervisor.ex`
- Modify: `apps/sigma_logs/lib/sigma_logs/buffer.ex`
- Test: `apps/sigma_web/test/sigma_web/live/session_live_test.exs`
- Test: `apps/sigma_logs/test/sigma_logs/buffer_test.exs`

- [ ] Add a deterministic session topic helper in `SessionLive`.

```elixir
defp session_topic(repo_key, session_id), do: "session:#{repo_key}:#{session_id}"
defp logs_topic(repo_key, session_id), do: "sigma:logs:#{repo_key}:#{session_id}"
```

- [ ] Compute `repo_key = ConfigManager.repository_key(workdir)` in `mount/3`.

- [ ] Subscribe and broadcast with the repository-qualified topic.

- [ ] Change `Sigma.Logs` APIs to accept a qualified id while preserving current one-argument call shape for tests.

```elixir
def session_key(repo_key, session_id), do: "#{repo_key}:#{session_id}"
```

- [ ] Update log buffer registry names to use the qualified id.

- [ ] Add tests that two repositories with the same `session_id` do not receive each other's events/logs.

- [ ] Run focused tests.

```bash
devenv shell -- mix test apps/sigma_logs/test apps/sigma_web/test/sigma_web/live/session_live_test.exs
```

Expected: 0 failures.

## Task 5: Make session file operations safe and metadata-aware

**Findings covered:** fork/rename loses metadata, session rename/delete/fork trust client path fragments.

**Files:**
- Create: `apps/sigma_session/lib/sigma_session/session_files.ex`
- Test: `apps/sigma_session/test/sigma_session/session_files_test.exs`
- Modify: `apps/sigma_web/lib/sigma_web/live/session_live.ex`

- [ ] Create `Sigma.Session.SessionFiles` with basename-only id validation.

```elixir
def valid_session_id?(id) when is_binary(id) do
  id not in [".", ".."] and String.match?(id, ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
end
```

- [ ] Add helpers for JSONL and metadata paths that return `{:ok, path}` or `{:error, :invalid_session_id}`.

```elixir
def jsonl_path(sessions_dir, id), do: safe_path(sessions_dir, id, ".jsonl")
def meta_path(sessions_dir, id), do: safe_path(sessions_dir, id, ".meta.json")
```

- [ ] Add `rename/3`, `delete/2`, and `fork/4` helpers that operate on both `.jsonl` and `.meta.json`.

- [ ] Ensure fork copies metadata and rewrites `cwd` only when explicitly requested. For worktree sessions, preserve the original `cwd`, `branch`, `worktree`, and `mcp_server_ids`.

- [ ] Change `SessionLive` handlers to call `SessionFiles` instead of `Path.join/2` with client values.

- [ ] Add tests for `../escape`, slash-containing names, metadata copy on fork, metadata rename, and metadata removal on delete.

- [ ] Run focused tests.

```bash
devenv shell -- mix test apps/sigma_session/test/sigma_session/session_files_test.exs apps/sigma_web/test/sigma_web/live/session_live_test.exs
```

Expected: 0 failures.

## Task 6: Make worktree session creation fail closed

**Findings covered:** worktree creation ignores git failure and accepts escaping names.

**Files:**
- Modify: `apps/sigma_web/lib/sigma_web/live/new_session_live.ex`
- Test: `apps/sigma_web/test/sigma_web/live/new_session_live_test.exs`

- [ ] Add private validation for worktree directory names.

```elixir
defp valid_worktree_name?(name) when is_binary(name) do
  name not in [".", ".."] and
    Path.basename(name) == name and
    String.match?(name, ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
end
```

- [ ] Resolve worktree paths with `Path.expand/1` and verify they remain inside `<repo>/.trees`.

```elixir
trees_root = Path.expand(Path.join(workdir, ".trees"))
worktree_path = Path.expand(Path.join(trees_root, dir_name))

unless String.starts_with?(worktree_path <> "/", trees_root <> "/") do
  {:error, "Invalid worktree name"}
end
```

- [ ] Check `System.cmd/3` result and stop before writing metadata on nonzero exit.

```elixir
case System.cmd("git", ["-C", workdir, "worktree", "add", worktree_path, branch], stderr_to_stdout: true) do
  {_output, 0} -> {worktree_path, true}
  {output, _status} -> {:error, output}
end
```

- [ ] Add LiveView tests that invalid names are rejected and failed git commands do not create `.meta.json` or `.jsonl`.

- [ ] Run focused tests.

```bash
devenv shell -- mix test apps/sigma_web/test/sigma_web/live/new_session_live_test.exs
```

Expected: 0 failures.

## Task 7: Save secret-bearing config with restrictive permissions

**Findings covered:** secrets saved with default file permissions.

**Files:**
- Modify: `apps/sigma_session/lib/sigma_session/config_manager.ex`
- Test: `apps/sigma_session/test/sigma_session/config_manager_test.exs`

- [ ] Add tests that `auth.json` and `mcp.json` are written with mode `0600` and config dir with mode `0700`.

- [ ] Replace `save_json/2` with an atomic write helper.

```elixir
defp save_json(filename, data) do
  dir = get_config_dir()
  path = Path.join(dir, filename)
  tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

  File.mkdir_p!(dir)
  File.chmod(dir, 0o700)
  File.write!(tmp, Jason.encode!(data, pretty: true))
  File.chmod!(tmp, file_mode(filename))
  File.rename!(tmp, path)
  File.chmod!(path, file_mode(filename))
end

defp file_mode(filename) when filename in [@auth_file, @mcp_file], do: 0o600
defp file_mode(_filename), do: 0o644
```

- [ ] Run focused tests.

```bash
devenv shell -- mix test apps/sigma_session/test/sigma_session/config_manager_test.exs
```

Expected: 0 failures.

## Task 8: Fail closed on missing permission policy

**Findings covered:** missing permission policy silently allows tools.

**Files:**
- Modify: `apps/sigma_coding/lib/sigma_coding/permission_interceptor.ex`
- Test: `apps/sigma_coding/test/sigma_coding/permission_test.exs`

- [ ] Add failing tests for unresolved atom and dead pid policies.

```elixir
test "denies when configured permission policy is missing" do
  tool_call = %{name: "bash", arguments: %{}, id: "toolu_1"}
  assert {:deny, _} = PermissionInterceptor.check(tool_call, permission_policy: :missing_policy)
end
```

- [ ] Change policy resolution so presence of the key matters.

```elixir
cond do
  Keyword.has_key?(opts, :permission_policy) ->
    case resolve_policy(Keyword.fetch!(opts, :permission_policy)) do
      {:ok, policy} -> check_policy(policy, tool_call, opts)
      :error -> {:deny, "Permission policy is unavailable for tool: #{tool_call.name}"}
    end

  Keyword.has_key?(opts, :allow_tool) ->
    ...
end
```

- [ ] Wrap `PermissionPolicy.check/2` exits and convert them to deny.

- [ ] Run focused tests.

```bash
devenv shell -- mix test apps/sigma_coding/test/sigma_coding/permission_test.exs
```

Expected: 0 failures.

## Task 9: Enforce sandbox checks for wildcard paths

**Findings covered:** glob inputs bypass cwd sandbox.

**Files:**
- Modify: `apps/sigma_coding/lib/sigma_coding/utils/path_utils.ex`
- Modify: `apps/sigma_tools/lib/sigma_tools/search.ex`
- Modify: `apps/sigma_tools/lib/sigma_tools/find.ex`
- Modify: `apps/sigma_coding/lib/sigma_coding/tools/grep.ex`
- Modify: `apps/sigma_coding/lib/sigma_coding/tools/glob.ex`
- Test: `apps/sigma_tools/test/sigma_tools/search_test.exs`
- Test: `apps/sigma_tools/test/sigma_tools/find_test.exs`
- Test: `apps/sigma_coding/test/sigma_coding/tools/grep_test.exs`
- Test: `apps/sigma_coding/test/sigma_coding/tools/glob_test.exs`

- [ ] Add path utility tests for absolute globs and parent traversal.

- [ ] Add a `safe_wildcard/3` helper that rejects absolute patterns and validates every match with `safe_resolve/2`.

```elixir
def safe_wildcard(pattern, cwd, opts \\ []) do
  with :ok <- reject_unsafe_pattern(pattern),
       expanded = Path.expand(pattern, cwd),
       matches = Path.wildcard(expanded, opts),
       {:ok, safe_matches} <- filter_safe_matches(matches, cwd) do
    {:ok, safe_matches}
  end
end
```

- [ ] Replace direct wildcard expansion in all four tool modules with `PathUtils.safe_wildcard/3`.

- [ ] Add regression tests for:
  - `paths: ["/etc/passwd*"]` rejected in `Sigma.Tools.Search`.
  - `paths: ["../*"]` rejected in `Sigma.Tools.Find`.
  - `glob: "../secret.txt"` rejected in legacy `grep`.
  - `pattern: "../*"` rejected in legacy `glob`.

- [ ] Run focused tests.

```bash
devenv shell -- mix test apps/sigma_tools/test/sigma_tools/search_test.exs apps/sigma_tools/test/sigma_tools/find_test.exs apps/sigma_coding/test/sigma_coding/tools/grep_test.exs apps/sigma_coding/test/sigma_coding/tools/glob_test.exs
```

Expected: 0 failures.

## Task 10: Harden hook execution and outcomes

**Findings covered:** permission hooks fail open on stdin/timeout, PostToolUse halt ignored, hook output unbounded.

**Files:**
- Modify: `apps/sigma_coding/lib/sigma_coding/hooks/runner.ex`
- Modify: `apps/sigma_coding/lib/sigma_coding/hooks/outcome.ex`
- Modify: `apps/sigma_coding/lib/sigma_coding/dispatcher.ex`
- Test: `apps/sigma_coding/test/sigma_coding/hooks/outcome_test.exs`
- Test: `apps/sigma_coding/test/sigma_coding/integration_test.exs`

- [ ] Add tests for an EOF-reading `PreToolUse` hook that denies a tool.

- [ ] Refactor hook execution to feed finite stdin and close it. Prefer an implementation that does not interpolate the hook command into another shell string. If plain `Port` cannot close stdin independently, use a temporary payload file and invoke `/bin/sh` with positional arguments for the payload path and hook command.

```elixir
payload_path = write_payload_file!(payload_json)
Port.open({:spawn_executable, "/bin/sh"}, [
  :binary,
  :exit_status,
  :stderr_to_stdout,
  {:args, ["-c", "cat \"$1\" | sh -c \"$2\"", "sigma-hook", payload_path, spec.command]}
])
```

Use `System.tmp_dir!()` and remove the payload file in `after`.

- [ ] Treat timeout as a distinct result.

```elixir
{:error, :timeout, spec}
```

- [ ] Decode timeout as blocking for `:pre_tool_use` and `:permission_request`; surface as non-blocking warning only for non-permission hook events.

- [ ] Apply output caps during collection, not after process exit.

```elixir
@max_output_bytes 1_000_000
```

- [ ] Change `Dispatcher.apply_post_outcome({:halt, reason}, result)` to return a terminating error or halt tuple that the agent will not treat as a normal tool result.

- [ ] Run focused tests.

```bash
devenv shell -- mix test apps/sigma_coding/test/sigma_coding/hooks/outcome_test.exs apps/sigma_coding/test/sigma_coding/integration_test.exs apps/sigma_coding/test/sigma_coding/dispatcher_test.exs
```

Expected: 0 failures.

## Task 11: Bound bash output and tool batch runtime

**Findings covered:** parallel tool batches block forever, bash output collection unbounded.

**Files:**
- Modify: `apps/sigma_coding/lib/sigma_coding/dispatcher.ex`
- Modify: `apps/sigma_coding/lib/sigma_coding/tools/bash.ex`
- Test: `apps/sigma_coding/test/sigma_coding/dispatcher_test.exs`
- Test: `apps/sigma_coding/test/sigma_coding/tools/bash_test.exs`

- [ ] Add dispatcher tests where one parallel tool sleeps past a short batch timeout while another completes.

- [ ] Add finite defaults.

```elixir
@default_batch_timeout_ms 120_000
@default_bash_timeout_ms 120_000
@max_output_bytes 1_000_000
```

- [ ] Replace `Task.yield_many(:infinity)` with a timeout from opts.

```elixir
timeout = Keyword.get(opts, :batch_timeout_ms, @default_batch_timeout_ms)
tasks |> Task.yield_many(timeout)
```

- [ ] Shut down unfinished tasks with `Task.shutdown(task, :brutal_kill)`.

- [ ] Cap bash output incrementally and send truncated updates.

- [ ] Run focused tests.

```bash
devenv shell -- mix test apps/sigma_coding/test/sigma_coding/dispatcher_test.exs apps/sigma_coding/test/sigma_coding/tools/bash_test.exs
```

Expected: 0 failures.

## Task 12: Add an agent tool-round budget

**Findings covered:** agent tool-use loop has no round budget.

**Files:**
- Modify: `apps/sigma_agent/lib/sigma_agent.ex`
- Test: `apps/sigma_agent/test/sigma_agent_test.exs`
- Test: `apps/sigma_agent/test/sigma_agent/runtime_test.exs`

- [ ] Add a test provider that always returns a tool call and assert the turn stops after the configured limit.

- [ ] Thread a round count through `run_turn_loop/2`.

```elixir
@default_max_tool_rounds 20

defp run_turn_loop(state, tool_round \\ 0) do
  if tool_round >= max_tool_rounds(state) do
    emit(state, {:turn_error, "Maximum tool rounds exceeded."})
    state
  else
    ...
    run_turn_loop(state, tool_round + 1)
  end
end
```

- [ ] Allow tests to override the limit through existing provider/dispatcher opts instead of adding a new public settings UI.

- [ ] Run focused tests.

```bash
devenv shell -- mix test apps/sigma_agent/test/sigma_agent_test.exs apps/sigma_agent/test/sigma_agent/runtime_test.exs
```

Expected: 0 failures.

## Task 13: Harden provider message and stream decoding

**Findings covered:** CRLF SSE, persisted system messages, malformed tool JSON.

**Files:**
- Modify: `apps/sigma_ai/lib/sigma_ai/stream.ex`
- Modify: `apps/sigma_agent/lib/sigma_agent/context_builder.ex`
- Modify: `apps/sigma_agent/lib/sigma_agent/message_transformer.ex`
- Modify: `apps/sigma_ai/lib/sigma_ai/providers/openai.ex`
- Modify: `apps/sigma_ai/lib/sigma_ai/providers/anthropic.ex`
- Test: `apps/sigma_ai/test/sigma_ai/stream_test.exs`
- Test: `apps/sigma_agent/test/sigma_agent/message_transformer_test.exs`
- Test: `apps/sigma_ai/test/sigma_ai/providers/openai_test.exs`
- Test: `apps/sigma_ai/test/sigma_ai/providers/anthropic_test.exs`

- [ ] Add CRLF SSE tests.

```elixir
test "decodes CRLF framed SSE events" do
  chunk = "data: {\"type\":\"message_start\"}\r\n\r\n"
  assert {[_], ""} = Sigma.Ai.Stream.decode("", chunk)
end
```

- [ ] Normalize line endings in `Sigma.Ai.Stream`.

```elixir
data = (buffer <> chunk) |> String.replace("\r\n", "\n")
```

- [ ] Add tests that system messages are merged into context system prompt and not sent as provider message roles.

- [ ] Update `ContextBuilder` or `MessageTransformer` so `:system` messages become part of `context.system` before provider transforms.

- [ ] Add provider tests where malformed tool JSON fails the turn instead of producing `%{}` arguments.

- [ ] Replace `%{}` fallback in both providers with a raised provider error or non-executable error event.

- [ ] Run focused tests.

```bash
devenv shell -- mix test apps/sigma_ai/test/sigma_ai/stream_test.exs apps/sigma_agent/test/sigma_agent/message_transformer_test.exs apps/sigma_ai/test/sigma_ai/providers/openai_test.exs apps/sigma_ai/test/sigma_ai/providers/anthropic_test.exs
```

Expected: 0 failures.

## Task 14: Isolate persistence callback failures

**Findings covered:** persistence callback failures can tear down the session subtree.

**Files:**
- Modify: `apps/sigma_agent/lib/sigma_agent/session_process.ex`
- Modify: `apps/sigma_agent/lib/sigma_agent/session_supervisor.ex` only if restart strategy change is still necessary after callback isolation.
- Test: `apps/sigma_agent/test/sigma_agent/runtime_test.exs`

- [ ] Add a test where `on_event` raises and the session process remains alive with an emitted/logged persistence error.

- [ ] Wrap `on_event.(event)` in `try/rescue/catch` inside `SessionProcess.handle_cast/2`.

```elixir
defp safe_on_event(on_event, event) when is_function(on_event, 1) do
  on_event.(event)
  :ok
rescue
  e -> {:error, Exception.message(e)}
catch
  kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
end
```

- [ ] Apply the runtime event regardless of persistence failure, and surface the persistence failure through telemetry or logs.

- [ ] Run focused tests.

```bash
devenv shell -- mix test apps/sigma_agent/test/sigma_agent/runtime_test.exs
```

Expected: 0 failures.

## Task 15: Fix source parity documentation

**Findings covered:** absent `./source` parity contract.

**Files:**
- Modify: `README.md`
- Optional: add a script or docs note if the repo is expected to fetch upstream source out of band.

- [ ] Choose one policy:
  - Add `source` as a submodule/fetch step, or
  - Update README to state the upstream source is not vendored and link to the authoritative upstream repo.

- [ ] If not vendoring source, replace the current README sentence with:

```markdown
The original TypeScript `pi` source is used as a behavioral reference while porting; it is not vendored in this repository. Fetch or clone the upstream source separately when doing parity work.
```

- [ ] Run docs diff check.

```bash
git diff --check README.md
```

Expected: exits 0.

## Task 16: Final umbrella verification

**Files:** all touched files.

- [ ] Run format check.

```bash
devenv shell -- mix format --check-formatted
```

Expected: exits 0.

- [ ] Run compile with warnings as errors.

```bash
devenv shell -- mix compile --warnings-as-errors
```

Expected: exits 0.

- [ ] Run full tests.

```bash
devenv shell -- mix test
```

Expected: 0 failures.

- [ ] Run production smoke check.

```bash
SECRET_KEY_BASE="$(devenv shell -- mix phx.gen.secret)" MIX_ENV=prod devenv shell -- mix eval ':ok'
```

Expected: exits 0.

- [ ] Run GitNexus change detection before committing.

```bash
npx gitnexus analyze
```

Then use the GitNexus detect-changes tool and review affected symbols/processes before commit.

- [ ] Commit in logical chunks if not already committed per task.

Suggested commit grouping:

```bash
git commit -m "fix(release): restore production boot config"
git commit -m "fix(session): harden repository and session identity"
git commit -m "fix(coding): fail closed around tools and hooks"
git commit -m "fix(agent): bound tool loops and provider decode errors"
git commit -m "docs: clarify source parity contract"
```

## Recommended Execution Order

1. Task 1: release config. It is independent and quickly verified.
2. Tasks 2-6: repository/session identity. These are tightly related and should land together or in adjacent commits.
3. Tasks 7-11: security hardening for config, permissions, tools, hooks, and output/timeouts.
4. Tasks 12-14: agent/provider/runtime resilience.
5. Task 15: docs.
6. Task 16: final verification.

## Risk Notes

- Changing `ConfigManager.sessions_dir/1` affects existing session discovery. Keep the legacy migration path until existing dev data has moved.
- Repository route validation may break direct-link workflows for paths that were never added through `RepoManager.add_repo/2`; add tests that the normal add-repository flow still works.
- Hook stdin handling is the most subtle tool-runtime change. Prefer a minimal implementation with explicit tests for EOF-reading hooks and timeout behavior before changing broader hook semantics.
- Tool timeouts may affect users who rely on very long-running bash commands. Use a documented max/default and allow explicit per-call timeout within a bounded maximum.
