# PRD: Build `pi_tools` as the Elixir Port of oh-my-pi Tools

## 1. Summary

Create a new umbrella app, `apps/pi_tools`, as the home for **oh-my-pi-style built-in tools** in `ex_pi`.

This is not just a refactor of current `PiCoding.Tools`. The goal is to establish `pi_tools` as the migration target for the oh-my-pi tool surface:

```text
read, write, edit, search, find, bash, job, task, todo, ask,
lsp, ast_grep, ast_edit, resolve, web_search, github, eval, ...
```

`ex_pi_coding` remains the **tool runtime kernel**: behaviour, dispatcher, permissions, hooks, MCP bridge. `pi_tools` becomes the **first-party tool implementation layer**.

oh-my-pi groups tools into file/content, runtime, code intelligence, coordination, external, memory/state, and misc tools. The initial `pi_tools` PR should mirror this structure and expose only oh-my-pi canonical tool names. There is no legacy fallback mode in the active dashboard/session tool list.

### Implementation Update

The first PR includes oh-my-pi hashline edit directly. `edit` is not a port of the old `path/content/old_content` replacement tool. It is `input`-only and uses the current oh-my-pi `[PATH#TAG]` header format, backed by a Rust NIF for hashline parsing, applying, and content tag calculation.

## 2. Goals

1. Add new umbrella app:

   ```text
   apps/pi_tools
   ```

   OTP app:

   ```elixir
   :pi_tools
   ```

   Module prefix:

   ```elixir
   PiTools
   ```

2. Establish `PiTools` as the canonical home for oh-my-pi-style tools.

3. Create a `PiTools.Catalog` describing the target oh-my-pi tool surface, including status and gating.

4. Implement an initial working subset with oh-my-pi canonical names:

   ```text
   read
   write
   edit
   search
   find
   bash
   ask
   ```

5. Keep current `PiCoding.Tools.*` modules in place for existing tests and internal callers, but do not expose legacy names in the default dashboard/session tool list.

6. Update `PiWeb.SessionLive` to load tools through `PiTools.default_tools/0`, not by hardcoding `PiCoding.Tools.*`.

7. Do not expose planned tools until they work or are explicitly enabled.

## 3. Non-goals

This PR should not fully implement LSP, AST editing, job management, task agents, memory, GitHub, web search, browser automation, or eval kernels.

This PR should create the **tool surface and migration structure**, implement the first usable adapters, and make `edit` hashline-only.

Do not break existing current tools for direct callers, but do not expose legacy tool names in the default model-facing list.

Do not move dispatcher, permissions, hooks, MCP, provider logic, or agent turn loop into `pi_tools`.

## 4. Architecture Boundary

### `ex_pi_coding`

Owns runtime mechanics:

```text
PiCoding.Tool
PiCoding.Dispatcher
PiCoding.PermissionInterceptor
PiCoding.PermissionPolicy
PiCoding.Hooks.*
PiCoding.MCP.*
PiCoding.Utils.PathUtils
```

`PiCoding.Tool` already defines name, description, schema, and execute callbacks.

`PiCoding.Dispatcher` already handles dispatch, permission checks, hook execution, telemetry, and tool lookup.

### `pi_tools`

Owns first-party implementations:

```text
PiTools.Read
PiTools.Write
PiTools.Edit
PiTools.Search
PiTools.Find
PiTools.Bash
PiTools.Ask
PiTools.Job
PiTools.Resolve
PiTools.Todo
PiTools.LSP
PiTools.ASTGrep
PiTools.ASTEdit
PiTools.WebSearch
PiTools.GitHub
PiTools.Eval
```

Also owns future shared implementation code:

```text
PiTools.Output
PiTools.Truncation
PiTools.SnapshotStore
PiTools.Hashline.*
PiTools.Search.*
PiTools.Find.*
PiTools.InternalURL
PiTools.Artifacts
```

## 5. New App Layout

Create:

```text
apps/pi_tools/
  mix.exs
  README.md
  lib/
    pi_tools.ex
    pi_tools/
      catalog.ex

      file/
        read.ex
        write.ex
        edit.ex
        search.ex
        find.ex

      runtime/
        bash.ex
        job.ex

      coordination/
        ask.ex
        todo.ex
        task.ex

      code_intel/
        lsp.ex
        ast_grep.ex
        ast_edit.ex

      external/
        web_search.ex
        github.ex

      state/
        resolve.ex

      legacy/
        grep.ex
        glob.ex
        ls.ex
        url_fetch.ex
        ask_user_question.ex
```

The actual modules exposed to the model should be flat aliases for now:

```elixir
PiTools.Read
PiTools.Write
PiTools.Edit
PiTools.Search
PiTools.Find
PiTools.Bash
PiTools.Ask
```

Implementation files may live under grouped directories.

## 6. `apps/pi_tools/mix.exs`

Create:

```elixir
defmodule PiTools.MixProject do
  use Mix.Project

  def project do
    [
      app: :pi_tools,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_pi_coding, in_umbrella: true},
      {:req, "~> 0.5"}
    ]
  end
end
```

`Req` is needed by the legacy `url_fetch` implementation.

## 7. Tool Registry

Create `PiTools`:

```elixir
defmodule PiTools do
  @moduledoc """
  oh-my-pi-style built-in tool registry for ex_pi.

  `ex_pi_coding` owns the runtime contract.
  `pi_tools` owns first-party tool implementations.
  """

  def default_tools do
    [
      PiTools.Ask,
      PiTools.Read,
      PiTools.Write,
      PiTools.Bash,
      PiTools.Edit,
      PiTools.Search,
      PiTools.Find
    ]
  end

  def planned_tools do
    PiTools.Catalog.planned()
  end
end
```

Default should be `:oh_my_pi` unless this breaks tests. If the current app needs a safer transition, set `:legacy` temporarily in `SessionLive` and leave a TODO to switch once prompts/tests are updated.

## 8. Tool Catalog

Create `PiTools.Catalog`.

Purpose: make the target oh-my-pi tool surface explicit even before every tool is implemented.

Example shape:

```elixir
defmodule PiTools.Catalog do
  @moduledoc """
  Catalog of the target oh-my-pi-compatible tool surface.
  """

  @tools [
    %{name: "read", category: :file, module: PiTools.Read, status: :implemented},
    %{name: "write", category: :file, module: PiTools.Write, status: :implemented},
    %{name: "edit", category: :file, module: PiTools.Edit, status: :implemented},
    %{name: "search", category: :file, module: PiTools.Search, status: :implemented},
    %{name: "find", category: :file, module: PiTools.Find, status: :implemented},

    %{name: "bash", category: :runtime, module: PiTools.Bash, status: :implemented},
    %{name: "job", category: :runtime, module: PiTools.Job, status: :planned},
    %{name: "eval", category: :runtime, module: PiTools.Eval, status: :planned},

    %{name: "lsp", category: :code_intel, module: PiTools.LSP, status: :planned},
    %{name: "ast_grep", category: :code_intel, module: PiTools.ASTGrep, status: :planned},
    %{name: "ast_edit", category: :code_intel, module: PiTools.ASTEdit, status: :planned},

    %{name: "ask", category: :coordination, module: PiTools.Ask, status: :implemented},
    %{name: "todo", category: :coordination, module: PiTools.Todo, status: :planned},
    %{name: "task", category: :coordination, module: PiTools.Task, status: :planned},

    %{name: "resolve", category: :state, module: PiTools.Resolve, status: :planned},

    %{name: "web_search", category: :external, module: PiTools.WebSearch, status: :planned},
    %{name: "github", category: :external, module: PiTools.GitHub, status: :planned}
  ]

  def all, do: @tools
  def implemented, do: Enum.filter(@tools, &(&1.status == :implemented))
  def planned, do: Enum.filter(@tools, &(&1.status == :planned))
end
```

Important: catalog entries with `status: :planned` must not be returned by `default_tools/1`.

## 9. Initial Implemented oh-my-pi Tools

### 9.1 `PiTools.Read`

Port the existing `PiCoding.Tools.Read` implementation into `PiTools.Read`.

Keep current schema for now:

```text
path
offset
limit
```

But document that this is an MVP of oh-my-pi `read`.

Future target: oh-my-pi `read` reads files, directories, archives, SQLite, documents, images, URLs, internal URLs, and supports selector suffixes such as `:raw`, `:A-B`, `:A+C`, and multi-ranges.

### 9.2 `PiTools.Write`

Port existing `PiCoding.Tools.Write`.

Keep behavior unchanged:

```text
create new file
fail if file exists
create parent directories
```

### 9.3 `PiTools.Edit`

Implement oh-my-pi hashline edit in the first PR.

Schema:

```text
input
```

`input` is a hashline patch string. It must begin with `[PATH#TAG]` on the first non-blank line. `TAG` is a 4-hex content hash copied from the latest read/search/write/edit output in the same session.

Supported first-scope operations:

```text
replace N..M:
delete N..M
insert before N:
insert after N:
insert head:
insert tail:
```

Body rows use `+TEXT`. The old `path/content/old_content` edit schema must fail clearly and must not silently fall back to legacy replacement behavior.

### 9.4 `PiTools.Search`

Create an oh-my-pi-style content search tool.

Tool name:

```elixir
def name, do: "search"
```

MVP schema:

```elixir
%{
  "type" => "object",
  "properties" => %{
    "pattern" => %{
      "type" => "string",
      "description" => "Regex pattern to search for"
    },
    "paths" => %{
      "oneOf" => [
        %{"type" => "string"},
        %{"type" => "array", "items" => %{"type" => "string"}}
      ],
      "description" => "File, directory, or glob path(s) to search"
    },
    "i" => %{
      "type" => "boolean",
      "description" => "Case-insensitive search"
    },
    "skip" => %{
      "type" => "integer",
      "description" => "Result page offset; only 0 is supported in MVP",
      "minimum" => 0
    }
  },
  "required" => ["pattern", "paths"]
}
```

Implementation may internally reuse the existing grep logic.

MVP behavior:

* Supports local files and directories.
* Supports one or many paths.
* Supports `i`.
* `skip > 0` may return a clear error until pagination is implemented.
* Output should be grouped by file when searching directories or multiple paths.
* Keep output stable and readable.

Future target: oh-my-pi `search` supports regex over files, directories, globs, archives, internal URLs, context lines, grouped output, pagination, and hashline anchors.

### 9.5 `PiTools.Find`

Create an oh-my-pi-style path discovery tool.

Tool name:

```elixir
def name, do: "find"
```

MVP schema:

```elixir
%{
  "type" => "object",
  "properties" => %{
    "paths" => %{
      "type" => "array",
      "items" => %{"type" => "string"},
      "description" => "One or more globs, files, or directories"
    },
    "hidden" => %{
      "type" => "boolean",
      "description" => "Whether hidden files are included"
    },
    "gitignore" => %{
      "type" => "boolean",
      "description" => "Whether .gitignore is respected; not supported in MVP"
    },
    "limit" => %{
      "type" => "integer",
      "description" => "Maximum number of returned paths",
      "minimum" => 1
    },
    "timeout" => %{
      "type" => "number",
      "description" => "Timeout in seconds; best-effort in MVP"
    }
  },
  "required" => ["paths"]
}
```

Implementation may internally reuse the current glob logic.

MVP behavior:

* Supports files, directories, and globs.
* Sort output deterministically.
* Return relative paths.
* Enforce limit.
* `gitignore` can be accepted but documented as best-effort or unsupported in MVP.

Future target: oh-my-pi `find` supports path discovery by glob, hidden/gitignore toggles, limits, timeout, grouped output, and mtime sorting.

### 9.6 `PiTools.Bash`

Port existing `PiCoding.Tools.Bash`.

Keep current behavior working.

Add oh-my-pi-compatible fields only when they can be safely supported:

```text
command
timeout
cwd
env
```

Do not expose `pty` or `async` yet unless implemented.

Future target: oh-my-pi `bash` supports cwd, env, timeout clamp, PTY, async/background jobs, auto-backgrounding, output truncation/artifacts, and shell-pattern interception.

### 9.7 `PiTools.Ask`

Create oh-my-pi-style `ask`.

Tool name:

```elixir
def name, do: "ask"
```

Implementation should delegate to current `AskUserQuestion` logic and the existing `ask_user_question_fn` callback.

Keep `PiTools.Legacy.AskUserQuestion` with name `"AskUserQuestion"` for compatibility.

## 10. Legacy Tools

Keep these modules implemented under `PiTools.Legacy.*`:

```text
PiTools.Legacy.Grep
PiTools.Legacy.Glob
PiTools.Legacy.LS
PiTools.Legacy.UrlFetch
PiTools.Legacy.AskUserQuestion
```

Then make `PiCoding.Tools.*` wrappers delegate to them or to the canonical modules:

```text
PiCoding.Tools.Read            -> PiTools.Read
PiCoding.Tools.Write           -> PiTools.Write
PiCoding.Tools.Edit            -> PiTools.Edit
PiCoding.Tools.Bash            -> PiTools.Bash
PiCoding.Tools.Grep            -> PiTools.Legacy.Grep
PiCoding.Tools.Glob            -> PiTools.Legacy.Glob
PiCoding.Tools.LS              -> PiTools.Legacy.LS
PiCoding.Tools.UrlFetch        -> PiTools.Legacy.UrlFetch
PiCoding.Tools.AskUserQuestion -> PiTools.Legacy.AskUserQuestion
```

## 11. Web Integration

Update `apps/ex_pi_web/mix.exs`:

```elixir
{:pi_tools, in_umbrella: true}
```

Update `PiWeb.SessionLive`.

Current code hardcodes built-ins:

```elixir
builtin_tools = [
  PiCoding.Tools.AskUserQuestion,
  PiCoding.Tools.Read,
  PiCoding.Tools.Write,
  PiCoding.Tools.Bash,
  PiCoding.Tools.Edit,
  PiCoding.Tools.Glob,
  PiCoding.Tools.Grep,
  PiCoding.Tools.LS,
  PiCoding.Tools.UrlFetch
]
```

Replace with:

```elixir
builtin_tools = PiTools.default_tools()
```

MCP merging remains unchanged:

```elixir
tool_modules = builtin_tools ++ mcp_tools
```

## 12. README

Create `apps/pi_tools/README.md`.

Suggested content:

```markdown
# pi_tools

Elixir port target for oh-my-pi built-in tools.

## Boundary

`ex_pi_coding` owns the runtime:

- `PiCoding.Tool`
- dispatcher
- permission checks
- hooks
- MCP adapter

`pi_tools` owns first-party tool implementations:

- file/content tools
- runtime tools
- code-intelligence tools
- coordination tools
- external tools
- state/memory tools

## Initial implemented tools

oh-my-pi-style:

- ask
- read
- write
- bash
- edit
- search
- find

legacy compatibility:

- AskUserQuestion
- grep
- glob
- ls
- url_fetch

## Planned tools

- job
- resolve
- todo
- task
- lsp
- ast_grep
- ast_edit
- eval
- github
- web_search

Do not expose planned tools to the model until implemented or explicitly enabled.
```

## 13. Tests

### 13.1 Registry tests

Create:

```text
apps/pi_tools/test/pi_tools_test.exs
```

Test:

```elixir
defmodule PiToolsTest do
  use ExUnit.Case, async: true

  test "default tools expose canonical names" do
    assert Enum.map(PiTools.default_tools(), &PiCoding.Tool.name/1) == [
             "ask",
             "read",
             "write",
             "bash",
             "edit",
             "search",
             "find"
           ]
  end

  test "catalog includes planned oh-my-pi tool surface without exposing planned tools" do
    planned_names = PiTools.Catalog.planned() |> Enum.map(& &1.name)

    assert "job" in planned_names
    assert "resolve" in planned_names
    assert "todo" in planned_names
    assert "task" in planned_names
    assert "lsp" in planned_names
    assert "ast_grep" in planned_names
    assert "ast_edit" in planned_names
    assert "web_search" in planned_names
    assert "github" in planned_names

    exposed_names = PiTools.default_tools() |> Enum.map(&PiCoding.Tool.name/1)

    refute "job" in exposed_names
    refute "lsp" in exposed_names
    refute "ast_grep" in exposed_names
  end
end
```

### 13.2 Compatibility wrapper tests

Create:

```text
apps/ex_pi_coding/test/ex_pi_coding/tools/compat_test.exs
```

Test that existing `PiCoding.Tools.*` modules still expose expected names and schemas.

### 13.3 Search/find smoke tests

Create:

```text
apps/pi_tools/test/pi_tools/search_test.exs
apps/pi_tools/test/pi_tools/find_test.exs
```

Search smoke test:

```elixir
test "search finds content in a local file" do
  tmp = Path.join(System.tmp_dir!(), "pi-tools-search-#{System.unique_integer([:positive])}")
  File.mkdir_p!(tmp)
  File.write!(Path.join(tmp, "a.txt"), "hello\nworld\n")

  assert {:ok, result} =
           PiTools.Search.execute("tc", %{"pattern" => "world", "paths" => "a.txt"}, cwd: tmp)

  [text] = result.content
  assert text.text =~ "a.txt"
  assert text.text =~ "world"
end
```

Find smoke test:

```elixir
test "find returns matching paths" do
  tmp = Path.join(System.tmp_dir!(), "pi-tools-find-#{System.unique_integer([:positive])}")
  File.mkdir_p!(Path.join(tmp, "lib"))
  File.write!(Path.join(tmp, "lib/a.ex"), "defmodule A do end")

  assert {:ok, result} =
           PiTools.Find.execute("tc", %{"paths" => ["lib/**/*.ex"]}, cwd: tmp)

  [text] = result.content
  assert text.text =~ "lib/a.ex"
end
```

## 14. Acceptance Criteria

This PR is complete when:

1. `apps/pi_tools` exists.

2. `PiTools.default_tools()` exposes:

   ```text
   ask, read, write, bash, edit, search, find
   ```

3. `PiTools.Edit` is hashline-only, input-only, and backed by the Rust NIF hashline core.

4. `PiTools.Catalog` lists the target oh-my-pi tool surface, including planned tools.

5. Planned tools are not exposed by default.

6. Current `PiCoding.Tools.*` modules still work for direct callers.

7. `PiWeb.SessionLive` loads built-ins through `PiTools.default_tools/1`.

8. Existing tests pass.

9. New registry, catalog, search, and find tests pass.

10. No dispatcher, permission, hook, MCP, or provider behavior changes.

## 15. Suggested PR Title

```text
feat(tools): introduce pi_tools as oh-my-pi tool surface
```

## 16. Suggested Commit Message

```text
feat(tools): introduce pi_tools as oh-my-pi tool surface

Add a dedicated umbrella app for first-party tool implementations and
the target oh-my-pi-compatible tool catalog.

Expose initial canonical tools: ask, read, write, bash, edit, search,
and find. Preserve current tool names through legacy wrappers and keep
PiCoding focused on the runtime contract, dispatcher, permissions,
hooks, and MCP adapter.
```

## 17. Follow-up PR Plan

After this lands, use separate PRs:

1. **Hashline snapshot store**

   ```text
   PiTools.SnapshotStore
   PiTools.Hashline.Parser
   PiTools.Hashline.Apply
   PiTools.Hashline.Mismatch
   ```

2. **oh-my-pi read selectors**

   ```text
   path:raw
   path:A-B
   path:A+C
   path:A-B,C-D
   directory tree read
   URL read via read
   ```

3. **Hashline edit mode**

   ```text
   ¶PATH#TAG
   replace N..M
   delete N..M
   insert before/after/head/tail
   ```

4. **Search/find parity**

   ```text
   grouped output
   pagination
   gitignore
   hidden files
   sparse snapshot recording
   ```

5. **Bash hardening + job**

   ```text
   cwd
   env
   timeout clamp
   output truncation
   async jobs
   job list/poll/cancel
   ```

6. **Resolve**

   ```text
   hidden apply/discard tool
   pending action queue
   preview producer integration
   ```

7. **Code intelligence**

   ```text
   lsp
   ast_grep
   ast_edit
   ```

8. **Coordination**

   ```text
   todo
   task subagents
   ```

9. **External/research**

   ```text
   github
   web_search
   eval
   browser later
   ```
