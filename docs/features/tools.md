# PRD: Build `sigma_tools` as the Elixir Port of oh-my-pi Tools

## 1. Summary

Create a new umbrella app, `apps/sigma_tools`, as the home for **oh-my-pi-style built-in tools** in `sigma`.

This is not just a refactor of current `Sigma.Coding.Tools`. The goal is to establish `sigma_tools` as the migration target for the oh-my-pi tool surface:

```text
read, write, edit, search, find, bash, job, task, todo, ask,
lsp, ast_grep, ast_edit, resolve, web_search, github, eval, ...
```

`sigma_coding` remains the **tool runtime kernel**: behaviour, dispatcher, permissions, hooks, MCP bridge. `sigma_tools` becomes the **first-party tool implementation layer**.

oh-my-pi groups tools into file/content, runtime, code intelligence, coordination, external, memory/state, and misc tools. The initial `sigma_tools` PR should mirror this structure and expose only oh-my-pi canonical tool names. There is no legacy fallback mode in the active dashboard/session tool list.

### Implementation Update

The first PR includes oh-my-pi hashline edit directly. `edit` is not a port of the old `path/content/old_content` replacement tool. It is `input`-only and uses the current oh-my-pi `[PATH#TAG]` header format, backed by a Rust NIF for hashline parsing, applying, and content tag calculation.

## 2. Goals

1. Add new umbrella app:

   ```text
   apps/sigma_tools
   ```

   OTP app:

   ```elixir
   :sigma_tools
   ```

   Module prefix:

   ```elixir
   Sigma.Tools
   ```

2. Establish `Sigma.Tools` as the canonical home for oh-my-pi-style tools.

3. Create a `Sigma.Tools.Catalog` describing the target oh-my-pi tool surface, including status and gating.

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

5. Keep current `Sigma.Coding.Tools.*` modules in place for existing tests and internal callers, but do not expose legacy names in the default dashboard/session tool list.

6. Update `Sigma.Web.SessionLive` to load tools through `Sigma.Tools.default_tools/0`, not by hardcoding `Sigma.Coding.Tools.*`.

7. Do not expose planned tools until they work or are explicitly enabled.

## 3. Non-goals

This PR should not fully implement LSP, AST editing, job management, task agents, memory, GitHub, web search, browser automation, or eval kernels.

This PR should create the **tool surface and migration structure**, implement the first usable adapters, and make `edit` hashline-only.

Do not break existing current tools for direct callers, but do not expose legacy tool names in the default model-facing list.

Do not move dispatcher, permissions, hooks, MCP, provider logic, or agent turn loop into `sigma_tools`.

## 4. Architecture Boundary

### `sigma_coding`

Owns runtime mechanics:

```text
Sigma.Coding.Tool
Sigma.Coding.Dispatcher
Sigma.Coding.PermissionInterceptor
Sigma.Coding.PermissionPolicy
Sigma.Coding.Hooks.*
Sigma.Coding.MCP.*
Sigma.Coding.Utils.PathUtils
```

`Sigma.Coding.Tool` already defines name, description, schema, and execute callbacks.

`Sigma.Coding.Dispatcher` already handles dispatch, permission checks, hook execution, telemetry, and tool lookup.

### `sigma_tools`

Owns first-party implementations:

```text
Sigma.Tools.Read
Sigma.Tools.Write
Sigma.Tools.Edit
Sigma.Tools.Search
Sigma.Tools.Find
Sigma.Tools.Bash
Sigma.Tools.Ask
Sigma.Tools.Job
Sigma.Tools.Resolve
Sigma.Tools.Todo
Sigma.Tools.LSP
Sigma.Tools.ASTGrep
Sigma.Tools.ASTEdit
Sigma.Tools.WebSearch
Sigma.Tools.GitHub
Sigma.Tools.Eval
```

Also owns future shared implementation code:

```text
Sigma.Tools.Output
Sigma.Tools.Truncation
Sigma.Tools.SnapshotStore
Sigma.Tools.Hashline.*
Sigma.Tools.Search.*
Sigma.Tools.Find.*
Sigma.Tools.InternalURL
Sigma.Tools.Artifacts
```

## 5. New App Layout

Create:

```text
apps/sigma_tools/
  mix.exs
  README.md
  lib/
    sigma_tools.ex
    sigma_tools/
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
Sigma.Tools.Read
Sigma.Tools.Write
Sigma.Tools.Edit
Sigma.Tools.Search
Sigma.Tools.Find
Sigma.Tools.Bash
Sigma.Tools.Ask
```

Implementation files may live under grouped directories.

## 6. `apps/sigma_tools/mix.exs`

Create:

```elixir
defmodule Sigma.Tools.MixProject do
  use Mix.Project

  def project do
    [
      app: :sigma_tools,
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
      {:sigma_coding, in_umbrella: true},
      {:req, "~> 0.5"}
    ]
  end
end
```

`Req` is needed by the legacy `url_fetch` implementation.

## 7. Tool Registry

Create `Sigma.Tools`:

```elixir
defmodule Sigma.Tools do
  @moduledoc """
  oh-my-pi-style built-in tool registry for sigma.

  `sigma_coding` owns the runtime contract.
  `sigma_tools` owns first-party tool implementations.
  """

  def default_tools do
    [
      Sigma.Tools.Ask,
      Sigma.Tools.Read,
      Sigma.Tools.Write,
      Sigma.Tools.Bash,
      Sigma.Tools.Edit,
      Sigma.Tools.Search,
      Sigma.Tools.Find
    ]
  end

  def planned_tools do
    Sigma.Tools.Catalog.planned()
  end
end
```

Default should be `:oh_my_pi` unless this breaks tests. If the current app needs a safer transition, set `:legacy` temporarily in `SessionLive` and leave a TODO to switch once prompts/tests are updated.

## 8. Tool Catalog

Create `Sigma.Tools.Catalog`.

Purpose: make the target oh-my-pi tool surface explicit even before every tool is implemented.

Example shape:

```elixir
defmodule Sigma.Tools.Catalog do
  @moduledoc """
  Catalog of the target oh-my-pi-compatible tool surface.
  """

  @tools [
    %{name: "read", category: :file, module: Sigma.Tools.Read, status: :implemented},
    %{name: "write", category: :file, module: Sigma.Tools.Write, status: :implemented},
    %{name: "edit", category: :file, module: Sigma.Tools.Edit, status: :implemented},
    %{name: "search", category: :file, module: Sigma.Tools.Search, status: :implemented},
    %{name: "find", category: :file, module: Sigma.Tools.Find, status: :implemented},

    %{name: "bash", category: :runtime, module: Sigma.Tools.Bash, status: :implemented},
    %{name: "job", category: :runtime, module: Sigma.Tools.Job, status: :planned},
    %{name: "eval", category: :runtime, module: Sigma.Tools.Eval, status: :planned},

    %{name: "lsp", category: :code_intel, module: Sigma.Tools.LSP, status: :planned},
    %{name: "ast_grep", category: :code_intel, module: Sigma.Tools.ASTGrep, status: :planned},
    %{name: "ast_edit", category: :code_intel, module: Sigma.Tools.ASTEdit, status: :planned},

    %{name: "ask", category: :coordination, module: Sigma.Tools.Ask, status: :implemented},
    %{name: "todo", category: :coordination, module: Sigma.Tools.Todo, status: :planned},
    %{name: "task", category: :coordination, module: Sigma.Tools.Task, status: :planned},

    %{name: "resolve", category: :state, module: Sigma.Tools.Resolve, status: :planned},

    %{name: "web_search", category: :external, module: Sigma.Tools.WebSearch, status: :planned},
    %{name: "github", category: :external, module: Sigma.Tools.GitHub, status: :planned}
  ]

  def all, do: @tools
  def implemented, do: Enum.filter(@tools, &(&1.status == :implemented))
  def planned, do: Enum.filter(@tools, &(&1.status == :planned))
end
```

Important: catalog entries with `status: :planned` must not be returned by `default_tools/1`.

## 9. Initial Implemented oh-my-pi Tools

### 9.1 `Sigma.Tools.Read`

Port the existing `Sigma.Coding.Tools.Read` implementation into `Sigma.Tools.Read`.

Keep current schema for now:

```text
path
offset
limit
```

But document that this is an MVP of oh-my-pi `read`.

Future target: oh-my-pi `read` reads files, directories, archives, SQLite, documents, images, URLs, internal URLs, and supports selector suffixes such as `:raw`, `:A-B`, `:A+C`, and multi-ranges.

### 9.2 `Sigma.Tools.Write`

Port existing `Sigma.Coding.Tools.Write`.

Keep behavior unchanged:

```text
create new file
fail if file exists
create parent directories
```

### 9.3 `Sigma.Tools.Edit`

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

### 9.4 `Sigma.Tools.Search`

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

### 9.5 `Sigma.Tools.Find`

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

### 9.6 `Sigma.Tools.Bash`

Port existing `Sigma.Coding.Tools.Bash`.

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

### 9.7 `Sigma.Tools.Ask`

Create oh-my-pi-style `ask`.

Tool name:

```elixir
def name, do: "ask"
```

Implementation should delegate to current `AskUserQuestion` logic and the existing `ask_user_question_fn` callback.

Keep `Sigma.Tools.Legacy.AskUserQuestion` with name `"AskUserQuestion"` for compatibility.

## 10. Legacy Tools

Keep these modules implemented under `Sigma.Tools.Legacy.*`:

```text
Sigma.Tools.Legacy.Grep
Sigma.Tools.Legacy.Glob
Sigma.Tools.Legacy.LS
Sigma.Tools.Legacy.UrlFetch
Sigma.Tools.Legacy.AskUserQuestion
```

Then make `Sigma.Coding.Tools.*` wrappers delegate to them or to the canonical modules:

```text
Sigma.Coding.Tools.Read            -> Sigma.Tools.Read
Sigma.Coding.Tools.Write           -> Sigma.Tools.Write
Sigma.Coding.Tools.Edit            -> Sigma.Tools.Edit
Sigma.Coding.Tools.Bash            -> Sigma.Tools.Bash
Sigma.Coding.Tools.Grep            -> Sigma.Tools.Legacy.Grep
Sigma.Coding.Tools.Glob            -> Sigma.Tools.Legacy.Glob
Sigma.Coding.Tools.LS              -> Sigma.Tools.Legacy.LS
Sigma.Coding.Tools.UrlFetch        -> Sigma.Tools.Legacy.UrlFetch
Sigma.Coding.Tools.AskUserQuestion -> Sigma.Tools.Legacy.AskUserQuestion
```

## 11. Web Integration

Update `apps/sigma_web/mix.exs`:

```elixir
{:sigma_tools, in_umbrella: true}
```

Update `Sigma.Web.SessionLive`.

Current code hardcodes built-ins:

```elixir
builtin_tools = [
  Sigma.Coding.Tools.AskUserQuestion,
  Sigma.Coding.Tools.Read,
  Sigma.Coding.Tools.Write,
  Sigma.Coding.Tools.Bash,
  Sigma.Coding.Tools.Edit,
  Sigma.Coding.Tools.Glob,
  Sigma.Coding.Tools.Grep,
  Sigma.Coding.Tools.LS,
  Sigma.Coding.Tools.UrlFetch
]
```

Replace with:

```elixir
builtin_tools = Sigma.Tools.default_tools()
```

MCP merging remains unchanged:

```elixir
tool_modules = builtin_tools ++ mcp_tools
```

## 12. README

Create `apps/sigma_tools/README.md`.

Suggested content:

```markdown
# sigma_tools

Elixir port target for oh-my-pi built-in tools.

## Boundary

`sigma_coding` owns the runtime:

- `Sigma.Coding.Tool`
- dispatcher
- permission checks
- hooks
- MCP adapter

`sigma_tools` owns first-party tool implementations:

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
apps/sigma_tools/test/sigma_tools_test.exs
```

Test:

```elixir
defmodule Sigma.ToolsTest do
  use ExUnit.Case, async: true

  test "default tools expose canonical names" do
    assert Enum.map(Sigma.Tools.default_tools(), &Sigma.Coding.Tool.name/1) == [
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
    planned_names = Sigma.Tools.Catalog.planned() |> Enum.map(& &1.name)

    assert "job" in planned_names
    assert "resolve" in planned_names
    assert "todo" in planned_names
    assert "task" in planned_names
    assert "lsp" in planned_names
    assert "ast_grep" in planned_names
    assert "ast_edit" in planned_names
    assert "web_search" in planned_names
    assert "github" in planned_names

    exposed_names = Sigma.Tools.default_tools() |> Enum.map(&Sigma.Coding.Tool.name/1)

    refute "job" in exposed_names
    refute "lsp" in exposed_names
    refute "ast_grep" in exposed_names
  end
end
```

### 13.2 Compatibility wrapper tests

Create:

```text
apps/sigma_coding/test/sigma_coding/tools/compat_test.exs
```

Test that existing `Sigma.Coding.Tools.*` modules still expose expected names and schemas.

### 13.3 Search/find smoke tests

Create:

```text
apps/sigma_tools/test/sigma_tools/search_test.exs
apps/sigma_tools/test/sigma_tools/find_test.exs
```

Search smoke test:

```elixir
test "search finds content in a local file" do
  tmp = Path.join(System.tmp_dir!(), "pi-tools-search-#{System.unique_integer([:positive])}")
  File.mkdir_p!(tmp)
  File.write!(Path.join(tmp, "a.txt"), "hello\nworld\n")

  assert {:ok, result} =
           Sigma.Tools.Search.execute("tc", %{"pattern" => "world", "paths" => "a.txt"}, cwd: tmp)

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
           Sigma.Tools.Find.execute("tc", %{"paths" => ["lib/**/*.ex"]}, cwd: tmp)

  [text] = result.content
  assert text.text =~ "lib/a.ex"
end
```

## 14. Acceptance Criteria

This PR is complete when:

1. `apps/sigma_tools` exists.

2. `Sigma.Tools.default_tools()` exposes:

   ```text
   ask, read, write, bash, edit, search, find
   ```

3. `Sigma.Tools.Edit` is hashline-only, input-only, and backed by the Rust NIF hashline core.

4. `Sigma.Tools.Catalog` lists the target oh-my-pi tool surface, including planned tools.

5. Planned tools are not exposed by default.

6. Current `Sigma.Coding.Tools.*` modules still work for direct callers.

7. `Sigma.Web.SessionLive` loads built-ins through `Sigma.Tools.default_tools/1`.

8. Existing tests pass.

9. New registry, catalog, search, and find tests pass.

10. No dispatcher, permission, hook, MCP, or provider behavior changes.

## 15. Suggested PR Title

```text
feat(tools): introduce sigma_tools as oh-my-pi tool surface
```

## 16. Suggested Commit Message

```text
feat(tools): introduce sigma_tools as oh-my-pi tool surface

Add a dedicated umbrella app for first-party tool implementations and
the target oh-my-pi-compatible tool catalog.

Expose initial canonical tools: ask, read, write, bash, edit, search,
and find. Preserve current tool names through legacy wrappers and keep
Sigma.Coding focused on the runtime contract, dispatcher, permissions,
hooks, and MCP adapter.
```

## 17. Follow-up PR Plan

After this lands, use separate PRs:

1. **Hashline snapshot store**

   ```text
   Sigma.Tools.SnapshotStore
   Sigma.Tools.Hashline.Parser
   Sigma.Tools.Hashline.Apply
   Sigma.Tools.Hashline.Mismatch
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
