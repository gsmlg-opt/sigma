defmodule Sigma.Agent.BackplaneRootRetirementFunctionalTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Backplane.Store
  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Coding.Hooks.Spec
  alias Sigma.Coding.Hooks.Spec.Command
  alias Sigma.Session.Log

  @moduletag :tmp_dir
  @moduletag :host_retirement_functional

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def output_token_limit(_model, _options), do: 2_000

    def stream(request) do
      send(request.options[:test_pid], {:root_retirement_provider, self(), request})

      receive do
        {:root_retirement_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 7, output: 3, total_tokens: 10},
            model: "root-retirement",
            provider: "root-retirement",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  test "explicit root retirement captures cross-turn commands and every native generation once",
       %{
         tmp_dir: dir
       } do
    c = root!(dir, waiting_hook?: true)
    {provider, first_process, command} = retained_command!(prompt!(c), c, "first")
    finish!(provider)
    hook_process = process!(c.hook_pid_path)

    provider =
      call!(prompt!(c), "write_stdin", %{
        "session_id" => command,
        "chars" => "cross-turn\n",
        "yield_time_ms" => 0
      })

    result = result!(provider, "write_stdin")
    refute result.is_error
    assert value!(result)["session_id"] == command
    finish!(provider)
    assert File.exists?(first_process)
    first_host = only_host!(store!(c.path))
    assert map_size(first_host.bindings) == 2
    assert first_host.native == %{}

    assert {:ok, %{status: :confirmed}} =
             Subagents.close(Runtime.lookup(c.repo, "source", :subagents))

    refute File.exists?(first_process)
    {provider, final_process, _command} = retained_command!(prompt!(c), c, "rotated")
    finish!(provider)
    store = store!(c.path)
    host = only_host!(store)
    assert host.identity == first_host.identity
    assert map_size(host.bindings) == 3

    assert host.bindings
           |> Map.values()
           |> Enum.map(& &1.native_owner_id)
           |> Enum.uniq()
           |> length() == 2

    snapshots = runtime_bytes(c.path)
    assert map_size(snapshots) == 3
    assert {:ok, log} = Log.snapshot(c.path)
    assert host.identity.root_header_id == log.session_id
    assert host.identity.transcript_header_id == log.session_id
    assert host.identity.child_session_id == nil
    refute host.identity.host_lifetime_id == log.session_id

    assert {:ok, %{status: :confirmed, capture: :durable}} = Sigma.Agent.retire_host(c.agent)
    assert Process.alive?(c.agent)
    refute File.exists?(final_process)
    refute File.exists?(hook_process)
    assert_confirmed!(store, host)
    assert [%{"reason" => "other"}] = end_payloads(c)
    assert runtime_bytes(c.path) === snapshots
    ledger = ledger!(store)
    receipt = File.read!(receipt_path(c.path))

    # A late phase notification from a finished turn cannot reopen admission
    # after its host has already retired.
    GenServer.cast(c.agent, {:turn_phase, provider.request.turn_id, :streaming_provider})

    assert {:rejected, :session_busy} =
             Sigma.Agent.prompt(c.agent, "Cannot enter the retired lifetime")

    assert {:ok, %{status: :confirmed, capture: :durable}} = Sigma.Agent.retire_host(c.agent)
    assert ledger!(store) === ledger
    assert File.read!(receipt_path(c.path)) === receipt
    assert length(end_payloads(c)) == 1
    stop_session!(c)
    assert length(end_payloads(c)) == 1
    refute_receive {:root_retirement_provider, _, _}, 50
  end

  test "receipt retry preserves the original hook shutdown and SessionEnd effects", %{
    tmp_dir: dir
  } do
    c = root!(dir, waiting_hook?: true)
    {provider, process, _command} = retained_command!(prompt!(c), c, "retry")
    finish!(provider)
    hook_process = process!(c.hook_pid_path)
    store = store!(c.path)
    host = only_host!(store)
    snapshots = runtime_bytes(c.path)
    receipt = receipt_path(c.path)
    backup = receipt <> ".saved"
    File.rename!(receipt, backup)
    File.mkdir!(receipt)

    try do
      assert {:error, error} = Sigma.Agent.retire_host(c.agent)
      assert inspect(error) =~ "eisdir"
      assert Process.alive?(c.agent)
      refute File.exists?(process)
      refute File.exists?(hook_process)
      assert [%{"reason" => "other"}] = end_payloads(c)
      assert runtime_bytes(c.path) === snapshots
    after
      File.rmdir!(receipt)
      File.rename!(backup, receipt)
    end

    # These processes have exited. Retrying a strict shutdown or SessionEnd
    # instead of persisting their original acknowledgements would fail or repeat effects.
    assert {:ok, %{status: :confirmed, capture: :durable}} = Sigma.Agent.retire_host(c.agent)
    assert_confirmed!(store, host)
    assert runtime_bytes(c.path) === snapshots
    assert length(end_payloads(c)) == 1
    stop_session!(c)
    assert length(end_payloads(c)) == 1
  end

  test "normal session subtree shutdown captures root components before Store exits", %{
    tmp_dir: dir
  } do
    c = root!(dir, waiting_hook?: true)
    {provider, process, _command} = retained_command!(prompt!(c), c, "shutdown")
    finish!(provider)
    hook_process = process!(c.hook_pid_path)
    store = store!(c.path)
    host = only_host!(store)
    snapshots = runtime_bytes(c.path)
    stop_session!(c)
    refute Process.alive?(store)
    refute File.exists?(process)
    refute File.exists?(hook_process)
    assert [%{"reason" => "other"}] = end_payloads(c)

    reopened = start_supervised!({Store, path: c.path <> ".runtime"})
    assert_confirmed!(reopened, host)
    assert runtime_bytes(c.path) === snapshots
    assert :ok = Store.retire(reopened)
    refute_receive {:root_retirement_provider, _, _}, 50
  end

  test "active Provider shutdown still joins hooks and SessionEnd without claiming native retirement",
       %{tmp_dir: dir} do
    c = root!(dir, waiting_hook?: true)
    {provider, process, _command} = retained_command!(prompt!(c), c, "active-shutdown")
    hook_process = process!(c.hook_pid_path)
    store = store!(c.path)
    host = only_host!(store)
    provider_monitor = Process.monitor(provider.pid)
    agent_monitor = Process.monitor(c.agent)

    stop_session!(c)
    assert_receive {:DOWN, ^agent_monitor, :process, _, :shutdown}, 1_000
    assert_receive {:DOWN, ^provider_monitor, :process, _, _}, 1_000
    refute File.exists?(hook_process)
    refute File.exists?(process)
    assert [%{"reason" => "other"}] = end_payloads(c)

    reopened = start_supervised!({Store, path: c.path <> ".runtime"})
    actual = ledger!(reopened).hosts[host.identity.host_lifetime_id]
    assert actual.bindings == host.bindings
    assert actual.async_hooks == nil
    assert actual.session_end == nil

    for member <- Map.values(host.bindings),
        do: assert({:ok, %{status: :unconfirmed}} = Store.host_retirement(reopened, member))
  end

  test "SessionEnd preserves handler diagnostics separately from dispatch completion", %{
    tmp_dir: dir
  } do
    c = root!(dir, end_exit: 1)
    finish!(prompt!(c))
    store = store!(c.path)
    host = only_host!(store)
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
    actual = ledger!(store).hosts[host.identity.host_lifetime_id]
    assert actual.session_end.dispatch == :completed
    assert actual.session_end.outcome == :proceed
    assert Enum.any?(actual.session_end.warnings, &String.contains?(&1, "code 1"))
    assert length(end_payloads(c)) == 1
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
    assert length(end_payloads(c)) == 1
  end

  test "root Plan generations persist component receipts without replaying tool history", %{
    tmp_dir: dir
  } do
    c = root!(dir, waiting_hook?: true)

    provider =
      call!(prompt!(c), "update_plan", %{
        "plan" => [%{"step" => "First plan", "status" => "completed"}]
      })

    refute result!(provider, "update_plan").is_error
    finish!(provider)
    hook_process = process!(c.hook_pid_path)
    finish!(prompt!(c))
    store = store!(c.path)
    first = only_host!(store)
    assert map_size(first.bindings) == 2

    assert {:ok, %{status: :confirmed}} =
             Subagents.close(Runtime.lookup(c.repo, "source", :subagents))

    provider =
      call!(prompt!(c), "update_plan", %{
        "plan" => [%{"step" => "Next plan", "status" => "completed"}]
      })

    refute result!(provider, "update_plan").is_error
    finish!(provider)
    host = only_host!(store)
    assert host.identity == first.identity
    assert map_size(host.bindings) == 3

    assert host.bindings
           |> Map.values()
           |> Enum.map(& &1.native_owner_id)
           |> Enum.uniq()
           |> length() == 2

    snapshots = runtime_bytes(c.path)
    assert {:ok, %{status: :confirmed, capture: :durable}} = Sigma.Agent.retire_host(c.agent)
    assert_confirmed!(store, host)
    refute File.exists?(hook_process)
    assert length(end_payloads(c)) == 1
    assert runtime_bytes(c.path) === snapshots
    GenServer.cast(c.agent, {:turn_phase, provider.request.turn_id, :streaming_provider})

    assert {:rejected, :session_busy} =
             Sigma.Agent.prompt(c.agent, "Retired lifetime remains closed")

    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
    assert runtime_bytes(c.path) === snapshots
    assert length(end_payloads(c)) == 1
  end

  test "failed rename opens a fresh root lifetime and a later move never recreates the source", %{
    tmp_dir: dir
  } do
    c = root!(dir)
    finish!(prompt!(c))
    store = store!(c.path)
    original = only_host!(store)
    before = runtime_bytes(c.path)
    target = Path.join(c.sessions, "renamed.jsonl")
    File.write!(target, "occupied")

    assert {:error, :already_exists} =
             Runtime.rename_session(c.repo, "source", "renamed", c.sessions)

    assert Process.alive?(c.agent)
    assert File.read!(target) == "occupied"
    assert length(end_payloads(c)) == 1
    assert runtime_bytes(c.path) === before
    assert_confirmed!(store!(c.path), original)
    finish!(prompt!(c))
    ledger = ledger!(store!(c.path))
    assert map_size(ledger.hosts) == 2

    [fresh] =
      ledger.hosts
      |> Map.values()
      |> Enum.reject(&(&1.identity.host_lifetime_id == original.identity.host_lifetime_id))

    assert fresh.identity.root_header_id == original.identity.root_header_id
    assert fresh.identity.transcript_header_id == original.identity.transcript_header_id
    assert fresh.async_hooks == nil
    assert fresh.session_end == nil
    assert map_size(fresh.bindings) == 1
    assert fresh.native == %{}
    File.rm!(target)
    snapshots = runtime_bytes(c.path)

    assert {:ok, %{session_id: "renamed"}} =
             Runtime.rename_session(c.repo, "source", "renamed", c.sessions)

    refute Process.alive?(c.agent)
    assert length(end_payloads(c)) == 2
    refute File.exists?(c.path)
    refute File.exists?(c.path <> ".runtime")
    refute File.exists?(c.path <> ".subagents")
    assert runtime_bytes(target) === snapshots
    reopened = start_supervised!({Store, path: target <> ".runtime"})
    assert_confirmed!(reopened, original)
    assert_confirmed!(reopened, fresh)
    assert :ok = Store.retire(reopened)
    refute_receive {:root_retirement_provider, _, _}, 50
    refute File.exists?(c.path <> ".runtime")
  end

  defp root!(dir, opts \\ []) do
    repo = Path.join(dir, "repo")
    sessions = Path.join(repo, "sessions")
    path = Path.join(sessions, "source.jsonl")
    end_path = Path.join(dir, "session-end.jsonl")
    hook_pid_path = Path.join(dir, "async-hook.pid")
    File.mkdir_p!(sessions)
    end_script = Path.join(dir, "session-end.sh")

    File.write!(
      end_script,
      "cat >> #{quote_shell(end_path)}\nprintf '\\n' >> #{quote_shell(end_path)}\nprintf '{}'\nexit #{opts[:end_exit] || 0}\n"
    )

    specs = [hook(:session_end, end_script)]

    specs =
      if opts[:waiting_hook?] do
        script = Path.join(dir, "async-hook.sh")
        release = Path.join(dir, "async-hook.release")

        File.write!(
          script,
          "printf '%s\\n' \"$$\" > #{quote_shell(hook_pid_path)}\nwhile [ ! -e #{quote_shell(release)} ]; do sleep 0.01; done\n"
        )

        spec = hook(:session_start, script)
        [%{spec | handler: %{spec.handler | async: true, timeout_ms: 30_000}} | specs]
      else
        specs
      end

    on_exit(fn ->
      case Runtime.lookup(repo, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end

      Sigma.Agent.Backplane.GoalStore.retire(Path.join(path <> ".subagents", "goal"))
    end)

    assert {:ok, handle} =
             Runtime.get_session(repo, "source",
               cwd: repo,
               transcript_path: path,
               provider: Provider,
               model: %{
                 id: "root-retirement",
                 provider: "root-retirement",
                 api: "openai-responses"
               },
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               tools: [],
               hook_specs: specs,
               options: [test_pid: self()]
             )

    :ok = Sigma.Agent.subscribe(handle.agent)

    %{
      repo: repo,
      sessions: sessions,
      path: path,
      agent: handle.agent,
      handle: handle,
      end_path: end_path,
      hook_pid_path: hook_pid_path,
      dir: dir
    }
  end

  defp hook(event, script) do
    %Spec{
      event: event,
      matcher: :any,
      handler: %Command{cmd: "sh " <> quote_shell(script), timeout_ms: 1_000},
      origin: {:user, Path.dirname(script)},
      trusted?: true,
      dialect: :codex
    }
  end

  defp prompt!(c) do
    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "Perform actual root work")
    provider!()
  end

  defp retained_command!(provider, c, name) do
    path = Path.join(c.dir, name <> ".pid")

    provider =
      call!(provider, "exec_command", %{
        "cmd" =>
          "printf '%s\\n' \"$$\" > #{quote_shell(path)}; while IFS= read -r line; do printf '%s\\n' \"$line\"; done",
        "shell" => "/bin/sh",
        "login" => false,
        "yield_time_ms" => 0
      })

    result = result!(provider, "exec_command")
    refute result.is_error
    assert %{"status" => "running", "session_id" => command} = value!(result)
    {provider, process!(path), command}
  end

  defp call!(provider, name, arguments) do
    send(
      provider.pid,
      {:root_retirement_response,
       [
         %{
           type: :tool_call,
           id: "root-retirement-#{System.unique_integer([:positive])}",
           name: name,
           arguments: arguments,
           input_kind: :function
         }
       ]}
    )

    provider!()
  end

  defp provider! do
    receive do
      {:root_retirement_provider, pid, request} -> %{pid: pid, request: request}
      {:turn_error, error} -> flunk("root retirement turn failed: #{inspect(error)}")
    after
      8_000 -> flunk("actual root Provider did not start")
    end
  end

  defp finish!(provider) do
    send(provider.pid, {:root_retirement_response, [%{type: :text, text: "Finished"}]})
    assert_receive {:agent_end, _}, 8_000
  end

  defp result!(provider, name) do
    result =
      Enum.find(
        Enum.reverse(provider.request.context.messages),
        &(Map.get(&1, :tool_name) == name)
      )

    assert result
    result
  end

  defp value!(result) do
    assert [%{type: :text, text: json}] = result.content
    Jason.decode!(json)
  end

  defp store!(path) do
    assert {:ok, store} = Store.open(path: path <> ".runtime")
    store
  end

  defp ledger!(store) do
    assert {:ok, %{version: 2} = ledger} = Store.host_retirement(store, :all)
    ledger
  end

  defp only_host!(store) do
    assert [host] = ledger!(store).hosts |> Map.values()
    host
  end

  defp assert_confirmed!(store, original) do
    host = ledger!(store).hosts[original.identity.host_lifetime_id]
    assert host.identity == original.identity
    assert host.bindings == original.bindings
    assert host.async_hooks == %{status: :confirmed}

    assert host.session_end == %{
             status: :confirmed,
             dispatch: :completed,
             outcome: :proceed,
             warnings: []
           }

    assert map_size(host.native) ==
             host.bindings
             |> Map.values()
             |> Enum.map(&{&1.native_owner_id, &1.native_session_incarnation})
             |> Enum.uniq()
             |> length()

    for binding <- Map.values(host.bindings) do
      assert {:ok,
              %{
                status: :confirmed,
                native: %{status: :confirmed},
                async_hooks: %{status: :confirmed},
                session_end: end_receipt
              }} = Store.host_retirement(store, binding)

      assert end_receipt == host.session_end
    end
  end

  defp runtime_bytes(path) do
    Path.wildcard(Path.join(path <> ".runtime", "*.runtime"))
    |> Map.new(&{Path.basename(&1), File.read!(&1)})
  end

  defp receipt_path(path), do: Path.join(path <> ".runtime", "host-retirement.etf")

  defp end_payloads(c) do
    case File.read(c.end_path) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp stop_session!(c) do
    assert :ok =
             DynamicSupervisor.terminate_child(
               Runtime.lookup(c.repo, :sessions),
               c.handle.session_supervisor
             )

    refute Process.alive?(c.agent)
  end

  defp process!(path, attempts \\ 500)
  defp process!(_path, 0), do: flunk("actual command did not record its OS PID")

  defp process!(path, attempts) do
    case File.read(path) do
      {:ok, text} when text != "" ->
        assert {pid, ""} = text |> String.trim() |> Integer.parse()
        process = "/proc/#{pid}"
        assert File.exists?(process)
        process

      _ ->
        Process.sleep(10)
        process!(path, attempts - 1)
    end
  end

  defp quote_shell(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"
end
