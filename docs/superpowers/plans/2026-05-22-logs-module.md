# Logs Module (ex_pi_logs) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a structured debug-logging system using `:telemetry` that captures LLM requests/responses, tool calls, and permission checks per session, displayed in a real-time slide-out drawer in the appbar.

**Architecture:** A new `ex_pi_logs` umbrella app owns an ETS-backed ring buffer (500 entries, per session) and globally-attached telemetry handlers. Emitters in `ex_pi_ai` and `ex_pi_coding` fire `:telemetry.execute/3` with a `session_id` in metadata. `ex_pi_web` starts a buffer per session on mount, subscribes to a PubSub log topic, and renders a `LogDrawerLive` LiveComponent toggled from the appbar.

**Tech Stack:** `:telemetry` (already in lockfile), `phoenix_pubsub` (already in lockfile), ETS, Phoenix LiveComponent, DuskMoon UI components.

---

## Telemetry Event Names

```
[:ex_pi, :llm, :request, :start]       # before HTTP call to provider
[:ex_pi, :llm, :request, :stop]        # after :done event from stream
[:ex_pi, :tool, :call, :start]         # before tool.execute/3
[:ex_pi, :tool, :call, :stop]          # after tool.execute/3 returns
[:ex_pi, :permission, :check, :start]  # before PermissionPolicy.check/2
[:ex_pi, :permission, :check, :stop]   # after result returned
# Reserved (not emitted yet):
[:ex_pi, :mcp, :call, :start / :stop]
[:ex_pi, :hook, :run, :start / :stop]
```

## File Map

### New files (ex_pi_logs)
| File | Responsibility |
|------|---------------|
| `apps/ex_pi_logs/mix.exs` | App definition, deps: `:telemetry`, `:phoenix_pubsub` |
| `apps/ex_pi_logs/lib/ex_pi_logs.ex` | Public API: `start_session/1`, `stop_session/1`, `all/1`, `search/2` |
| `apps/ex_pi_logs/lib/ex_pi_logs/application.ex` | Starts Registry + BufferSupervisor, inits counter, calls `Handler.attach_all/0` |
| `apps/ex_pi_logs/lib/ex_pi_logs/entry.ex` | `%PiLogs.Entry{}` struct; counter stored in `:persistent_term` |
| `apps/ex_pi_logs/lib/ex_pi_logs/buffer.ex` | GenServer: owns ETS table, push/all/search, 500-entry ring cap |
| `apps/ex_pi_logs/lib/ex_pi_logs/buffer_supervisor.ex` | Plain module wrapping DynamicSupervisor: `start_session/1`, `stop_session/1` |
| `apps/ex_pi_logs/lib/ex_pi_logs/handler.ex` | `attach_all/0` (idempotent) + `handle_event/4` — writes to Buffer, broadcasts PubSub |
| `apps/ex_pi_logs/test/test_helper.exs` | ExUnit.start() |
| `apps/ex_pi_logs/test/ex_pi_logs/buffer_test.exs` | Buffer push, ring cap, search |
| `apps/ex_pi_logs/test/ex_pi_logs/handler_test.exs` | Handler routes entries to correct buffer |

### New files (ex_pi_web)
| File | Responsibility |
|------|---------------|
| `apps/ex_pi_web/lib/ex_pi_web/live/log_drawer_live.ex` | LiveComponent: filter chips, search input, scrollable entry list |

### Modified files
| File | Change |
|------|--------|
| `apps/ex_pi_ai/mix.exs` | Add `{:telemetry, "~> 1.0"}` |
| `apps/ex_pi_ai/lib/ex_pi_ai/providers/anthropic.ex` | Wrap stream with `Stream.transform` to emit `:start`/`:stop` |
| `apps/ex_pi_coding/mix.exs` | Add `{:telemetry, "~> 1.0"}` |
| `apps/ex_pi_coding/lib/ex_pi_coding/dispatcher.ex` | Emit tool `:start`/`:stop` in `do_dispatch/3` |
| `apps/ex_pi_coding/lib/ex_pi_coding/permission_interceptor.ex` | Emit permission `:start`/`:stop` in `check/2` |
| `apps/ex_pi_agent/lib/ex_pi_agent.ex` | Add `:session_id` to state; pass in provider params + dispatcher opts |
| `apps/ex_pi_web/mix.exs` | Add `{:ex_pi_logs, in_umbrella: true}` |
| `apps/ex_pi_web/lib/ex_pi_web/live/session_live.ex` | Start buffer, subscribe, handle `{:log_entry, entry}`, drawer state |
| `apps/ex_pi_web/lib/ex_pi_web/layouts/app.html.heex` | Conditionally render logs toggle button (bracket assign access, not `@`) |
| `config/config.exs` | `config :ex_pi_logs, pubsub: PiWeb.PubSub` |

---

## Task 1: ex_pi_logs umbrella app scaffold

**Files:**
- Create: `apps/ex_pi_logs/mix.exs`
- Create: `apps/ex_pi_logs/lib/ex_pi_logs.ex`
- Create: `apps/ex_pi_logs/lib/ex_pi_logs/application.ex`
- Create: `apps/ex_pi_logs/test/test_helper.exs`
- Modify: `config/config.exs`

> **Note:** The Registry and BufferSupervisor are both added here so every subsequent task can compile and boot cleanly. The Entry counter, Handler, and Buffer are added in later tasks but the supervision tree is ready from the start.

- [ ] **Step 1: Create mix.exs**

```elixir
# apps/ex_pi_logs/mix.exs
defmodule PiLogs.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_pi_logs,
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
      mod: {PiLogs.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"}
    ]
  end
end
```

- [ ] **Step 2: Create application.ex with Registry + BufferSupervisor**

```elixir
# apps/ex_pi_logs/lib/ex_pi_logs/application.ex
defmodule PiLogs.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: PiLogs.Registry},
      {DynamicSupervisor, name: PiLogs.BufferSupervisor, strategy: :one_for_one}
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: PiLogs.Supervisor)
    result
  end
end
```

- [ ] **Step 3: Create stub public API module**

```elixir
# apps/ex_pi_logs/lib/ex_pi_logs.ex
defmodule PiLogs do
  def start_session(session_id), do: PiLogs.BufferSupervisor.start_session(session_id)
  def stop_session(session_id), do: PiLogs.BufferSupervisor.stop_session(session_id)
  def all(session_id), do: PiLogs.Buffer.all(session_id)
  def search(session_id, opts \\ []), do: PiLogs.Buffer.search(session_id, opts)
end
```

- [ ] **Step 4: Create test_helper.exs**

```elixir
# apps/ex_pi_logs/test/test_helper.exs
ExUnit.start()
```

- [ ] **Step 5: Add pubsub config to config/config.exs**

After the existing config entries:
```elixir
config :ex_pi_logs, pubsub: PiWeb.PubSub
```

- [ ] **Step 6: Verify compilation**

Run: `mix compile`
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add apps/ex_pi_logs/ config/config.exs
git commit -m "feat(logs): add ex_pi_logs umbrella app scaffold"
```

---

## Task 2: PiLogs.Entry struct

**Files:**
- Create: `apps/ex_pi_logs/lib/ex_pi_logs/entry.ex`
- Modify: `apps/ex_pi_logs/lib/ex_pi_logs/application.ex`
- Create: `apps/ex_pi_logs/test/ex_pi_logs/entry_test.exs`

> **Counter implementation note:** The counter MUST NOT use `@counter :atomics.new(1, [])` as a module attribute. Module attributes are evaluated at **compile time** — the atomics reference stored in the bytecode would be a dangling pointer at runtime. Instead, the counter is created during `Application.start/2` and stored in `:persistent_term` where it persists for the VM lifetime.

- [ ] **Step 1: Write the failing test**

```elixir
# apps/ex_pi_logs/test/ex_pi_logs/entry_test.exs
defmodule PiLogs.EntryTest do
  use ExUnit.Case, async: true

  test "new/4 creates an entry with correct fields" do
    entry = PiLogs.Entry.new("session_abc", :llm, :request_start, %{model: "claude-3"})

    assert entry.session_id == "session_abc"
    assert entry.category == :llm
    assert entry.event == :request_start
    assert entry.metadata == %{model: "claude-3"}
    assert is_integer(entry.id)
    assert is_integer(entry.timestamp)
  end

  test "new/4 ids are strictly increasing" do
    e1 = PiLogs.Entry.new("s", :llm, :start, %{})
    e2 = PiLogs.Entry.new("s", :llm, :start, %{})
    assert e2.id > e1.id
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ex_pi_logs/test/ex_pi_logs/entry_test.exs`
Expected: compilation error — `PiLogs.Entry` does not exist.

- [ ] **Step 3: Implement Entry with persistent_term counter**

```elixir
# apps/ex_pi_logs/lib/ex_pi_logs/entry.ex
defmodule PiLogs.Entry do
  @enforce_keys [:id, :session_id, :category, :event, :metadata, :timestamp]
  defstruct [:id, :session_id, :category, :event, :metadata, :timestamp]

  @counter_key {__MODULE__, :counter}

  def init_counter do
    ref = :atomics.new(1, signed: false)
    :persistent_term.put(@counter_key, ref)
  end

  def new(session_id, category, event, metadata) do
    ref = :persistent_term.get(@counter_key)
    id = :atomics.add_get(ref, 1, 1)
    %__MODULE__{
      id: id,
      session_id: session_id,
      category: category,
      event: event,
      metadata: metadata,
      timestamp: System.system_time(:millisecond)
    }
  end
end
```

- [ ] **Step 4: Call init_counter from Application.start/2**

Update `apps/ex_pi_logs/lib/ex_pi_logs/application.ex`:

```elixir
defmodule PiLogs.Application do
  use Application

  @impl true
  def start(_type, _args) do
    PiLogs.Entry.init_counter()

    children = [
      {Registry, keys: :unique, name: PiLogs.Registry},
      {DynamicSupervisor, name: PiLogs.BufferSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PiLogs.Supervisor)
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test apps/ex_pi_logs/test/ex_pi_logs/entry_test.exs`
Expected: 2 tests pass.

- [ ] **Step 6: Commit**

```bash
git add apps/ex_pi_logs/lib/ex_pi_logs/entry.ex \
        apps/ex_pi_logs/lib/ex_pi_logs/application.ex \
        apps/ex_pi_logs/test/ex_pi_logs/entry_test.exs
git commit -m "feat(logs): add PiLogs.Entry struct with persistent_term counter"
```

---

## Task 3: PiLogs.Buffer + BufferSupervisor

**Files:**
- Create: `apps/ex_pi_logs/lib/ex_pi_logs/buffer.ex`
- Create: `apps/ex_pi_logs/lib/ex_pi_logs/buffer_supervisor.ex`
- Create: `apps/ex_pi_logs/test/ex_pi_logs/buffer_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/ex_pi_logs/test/ex_pi_logs/buffer_test.exs
defmodule PiLogs.BufferTest do
  use ExUnit.Case, async: true

  setup do
    session_id = "test_session_#{System.unique_integer([:positive])}"
    {:ok, _pid} = PiLogs.Buffer.start_link(session_id: session_id)
    %{session_id: session_id}
  end

  test "all/1 returns empty list on new session", %{session_id: sid} do
    assert PiLogs.Buffer.all(sid) == []
  end

  test "push/2 adds entries, all/1 returns newest first", %{session_id: sid} do
    e1 = PiLogs.Entry.new(sid, :llm, :request_start, %{})
    e2 = PiLogs.Entry.new(sid, :tool, :call_start, %{})
    PiLogs.Buffer.push(sid, e1)
    PiLogs.Buffer.push(sid, e2)

    [first | _] = PiLogs.Buffer.all(sid)
    assert first.id == e2.id
  end

  test "ring cap keeps exactly 500 entries when over limit", %{session_id: sid} do
    for _ <- 1..505 do
      PiLogs.Buffer.push(sid, PiLogs.Entry.new(sid, :llm, :request_start, %{}))
    end

    entries = PiLogs.Buffer.all(sid)
    assert length(entries) == 500
  end

  test "ring cap drops the oldest entry first", %{session_id: sid} do
    entries = for i <- 1..502, do: PiLogs.Entry.new(sid, :llm, :start, %{seq: i})
    Enum.each(entries, &PiLogs.Buffer.push(sid, &1))

    [latest | _rest] = PiLogs.Buffer.all(sid)
    assert latest.metadata.seq == 502

    all = PiLogs.Buffer.all(sid)
    # first inserted (seq 1 and 2) should be evicted
    assert Enum.all?(all, fn e -> e.metadata.seq > 2 end)
  end

  test "search/2 filters by category", %{session_id: sid} do
    PiLogs.Buffer.push(sid, PiLogs.Entry.new(sid, :llm, :request_start, %{}))
    PiLogs.Buffer.push(sid, PiLogs.Entry.new(sid, :tool, :call_start, %{}))

    results = PiLogs.Buffer.search(sid, category: :llm)
    assert length(results) == 1
    assert hd(results).category == :llm
  end

  test "search/2 with nil category returns all entries", %{session_id: sid} do
    PiLogs.Buffer.push(sid, PiLogs.Entry.new(sid, :llm, :request_start, %{}))
    PiLogs.Buffer.push(sid, PiLogs.Entry.new(sid, :tool, :call_start, %{}))

    results = PiLogs.Buffer.search(sid, category: nil)
    assert length(results) == 2
  end

  test "search/2 filters by text in metadata", %{session_id: sid} do
    PiLogs.Buffer.push(sid, PiLogs.Entry.new(sid, :llm, :request_start, %{model: "claude-3-opus"}))
    PiLogs.Buffer.push(sid, PiLogs.Entry.new(sid, :llm, :request_start, %{model: "gpt-4"}))

    results = PiLogs.Buffer.search(sid, text: "claude")
    assert length(results) == 1
  end

  test "search/2 with empty string text returns all entries", %{session_id: sid} do
    PiLogs.Buffer.push(sid, PiLogs.Entry.new(sid, :llm, :request_start, %{model: "claude"}))
    PiLogs.Buffer.push(sid, PiLogs.Entry.new(sid, :tool, :call_start, %{}))

    results = PiLogs.Buffer.search(sid, text: "")
    assert length(results) == 2
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test apps/ex_pi_logs/test/ex_pi_logs/buffer_test.exs`
Expected: compilation errors — `PiLogs.Buffer` does not exist.

- [ ] **Step 3: Implement Buffer GenServer**

```elixir
# apps/ex_pi_logs/lib/ex_pi_logs/buffer.ex
defmodule PiLogs.Buffer do
  use GenServer

  @cap 500

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  def push(session_id, entry) do
    GenServer.cast(via(session_id), {:push, entry})
  end

  def all(session_id) do
    case GenServer.whereis(via(session_id)) do
      nil -> []
      pid -> GenServer.call(pid, :all)
    end
  end

  def search(session_id, opts \\ []) do
    all(session_id)
    |> filter_category(Keyword.get(opts, :category))
    |> filter_text(Keyword.get(opts, :text))
  end

  # Server

  @impl true
  def init(_session_id) do
    table = :ets.new(:pi_logs_buffer, [:ordered_set, :private])
    {:ok, %{table: table, count: 0}}
  end

  @impl true
  def handle_cast({:push, entry}, %{table: table, count: count} = state) do
    :ets.insert(table, {entry.id, entry})

    state =
      if count >= @cap do
        oldest_key = :ets.first(table)
        if oldest_key != :"$end_of_table", do: :ets.delete(table, oldest_key)
        %{state | count: @cap}
      else
        %{state | count: count + 1}
      end

    {:noreply, state}
  end

  @impl true
  def handle_call(:all, _from, %{table: table} = state) do
    entries =
      :ets.tab2list(table)
      |> Enum.sort_by(fn {id, _} -> id end, :desc)
      |> Enum.map(fn {_, entry} -> entry end)

    {:reply, entries, state}
  end

  defp via(session_id), do: {:via, Registry, {PiLogs.Registry, session_id}}

  defp filter_category(entries, nil), do: entries
  defp filter_category(entries, cat), do: Enum.filter(entries, &(&1.category == cat))

  # Empty string matches everything — same as nil
  defp filter_text(entries, nil), do: entries
  defp filter_text(entries, ""), do: entries
  defp filter_text(entries, text) do
    lower = String.downcase(text)
    Enum.filter(entries, fn entry ->
      entry.metadata
      |> inspect()
      |> String.downcase()
      |> String.contains?(lower)
    end)
  end
end
```

- [ ] **Step 4: Implement BufferSupervisor**

```elixir
# apps/ex_pi_logs/lib/ex_pi_logs/buffer_supervisor.ex
defmodule PiLogs.BufferSupervisor do
  def start_session(session_id) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {PiLogs.Buffer, session_id: session_id}
    )
  end

  def stop_session(session_id) do
    case GenServer.whereis({:via, Registry, {PiLogs.Registry, session_id}}) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test apps/ex_pi_logs/test/ex_pi_logs/buffer_test.exs`
Expected: 7 tests pass.

- [ ] **Step 6: Commit**

```bash
git add apps/ex_pi_logs/lib/ex_pi_logs/buffer.ex \
        apps/ex_pi_logs/lib/ex_pi_logs/buffer_supervisor.ex \
        apps/ex_pi_logs/test/ex_pi_logs/buffer_test.exs
git commit -m "feat(logs): add per-session ETS ring buffer (500 entries)"
```

---

## Task 4: PiLogs.Handler (telemetry attach + broadcast)

**Files:**
- Create: `apps/ex_pi_logs/lib/ex_pi_logs/handler.ex`
- Create: `apps/ex_pi_logs/test/ex_pi_logs/handler_test.exs`
- Modify: `apps/ex_pi_logs/lib/ex_pi_logs/application.ex`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/ex_pi_logs/test/ex_pi_logs/handler_test.exs
defmodule PiLogs.HandlerTest do
  use ExUnit.Case, async: false

  setup do
    session_id = "handler_test_#{System.unique_integer([:positive])}"
    {:ok, _} = PiLogs.Buffer.start_link(session_id: session_id)
    # attach_all is idempotent (detaches before re-attaching)
    PiLogs.Handler.attach_all()
    on_exit(fn -> :telemetry.detach("ex_pi_logs") end)
    %{session_id: session_id}
  end

  test "LLM request_start is stored in buffer", %{session_id: sid} do
    :telemetry.execute(
      [:ex_pi, :llm, :request, :start],
      %{system_time: System.system_time()},
      %{session_id: sid, model: "claude-3", request_body: %{}}
    )

    [entry] = PiLogs.Buffer.all(sid)
    assert entry.category == :llm
    assert entry.event == :request_start
    assert entry.metadata[:model] == "claude-3"
  end

  test "tool call_stop is stored with correct category", %{session_id: sid} do
    :telemetry.execute(
      [:ex_pi, :tool, :call, :stop],
      %{duration: 42},
      %{session_id: sid, tool_name: "bash", result: {:ok, "output"}}
    )

    [entry] = PiLogs.Buffer.all(sid)
    assert entry.category == :tool
    assert entry.event == :call_stop
  end

  test "events without session_id are silently dropped", %{session_id: sid} do
    :telemetry.execute(
      [:ex_pi, :llm, :request, :start],
      %{system_time: System.system_time()},
      %{model: "claude-3"}
    )

    assert PiLogs.Buffer.all(sid) == []
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test apps/ex_pi_logs/test/ex_pi_logs/handler_test.exs`
Expected: compilation error — `PiLogs.Handler` not defined.

- [ ] **Step 3: Implement Handler**

```elixir
# apps/ex_pi_logs/lib/ex_pi_logs/handler.ex
defmodule PiLogs.Handler do
  @handler_id "ex_pi_logs"

  @events [
    [:ex_pi, :llm, :request, :start],
    [:ex_pi, :llm, :request, :stop],
    [:ex_pi, :tool, :call, :start],
    [:ex_pi, :tool, :call, :stop],
    [:ex_pi, :permission, :check, :start],
    [:ex_pi, :permission, :check, :stop]
  ]

  # Idempotent: detach any existing handler before re-attaching.
  # This prevents {:error, :already_exists} on app restarts or test re-runs.
  def attach_all do
    :telemetry.detach(@handler_id)
    :telemetry.attach_many(@handler_id, @events, &handle_event/4, nil)
  end

  def handle_event(event_name, measurements, metadata, _config) do
    session_id = metadata[:session_id]

    if session_id do
      {category, event} = parse_event(event_name)
      full_metadata = Map.merge(metadata, measurements)
      entry = PiLogs.Entry.new(session_id, category, event, full_metadata)
      PiLogs.Buffer.push(session_id, entry)
      broadcast(session_id, entry)
    end
  end

  defp broadcast(session_id, entry) do
    pubsub = Application.get_env(:ex_pi_logs, :pubsub)
    if pubsub do
      Phoenix.PubSub.broadcast(pubsub, "ex_pi:logs:#{session_id}", {:log_entry, entry})
    end
  end

  defp parse_event([:ex_pi, :llm, :request, :start]), do: {:llm, :request_start}
  defp parse_event([:ex_pi, :llm, :request, :stop]), do: {:llm, :request_stop}
  defp parse_event([:ex_pi, :tool, :call, :start]), do: {:tool, :call_start}
  defp parse_event([:ex_pi, :tool, :call, :stop]), do: {:tool, :call_stop}
  defp parse_event([:ex_pi, :permission, :check, :start]), do: {:permission, :check_start}
  defp parse_event([:ex_pi, :permission, :check, :stop]), do: {:permission, :check_stop}
end
```

- [ ] **Step 4: Call attach_all from Application after supervisor starts**

Update `apps/ex_pi_logs/lib/ex_pi_logs/application.ex`:

```elixir
defmodule PiLogs.Application do
  use Application

  @impl true
  def start(_type, _args) do
    PiLogs.Entry.init_counter()

    children = [
      {Registry, keys: :unique, name: PiLogs.Registry},
      {DynamicSupervisor, name: PiLogs.BufferSupervisor, strategy: :one_for_one}
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: PiLogs.Supervisor)
    PiLogs.Handler.attach_all()
    result
  end
end
```

- [ ] **Step 5: Run all ex_pi_logs tests**

Run: `mix test apps/ex_pi_logs/`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add apps/ex_pi_logs/lib/ex_pi_logs/handler.ex \
        apps/ex_pi_logs/lib/ex_pi_logs/application.ex \
        apps/ex_pi_logs/test/ex_pi_logs/handler_test.exs
git commit -m "feat(logs): add idempotent telemetry handler with ETS write and PubSub broadcast"
```

---

## Task 5: Thread session_id through PiAgent

**Files:**
- Modify: `apps/ex_pi_agent/lib/ex_pi_agent.ex`
- Modify: `apps/ex_pi_web/lib/ex_pi_web/session_manager.ex`

`PiAgent` has no `:session_id` field today. It needs one so it can inject `session_id` into provider params (for LLM telemetry) and into `dispatcher_opts` (for tool/permission telemetry).

The `session_id` flows: `SessionManager.get_agent(session_id, opts)` → `start_agent/3` → `PiAgent.start_link(opts)` → `init/1`.

Also note: `generate_summary/2` inside `PiAgent` calls `state.provider.stream(params)` for context compaction. Add `session_id` there too so compaction LLM calls are also logged.

- [ ] **Step 1: Add :session_id to PiAgent struct**

In `apps/ex_pi_agent/lib/ex_pi_agent.ex`, update the `defstruct`:

```elixir
  defstruct [
    :session_id,
    :model,
    :system_prompt,
    :tools,
    :provider,
    :cwd,
    :on_event,
    :dispatcher_opts,
    :provider_options,
    :task_supervisor,
    :current_turn_task,
    :policy,
    messages: [],
    subscribers: [],
    current_turn_assistant_message: nil
  ]
```

- [ ] **Step 2: Read session_id in init/1**

In `init/1`, add `session_id: opts[:session_id]` to the struct:

```elixir
    state = %__MODULE__{
      session_id: opts[:session_id],
      task_supervisor: task_sup,
      policy: policy,
      model: opts[:model],
      system_prompt: opts[:system_prompt],
      tools: opts[:tools] || [],
      provider: opts[:provider] || Anthropic,
      messages: opts[:messages] || [],
      cwd: opts[:cwd] || File.cwd!(),
      on_event: opts[:on_event],
      dispatcher_opts: opts[:dispatcher_opts] || [],
      provider_options: opts[:options] || []
    }
```

- [ ] **Step 3: Pass session_id in provider params (run_stream)**

In `run_stream/1`, add `session_id` to the `params` map:

```elixir
    params = %{
      model: state.model,
      session_id: state.session_id,
      context: %{
        messages: llm_messages,
        system_prompt: state.system_prompt,
        tools: ai_tools
      },
      options: state.provider_options
    }
```

- [ ] **Step 4: Pass session_id in dispatcher_opts (execute_tools)**

In `execute_tools/2`:

```elixir
    opts =
      state.dispatcher_opts
      |> Keyword.put(:cwd, state.cwd)
      |> Keyword.put(:permission_policy, state.policy)
      |> Keyword.put(:session_id, state.session_id)
```

- [ ] **Step 5: Pass session_id in compaction params (generate_summary)**

In `generate_summary/2`, update the `params` map:

```elixir
    params = %{
      model: state.model,
      session_id: state.session_id,
      context: %{
        messages: [%{role: :user, content: [%{type: :text, text: prompt}]}],
        system_prompt: nil,
        tools: []
      },
      options: state.provider_options
    }
```

- [ ] **Step 6: Pass session_id from SessionManager.start_agent**

In `apps/ex_pi_web/lib/ex_pi_web/session_manager.ex`, update `start_agent/3`:

```elixir
  defp start_agent(session_id, opts, state) do
    agent_opts = Keyword.put(opts, :session_id, session_id)
    case DynamicSupervisor.start_child(PiWeb.AgentSupervisor, {PiAgent, agent_opts}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        policy_pid = PiAgent.get_policy(pid)
        entry = {pid, policy_pid, ref}
        {:reply, {:ok, {pid, policy_pid}}, put_in(state.agents[session_id], entry)}

      error ->
        {:reply, error, state}
    end
  end
```

- [ ] **Step 7: Run existing tests to confirm no regressions**

Run: `mix test apps/ex_pi_agent/ apps/ex_pi_web/`
Expected: all existing tests pass.

- [ ] **Step 8: Commit**

```bash
git add apps/ex_pi_agent/lib/ex_pi_agent.ex \
        apps/ex_pi_web/lib/ex_pi_web/session_manager.ex
git commit -m "feat(logs): thread session_id through PiAgent state, provider params, and dispatcher opts"
```

---

## Task 6: LLM telemetry emission in Anthropic provider

**Files:**
- Modify: `apps/ex_pi_ai/lib/ex_pi_ai/providers/anthropic.ex`
- Modify: `apps/ex_pi_ai/mix.exs`

- [ ] **Step 1: Add telemetry dep to ex_pi_ai**

In `apps/ex_pi_ai/mix.exs`, add to `deps/0`:

```elixir
      {:telemetry, "~> 1.0"},
```

- [ ] **Step 2: Extract the Stream.resource into a private function**

In `apps/ex_pi_ai/lib/ex_pi_ai/providers/anthropic.ex`, extract the entire `Elixir.Stream.resource(fn -> ... end, fn ... end, fn _ -> :ok end)` block in `stream/1` into a new private function:

```elixir
  defp build_inner_stream(model, body, headers, options) do
    Elixir.Stream.resource(
      fn ->
        # ... exact same start_fun as before ...
      end,
      fn
        # ... exact same next_fun as before ...
      end,
      fn _ -> :ok end
    )
  end
```

- [ ] **Step 3: Wrap with Stream.transform to inject telemetry**

Replace the `stream/1` body to call `build_inner_stream/4` and wrap it:

```elixir
  @impl true
  def stream(params) do
    model = params.model
    context = params.context
    options = params.options
    session_id = Map.get(params, :session_id)

    api_key = options[:api_key] || System.get_env("ANTHROPIC_AUTH_TOKEN")
    base_url =
      options[:base_url] || System.get_env("ANTHROPIC_BASE_URL") || "https://api.anthropic.com"

    system = build_system(context[:system_prompt])
    body = %{
      model: model.id,
      messages: transform_messages(context.messages),
      system: system,
      max_tokens: options[:max_tokens] || 4096,
      stream: true
    }
    body = if context[:tools], do: Map.put(body, :tools, transform_tools(context.tools)), else: body

    {body, extra_betas} =
      case options[:thinking_budget] do
        budget when is_integer(budget) and budget > 0 ->
          body =
            body
            |> Map.put(:thinking, %{type: "enabled", budget_tokens: budget})
            |> Map.update!(:max_tokens, &max(&1, budget + 1000))
          {body, ["interleaved-thinking-2025-05-14"]}
        _ ->
          {body, []}
      end

    beta_value = (["prompt-caching-2024-07-31"] ++ extra_betas) |> Enum.join(",")
    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"},
      {"anthropic-beta", beta_value}
    ]

    inner = build_inner_stream(model, body, headers, options)

    Elixir.Stream.transform(
      inner,
      fn ->
        :telemetry.execute(
          [:ex_pi, :llm, :request, :start],
          %{system_time: System.system_time()},
          %{
            session_id: session_id,
            model: model.id,
            provider: "anthropic",
            request_body: body
          }
        )
        System.monotonic_time()
      end,
      fn event, start_time ->
        case event do
          {:done, _stop_reason, ai_msg} ->
            :telemetry.execute(
              [:ex_pi, :llm, :request, :stop],
              %{duration: System.monotonic_time() - start_time},
              %{
                session_id: session_id,
                model: model.id,
                usage: ai_msg.usage,
                response_content: ai_msg.content
              }
            )
            {[event], start_time}

          _ ->
            {[event], start_time}
        end
      end,
      fn _start_time -> :ok end
    )
  end
```

- [ ] **Step 4: Run full test suite to confirm no regressions**

Run: `mix test`
Expected: all existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/ex_pi_ai/lib/ex_pi_ai/providers/anthropic.ex apps/ex_pi_ai/mix.exs
git commit -m "feat(logs): emit LLM request telemetry from Anthropic provider"
```

---

## Task 7: Tool and permission telemetry in ex_pi_coding

**Files:**
- Modify: `apps/ex_pi_coding/lib/ex_pi_coding/dispatcher.ex`
- Modify: `apps/ex_pi_coding/lib/ex_pi_coding/permission_interceptor.ex`
- Modify: `apps/ex_pi_coding/mix.exs`

- [ ] **Step 1: Add telemetry dep to ex_pi_coding**

In `apps/ex_pi_coding/mix.exs`, add to `deps/0`:

```elixir
      {:telemetry, "~> 1.0"},
```

- [ ] **Step 2: Emit tool telemetry in Dispatcher**

In `apps/ex_pi_coding/lib/ex_pi_coding/dispatcher.ex`, replace `do_dispatch/3`:

```elixir
  defp do_dispatch(tool_call, tools, opts) do
    session_id = Keyword.get(opts, :session_id)

    case PiCoding.PermissionInterceptor.check(tool_call, opts) do
      :allow ->
        tool = Enum.find(tools, fn t -> t.name() == tool_call.name end)

        if tool do
          :telemetry.execute(
            [:ex_pi, :tool, :call, :start],
            %{system_time: System.system_time()},
            %{session_id: session_id, tool_name: tool_call.name, arguments: tool_call.arguments}
          )

          start = System.monotonic_time()

          result =
            try do
              tool.execute(tool_call.id, tool_call.arguments, opts)
            rescue
              e -> {:error, Exception.message(e)}
            catch
              kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
            end

          :telemetry.execute(
            [:ex_pi, :tool, :call, :stop],
            %{duration: System.monotonic_time() - start},
            %{session_id: session_id, tool_name: tool_call.name, result: inspect(result)}
          )

          result
        else
          {:error, "Tool #{tool_call.name} not found"}
        end

      {:deny, reason} ->
        {:error, reason}
    end
  end
```

> **Note:** The `:result` in tool `:stop` metadata uses `inspect(result)` rather than the raw tuple. This prevents `Jason.encode!` failures in the UI when rendering tuples like `{:ok, %{content: [...]}}`.

- [ ] **Step 3: Emit permission telemetry in PermissionInterceptor**

In `apps/ex_pi_coding/lib/ex_pi_coding/permission_interceptor.ex`, rename the existing `check/2` body to `do_check/2` and wrap it:

```elixir
  def check(tool_call, opts) do
    session_id = Keyword.get(opts, :session_id)

    :telemetry.execute(
      [:ex_pi, :permission, :check, :start],
      %{system_time: System.system_time()},
      %{session_id: session_id, tool_name: tool_call.name}
    )

    result = do_check(tool_call, opts)

    :telemetry.execute(
      [:ex_pi, :permission, :check, :stop],
      %{},
      %{session_id: session_id, tool_name: tool_call.name, result: inspect(result)}
    )

    result
  end

  defp do_check(tool_call, opts) do
    policy = Keyword.get(opts, :permission_policy)

    cond do
      policy && (is_pid(policy) || (is_atom(policy) && Process.whereis(policy))) ->
        case PermissionPolicy.check(policy, tool_call.name) do
          :allow -> :allow
          :deny -> {:deny, "Permission denied by policy for tool: #{tool_call.name}"}
          :ask ->
            request_fn = Keyword.get(opts, :permission_request_fn)
            if request_fn do
              request_fn.(tool_call)
            else
              {:deny, "Permission required for tool '#{tool_call.name}' but no request function provided"}
            end
        end

      Keyword.has_key?(opts, :allow_tool) ->
        allowed = Keyword.get(opts, :allow_tool)
        if tool_call.name == allowed or (is_list(allowed) and tool_call.name in allowed) do
          :allow
        else
          {:deny, "Permission denied for tool: #{tool_call.name}"}
        end

      true ->
        :allow
    end
  end
```

- [ ] **Step 4: Run full test suite**

Run: `mix test`
Expected: all existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/ex_pi_coding/lib/ex_pi_coding/dispatcher.ex \
        apps/ex_pi_coding/lib/ex_pi_coding/permission_interceptor.ex \
        apps/ex_pi_coding/mix.exs
git commit -m "feat(logs): emit tool call and permission telemetry"
```

---

## Task 8: Wire ex_pi_web — session lifecycle + log state

**Files:**
- Modify: `apps/ex_pi_web/mix.exs`
- Modify: `apps/ex_pi_web/lib/ex_pi_web/live/session_live.ex`

> **Toggle event routing note:** The appbar button fires `phx-click="toggle_logs"` with no `phx-target` → handled by `handle_event("toggle_logs", ...)` in `SessionLive`. The close button inside the drawer fires to the component (via `phx-target={@myself}`) → component calls `send(self(), {:toggle_logs})` → handled by `handle_info({:toggle_logs}, ...)` in `SessionLive`. Both clauses must exist.

> **Live entries cap note:** New entries arriving via PubSub are capped at 500 in the socket assign (matching the ETS buffer cap). When a filter/search is applied, results come directly from ETS via `PiLogs.search/2`, which also returns up to 500 entries.

- [ ] **Step 1: Add ex_pi_logs dep to ex_pi_web**

In `apps/ex_pi_web/mix.exs`, add to `deps/0`:

```elixir
      {:ex_pi_logs, in_umbrella: true},
```

- [ ] **Step 2: Start the log buffer and subscribe on session mount**

In `apps/ex_pi_web/lib/ex_pi_web/live/session_live.ex`, inside the `connected?(socket)` block:

```elixir
        if connected?(socket) do
          Phoenix.PubSub.subscribe(PiWeb.PubSub, "session:#{session_id}")
          Phoenix.PubSub.subscribe(PiWeb.PubSub, "ex_pi:logs:#{session_id}")
          PiLogs.start_session(session_id)
        end
```

- [ ] **Step 3: Add log-related assigns to socket**

In the socket assign chain in `mount/3`:

```elixir
          |> assign(:logs_available, true)
          |> assign(:show_logs, false)
          |> assign(:log_entries, [])
          |> assign(:log_filter, nil)
          |> assign(:log_search, "")
```

- [ ] **Step 4: Handle incoming log entries via PubSub**

```elixir
  @impl true
  def handle_info({:log_entry, entry}, socket) do
    entries = [entry | socket.assigns.log_entries] |> Enum.take(500)
    {:noreply, assign(socket, :log_entries, entries)}
  end
```

- [ ] **Step 5: Handle toggle from appbar button (handle_event)**

```elixir
  @impl true
  def handle_event("toggle_logs", _params, socket) do
    {:noreply, assign(socket, :show_logs, !socket.assigns.show_logs)}
  end
```

- [ ] **Step 6: Handle toggle from drawer close button (handle_info)**

```elixir
  @impl true
  def handle_info({:toggle_logs}, socket) do
    {:noreply, assign(socket, :show_logs, !socket.assigns.show_logs)}
  end
```

- [ ] **Step 7: Handle log filter events**

```elixir
  @impl true
  def handle_event("set_log_filter", %{"category" => cat}, socket) do
    category = if cat == "", do: nil, else: String.to_existing_atom(cat)
    entries = PiLogs.search(socket.assigns.session_id, category: category, text: socket.assigns.log_search)
    {:noreply, socket |> assign(:log_filter, category) |> assign(:log_entries, entries)}
  end

  @impl true
  def handle_event("set_log_search", %{"query" => q}, socket) do
    entries = PiLogs.search(socket.assigns.session_id, category: socket.assigns.log_filter, text: q)
    {:noreply, socket |> assign(:log_search, q) |> assign(:log_entries, entries)}
  end
```

- [ ] **Step 8: Clean up buffer on terminate**

```elixir
  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:session_id] do
      PiLogs.stop_session(socket.assigns.session_id)
    end
  end
```

- [ ] **Step 9: Run mix deps.get and compile**

Run: `mix deps.get && mix compile`
Expected: no errors.

- [ ] **Step 10: Commit**

```bash
git add apps/ex_pi_web/mix.exs apps/ex_pi_web/lib/ex_pi_web/live/session_live.ex
git commit -m "feat(logs): wire log buffer lifecycle and assigns into SessionLive"
```

---

## Task 9: LogDrawer LiveComponent

**Files:**
- Create: `apps/ex_pi_web/lib/ex_pi_web/live/log_drawer_live.ex`

> **phx-target note:** Filter and search buttons inside the component do NOT set `phx-target`. Events without `phx-target` bubble up to the parent LiveView by default — exactly where `handle_event("set_log_filter", ...)` and `handle_event("set_log_search", ...)` are defined. Only the close button sets `phx-target={@myself}` because it needs to route to the component's own `handle_event`.

> **Metadata rendering note:** Entry metadata uses `inspect/1` (not `Jason.encode!/1`) in the `<pre>` block. Metadata can contain Elixir-only terms like tuples (`{:ok, result}`) that Jason cannot encode. `inspect/1` always succeeds.

- [ ] **Step 1: Create the LogDrawer LiveComponent**

```elixir
# apps/ex_pi_web/lib/ex_pi_web/live/log_drawer_live.ex
defmodule PiWeb.LogDrawerLive do
  use PiWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed right-0 top-0 h-full w-[480px] z-50 bg-surface text-surface-content shadow-xl flex flex-col border-l border-outline/20"
    >
      <%!-- Header --%>
      <div class="flex items-center justify-between px-4 py-3 border-b border-outline/20 bg-surface-variant">
        <span class="font-semibold text-sm">Debug Logs</span>
        <button
          phx-click="toggle_logs"
          phx-target={@myself}
          class="text-surface-content/60 hover:text-surface-content"
        >
          <.dm_mdi name="close" class="w-5 h-5" />
        </button>
      </div>

      <%!-- Filters --%>
      <div class="flex items-center gap-2 px-4 py-2 border-b border-outline/20 flex-wrap">
        <button
          :for={{cat, label} <- [llm: "LLM", tool: "Tool", permission: "Permission"]}
          phx-click="set_log_filter"
          phx-value-category={if @filter == cat, do: "", else: cat}
          class={[
            "px-2 py-1 rounded text-xs font-medium transition-colors",
            @filter == cat && category_active_class(cat),
            @filter != cat && "bg-surface-variant text-surface-content/60 hover:text-surface-content"
          ]}
        >
          {label}
        </button>
        <input
          type="text"
          placeholder="Search…"
          value={@search}
          phx-keyup="set_log_search"
          phx-key="Enter"
          phx-value-query={@search}
          class="ml-auto text-xs px-2 py-1 rounded bg-surface-variant border border-outline/20 focus:outline-none focus:border-primary w-36"
        />
      </div>

      <%!-- Entry list --%>
      <div class="flex-1 overflow-y-auto divide-y divide-outline/10">
        <div :for={entry <- @entries} class="px-4 py-2 hover:bg-surface-variant/50">
          <div class="flex items-center gap-2 mb-1">
            <span class={["px-1.5 py-0.5 rounded text-[10px] font-bold uppercase", category_badge_class(entry.category)]}>
              {entry.category}
            </span>
            <span class="text-xs text-surface-content/50 font-mono">{entry.event}</span>
            <span class="ml-auto text-[10px] text-surface-content/40 font-mono">
              {format_ts(entry.timestamp)}
            </span>
          </div>
          <details class="text-xs">
            <summary class="cursor-pointer text-surface-content/60 hover:text-surface-content select-none">
              {summarize(entry)}
            </summary>
            <pre class="mt-1 p-2 bg-surface-variant rounded text-[10px] overflow-x-auto whitespace-pre-wrap break-all"><%= inspect(entry.metadata, pretty: true, limit: :infinity) %></pre>
          </details>
        </div>
        <div :if={@entries == []} class="px-4 py-8 text-center text-sm text-surface-content/40">
          No log entries yet.
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_logs", _params, socket) do
    send(self(), {:toggle_logs})
    {:noreply, socket}
  end

  defp category_badge_class(:llm), do: "bg-primary/20 text-primary"
  defp category_badge_class(:tool), do: "bg-secondary/20 text-secondary"
  defp category_badge_class(:permission), do: "bg-warning/20 text-warning"
  defp category_badge_class(_), do: "bg-surface-variant text-surface-content/60"

  defp category_active_class(:llm), do: "bg-primary/20 text-primary"
  defp category_active_class(:tool), do: "bg-secondary/20 text-secondary"
  defp category_active_class(:permission), do: "bg-warning/20 text-warning"
  defp category_active_class(_), do: "bg-surface-variant text-surface-content"

  defp format_ts(ts) do
    ts
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S.%f")
    |> String.slice(0, 12)
  end

  defp summarize(%{category: :llm, event: :request_start, metadata: m}),
    do: "→ #{m[:model]} (#{map_size(m[:request_body] || %{})} body fields)"

  defp summarize(%{category: :llm, event: :request_stop, metadata: m}),
    do: "← #{m[:model]} | #{(m[:usage] || %{}) |> Map.get(:output, 0)} output tokens"

  defp summarize(%{category: :tool, event: :call_start, metadata: m}),
    do: "→ #{m[:tool_name]}"

  defp summarize(%{category: :tool, event: :call_stop, metadata: m}),
    do: "← #{m[:tool_name]}"

  defp summarize(%{category: :permission, metadata: m}),
    do: "permission check: #{m[:tool_name]}"

  defp summarize(entry), do: inspect(entry.event)
end
```

- [ ] **Step 2: Compile and verify no errors**

Run: `mix compile`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add apps/ex_pi_web/lib/ex_pi_web/live/log_drawer_live.ex
git commit -m "feat(logs): add LogDrawer LiveComponent"
```

---

## Task 10: Appbar icon + drawer rendering in SessionLive

**Files:**
- Modify: `apps/ex_pi_web/lib/ex_pi_web/layouts/app.html.heex`
- Modify: `apps/ex_pi_web/lib/ex_pi_web/live/session_live.ex` (template portion)

> **Appbar assign access note:** The appbar layout is shared across all LiveViews. Only `SessionLive` assigns `:logs_available` and `:show_logs`. Use `assigns[:logs_available]` (bracket access returning `nil`) NOT `@logs_available` (which crashes if the assign is absent). This pattern suppresses the button on HomeLive, SettingsLive, etc. without requiring those views to set a default.

- [ ] **Step 1: Add conditional logs button to appbar**

In `apps/ex_pi_web/lib/ex_pi_web/layouts/app.html.heex`, inside the `<:user_profile>` slot, before `<.dm_theme_switcher>`:

```heex
<%= if assigns[:logs_available] do %>
  <.dm_tooltip content="Debug Logs" position="bottom">
    <button
      phx-click="toggle_logs"
      class={[
        "flex items-center justify-center p-2 rounded-full hover:bg-primary-content/10 transition-colors",
        assigns[:show_logs] && "text-primary-content bg-primary-content/20",
        !assigns[:show_logs] && "text-primary-content/70 hover:text-primary-content"
      ]}
    >
      <.dm_mdi name={if assigns[:show_logs], do: "bug", else: "bug-outline"} class="w-6 h-6" />
    </button>
  </.dm_tooltip>
<% end %>
```

- [ ] **Step 2: Render LogDrawer in SessionLive template**

In the `session_live.ex` template (either inline `~H"""` block or `.html.heex` — find which is used), add at the end before the outermost closing tag:

```heex
<.live_component
  :if={@show_logs}
  module={PiWeb.LogDrawerLive}
  id="log-drawer"
  entries={@log_entries}
  filter={@log_filter}
  search={@log_search}
/>
```

- [ ] **Step 3: Start the dev server and manually verify**

Run: `mix phx.server`

Navigate to `http://localhost:4580`, open a session, send a prompt, then:
1. Confirm the bug icon appears in the appbar only on the session page (not on Home or Settings)
2. Click the bug icon — drawer opens on the right
3. Send a prompt — confirm LLM `:request_start` and `:request_stop` entries appear in real time
4. Confirm tool call entries appear when tools execute
5. Click a category filter button — only that category's entries show
6. Click the same filter again — filter clears, all entries show
7. Type in the search box and press Enter — entries filter by text
8. Click the × close button — drawer closes
9. Click the bug icon again — drawer reopens with same entries

- [ ] **Step 4: Commit**

```bash
git add apps/ex_pi_web/lib/ex_pi_web/layouts/app.html.heex \
        apps/ex_pi_web/lib/ex_pi_web/live/session_live.ex
git commit -m "feat(logs): add logs icon to appbar and render LogDrawer in SessionLive"
```

---

## Done

All tasks complete when:
- [ ] `mix test` passes with no failures
- [ ] `mix compile --warnings-as-errors` passes
- [ ] The debug logs drawer opens/closes from the appbar during a live session
- [ ] LLM, tool, and permission entries appear in real-time as the agent runs
- [ ] Category filter and text search narrow the displayed entries
- [ ] The logs icon does not appear on HomeLive or SettingsLive
