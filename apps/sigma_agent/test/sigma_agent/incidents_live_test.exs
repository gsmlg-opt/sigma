defmodule Sigma.Agent.IncidentsLiveTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.{Incidents, Message, Runtime}
  alias Sigma.Agent.Backplane.ChildIO
  alias Sigma.Session.{Log, SessionFiles, Writer}

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      if params.options[:fail_provider] do
        raise Sigma.Ai.ProviderError,
          kind: :authentication,
          status: 401,
          code: "invalid_api_key",
          message: "private Provider key",
          raw: %{api_key: "private Provider key"}
      end

      {content, reason} =
        if Enum.any?(params.context.messages, &(&1.role == :tool_result)) do
          {[%{type: :text, text: "recovered tool failure"}], :stop}
        else
          {[%{type: :tool_call, id: "missing-call", name: "missing_fixture", arguments: %{}}],
           :tool_use}
        end

      message = %{
        role: :assistant,
        content: content,
        model: "test",
        provider: "test",
        api: "openai-responses",
        stop_reason: reason,
        usage: %{input: 1, output: 1, total_tokens: 2},
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, reason, message}]
    end
  end

  setup do
    directory =
      Path.join(System.tmp_dir!(), "sigma-live-incidents-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    identity = %{
      agent_id: "generation:grandchild",
      child_session_id: "grandchild-session",
      root_session_id: "root-session",
      run_id: "grandchild-run",
      public_run_id: "generation:grandchild-run",
      incarnation: 1,
      observer_incarnation: 1,
      agent_path: "/root/child/grandchild",
      parent_agent_id: "generation:child"
    }

    context =
      Incidents.context(Path.join(directory, "root.jsonl"), "root-header", %{
        kind: :child,
        id: identity.child_session_id,
        session_id: identity.child_session_id,
        agent_path: identity.agent_path
      })

    path = Path.join(directory, "root.jsonl.subagents/grandchild/session.jsonl")

    opts = [
      config: %{
        model: %{id: "mock", provider: "mock", api: "mock"},
        provider: __MODULE__,
        provider_options: [api_key: "private-provider-key"],
        cwd: directory,
        tools: [],
        dispatcher_opts: [],
        hook_specs: [],
        policy: nil
      },
      identity: identity,
      incident_context: context,
      transcript_path: path,
      backplane_store_path: Path.join(Path.dirname(path), "runtime")
    ]

    %{context: context, identity: identity, opts: opts, directory: directory}
  end

  test "nested child records only newly acknowledged results and reopening stays read only", c do
    historical = failure_message("historical-call")
    File.mkdir_p!(Path.dirname(c.opts[:transcript_path]))

    {:ok, writer} =
      Writer.start_link(
        storage_id: c.opts[:transcript_path],
        cwd: c.directory,
        session_id: c.identity.child_session_id
      )

    assert {:ok, _} = Writer.append(writer, {:agent_start, c.directory})
    assert {:ok, _} = Writer.append(writer, {:message_end, historical})
    GenServer.stop(writer)

    io = start_supervised!({ChildIO, c.opts})
    assert paths(c.context) == []
    prepared = prepare!(io, c.identity)
    assert paths(c.context) == []

    live = failure_message("live-call")
    assert :ok = ChildIO.project(io, prepared.key, [historical, live])
    [path] = paths(c.context)
    event = read!(path)
    assert event["subject"]["agent_path"] == "/root/child/grandchild"
    assert event["subject"]["session_id"] == "grandchild-session"
    assert event["root_header_id"] == "root-header"
    assert event["run_id"] == "generation:grandchild-run"
    assert event["tool_call_id"] == "live-call"
    assert event["error"] == %{"class" => "execution_failure"}
    refute File.read!(path) =~ "private"
    before = {File.read!(path), File.stat!(path, time: :posix)}

    assert :ok = ChildIO.project(io, prepared.key, [historical, live])
    assert {:error, _} = ChildIO.project(io, {"stale", 1}, [failure_message("stale")])
    assert :ok = stop_supervised(ChildIO)
    start_supervised!({ChildIO, c.opts})
    assert paths(c.context) == [path]
    assert {File.read!(path), File.stat!(path, time: :posix)} == before
  end

  test "live typed Provider failure without assistant output keeps its actual attempt", c do
    io = start_supervised!({ChildIO, c.opts})
    prepared = prepare!(io, c.identity)

    snapshot = %{
      failed_attempt: %{run_id: c.identity.run_id, attempt_id: "attempt-1"},
      error: Error.new(:timeout, "private Provider cause", cause: %{api_key: "private-token"})
    }

    assert :ok = ChildIO.prepare_provider_retry(io, prepared.key, snapshot)
    [path] = paths(c.context)
    event = read!(path)
    assert event["provider_attempt_id"] == "attempt-1"
    assert event["error"] == %{"class" => "timeout"}
    refute File.read!(path) =~ "private"
    before = {File.read!(path), File.stat!(path, time: :posix)}
    assert :ok = ChildIO.prepare_provider_retry(io, prepared.key, snapshot)
    assert {:error, _} = ChildIO.prepare_provider_retry(io, {"stale", 1}, snapshot)
    assert {File.read!(path), File.stat!(path, time: :posix)} == before
  end

  test "root Engine records an actual tool failure while the same turn continues", c do
    agent = root_agent!(c, [])
    assert {:accepted, %{turn_id: run_id}} = Sigma.Agent.prompt(agent, "use a missing fixture")
    assert_receive {:agent_end, _}, 10_000
    assert Sigma.Agent.status(agent).phase == :completed

    events = root_events(c.directory)
    assert [event] = Enum.filter(events, &(&1["kind"] == "tool_failure"))
    assert event["run_id"] == run_id
    assert event["tool_call_id"] == "missing-call"
    assert event["subject"]["agent_path"] == "/root"
    refute Enum.any?(events, &(&1["kind"] == "run_failed"))
  end

  test "root Engine records typed Provider failure without storing its raw payload", c do
    agent = root_agent!(c, fail_provider: true)
    assert {:accepted, %{turn_id: run_id}} = Sigma.Agent.prompt(agent, "fail the Provider")
    assert_receive {:agent_end, _}, 10_000
    assert_failed(agent, System.monotonic_time(:millisecond) + 5_000)

    events = root_events(c.directory)
    assert [event] = Enum.filter(events, &(&1["kind"] == "provider_failure"))
    assert event["run_id"] == run_id
    assert is_binary(event["provider_attempt_id"])
    assert event["error"]["class"] == "authentication"

    assert [runtime] = Enum.filter(events, &(&1["kind"] == "runtime_failure"))
    assert runtime["stage"] == "turn_failed"
    assert runtime["run_id"] == run_id
    assert runtime["error"]["class"] == "authentication"
    assert runtime["incident_id"] == event["incident_id"]

    for path <- Path.wildcard(Path.join(c.directory, ".incidents/*/*.json")) do
      refute File.read!(path) =~ "private Provider key"
    end
  end

  test "session file operations retain immutable incidents independently of transcript ownership",
       c do
    source = Path.join(c.directory, "source-sessions")
    target = Path.join(c.directory, "target-sessions")
    File.mkdir_p!(source)
    File.mkdir_p!(target)

    assert :ok = SessionFiles.create(source, "original", %{cwd: c.directory}, c.directory)
    assert {:ok, original_path} = SessionFiles.jsonl_path(source, "original")
    assert {:ok, snapshot} = Log.snapshot(original_path)
    header = snapshot.header["id"]
    context = Incidents.context(original_path, header)

    assert :ok =
             Incidents.record(context, %{
               kind: :runtime_failure,
               run_id: "old-run",
               stage: :turn_failed
             })

    [original_incident] = paths(context)
    original_bytes = File.read!(original_incident)
    original_identity = Map.take(File.stat!(original_incident), [:inode, :mtime, :size])

    assert :ok = SessionFiles.rename(source, "original", "renamed")
    assert {:ok, renamed_path} = SessionFiles.jsonl_path(source, "renamed")
    assert Incidents.context(renamed_path, header).directory == context.directory
    assert File.read!(original_incident) == original_bytes
    assert Map.take(File.stat!(original_incident), [:inode, :mtime, :size]) == original_identity

    assert :ok = SessionFiles.adopt(source, target, "renamed", c.directory)
    assert {:ok, adopted_path} = SessionFiles.jsonl_path(target, "renamed")
    assert {:ok, adopted} = Log.snapshot(adopted_path)
    assert adopted.header["id"] == header
    refute File.exists?(renamed_path)
    destination = Incidents.context(adopted_path, header)
    assert paths(destination) == []
    assert paths(context) == [original_incident]

    assert :ok =
             Incidents.record(destination, %{
               kind: :recovery_admitted,
               run_id: "old-run",
               source_run_id: "old-run",
               target_run_id: "new-run"
             })

    [destination_incident] = paths(destination)
    destination_bytes = File.read!(destination_incident)
    assert read!(destination_incident)["incident_id"] == read!(original_incident)["incident_id"]

    assert {:ok, fork_header} = SessionFiles.fork(target, "renamed", "forked", :all)
    refute fork_header == header
    assert {:ok, fork_path} = SessionFiles.jsonl_path(target, "forked")
    assert {:ok, forked} = Log.snapshot(fork_path)
    assert forked.header["id"] == fork_header
    assert forked.header["parentSession"] == header
    refute File.exists?(Incidents.context(fork_path, fork_header).directory)

    assert :ok = SessionFiles.delete(target, "renamed")
    assert :ok = SessionFiles.delete(target, "forked")
    refute File.exists?(adopted_path)
    refute File.exists?(fork_path)
    assert File.read!(original_incident) == original_bytes
    assert Map.take(File.stat!(original_incident), [:inode, :mtime, :size]) == original_identity
    assert File.read!(destination_incident) == destination_bytes
    assert paths(context) == [original_incident]
    assert paths(destination) == [destination_incident]
  end

  defp root_agent!(c, options) do
    on_exit(fn ->
      if pid = Runtime.lookup(c.directory, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
    end)

    assert {:ok, handle} =
             Runtime.get_session(c.directory, "incident-root",
               cwd: c.directory,
               transcript_path: Path.join(c.directory, "root.jsonl"),
               provider: Provider,
               model: %{id: "test", provider: "test", api: "openai-responses"},
               native_tools: true,
               native_memory_root: Path.join(c.directory, "memories"),
               tools: [],
               hook_specs: [],
               options: options
             )

    :ok = Sigma.Agent.subscribe(handle.agent)
    handle.agent
  end

  defp root_events(directory),
    do: directory |> Path.join(".incidents/*/*.json") |> Path.wildcard() |> Enum.map(&read!/1)

  defp assert_failed(agent, deadline) do
    phase = Sigma.Agent.status(agent).phase

    if phase == :failed or System.monotonic_time(:millisecond) >= deadline do
      assert phase == :failed
    else
      Process.sleep(20)
      assert_failed(agent, deadline)
    end
  end

  defp prepare!(io, identity) do
    authority = %{caller: "root", run_id: "root-run", grants: [], tool_revision: 1}
    assert {:ok, prepared} = ChildIO.prepare(io, identity, authority, [])
    prepared
  end

  defp failure_message(id) do
    %Message{
      id: "message-" <> id,
      role: :tool_result,
      tool_call_id: id,
      tool_name: "fixture",
      is_error: true,
      content: [%{type: :text, text: "private output"}],
      timestamp: System.system_time(:millisecond),
      metadata: %{
        structured_result: %{
          "error" => %{"class" => "execution_failure", "message" => "private cause"}
        }
      }
    }
  end

  defp paths(context), do: Path.wildcard(Path.join(context.directory, "*.json"))
  defp read!(path), do: path |> File.read!() |> Formata.JSON.decode!()
end
