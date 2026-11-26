defmodule Sigma.Agent.BackplaneProviderRetryTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Runtime
  alias Sigma.Ai.{ProviderError, ProviderEvent, ProviderUsage}
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir

  defmodule Provider do
    def stream_normalized(request) do
      if request.purpose == :compaction and request.options[:summary_progress] do
        Stream.concat(
          Stream.map(1..6, fn _ ->
            Process.sleep(50)
            %ProviderEvent{type: :response_activity}
          end),
          [
            %ProviderEvent{
              type: :response_completed,
              message: %{content: "Earlier work summarized."}
            }
          ]
        )
      else
        controlled_stream(request)
      end
    end

    defp controlled_stream(request) do
      Stream.resource(
        fn ->
          send(request.options[:test_pid], {:retry_provider, self(), request})
          nil
        end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule RejectFailedMessage do
    @behaviour Sigma.Session.Storage
    defdelegate read(path), to: Sigma.Session.Storage.JsonlFile
    defdelegate read_with_diagnostics(path), to: Sigma.Session.Storage.JsonlFile

    def append(_path, %{"type" => "message", "message" => %{"stop_reason" => reason}})
        when reason in [:error, "error"], do: {:error, :disk_full}

    def append(path, entry), do: Sigma.Session.Storage.JsonlFile.append(path, entry)
  end

  test "root retries only after preserving failed partial history and request metrics", c do
    handle = start_root(c)
    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Finish the task")
    assert_receive {:retry_provider, first, _}
    send(first, {:events, [failed()]})
    assert_receive {:retry_provider, next, request}, 2_000

    assert {:ok, snapshot} = Writer.context_snapshot(handle.writer)
    assert [%{role: :user}, partial] = snapshot.messages
    assert partial.stop_reason == :error
    assert {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(handle.path)
    failed_entry = Enum.find(entries, &(get_in(&1, ["message", "id"]) == partial.id))
    assert {:ok, original} = Sigma.Session.EntryDecoder.message(failed_entry)
    assert Enum.any?(original.content, &match?(%{type: :tool_call}, &1))
    assert partial.response_id == "interrupted-response"

    assert [%{role: :user}, %{role: :assistant, content: [%{type: :text, text: "partial"}]}] =
             request.context.messages

    send(next, {:events, [completed()]})
    assert_receive {:agent_end, _}, 3_000
    refute_received {:turn_error, _}
    assert {:ok, snapshot} = Log.snapshot(handle.path)
    assert length(snapshot.messages) == 3

    assert [%{status: :failed, output_tokens_total: 2}] =
             Enum.filter(Map.values(snapshot.metrics.requests), &(&1.status == :failed))

    # A cold projection preserves the original journal and cannot resurrect
    # unexecuted failed tool calls or fabricate tool results.
    before_bytes = File.read!(handle.path)
    projected = Sigma.Agent.ContextBuilder.build(messages: snapshot.context_messages).messages
    refute Enum.any?(projected, &(&1.role == :tool_result))
    refute Enum.any?(projected, &(inspect(&1.content) =~ "never-execute"))
    assert File.read!(handle.path) == before_bytes
  end

  test "root Writer failure prevents replacement Provider creation", c do
    handle = start_root(c, storage_mod: RejectFailedMessage)
    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Finish the task")
    assert_receive {:retry_provider, first, _}
    send(first, {:events, [failed()]})
    assert_receive {:agent_end, _}, 3_000
    refute_receive {:retry_provider, _, _}, 350
    assert {:ok, snapshot} = Log.snapshot(handle.path)
    assert Enum.all?(snapshot.messages, &(&1.role == :user))
  end

  test "invalid Anthropic tool JSON retries without replaying a settled command", c do
    marker = Path.join(c.tmp_dir, "settled-command")

    handle =
      start_root(c,
        native_tools: true,
        native_memory_root: Path.join(c.tmp_dir, "memories"),
        model: %{id: "retry", provider: "fixture", api: "openai-responses"}
      )

    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Finish")
    assert_receive {:retry_provider, first, _}, 5_000

    call = %{
      id: "settled-command",
      name: "exec_command",
      arguments: %{"cmd" => "printf x >> '#{marker}'"}
    }

    message = %{
      completed().message
      | stop_reason: :tool_use,
        content: [Map.put(call, :type, :tool_call)]
    }

    send(
      first,
      {:events,
       [
         %ProviderEvent{type: :tool_call_completed, tool_call: call, index: 0, message: message},
         %ProviderEvent{type: :response_completed, message: message}
       ]}
    )

    assert_receive {:retry_provider, second, _}, 10_000
    assert File.read!(marker) == "x"
    assert {:ok, settled} = Log.snapshot(handle.path)
    settled_results = Enum.filter(settled.messages, &(&1.role == :tool_result))
    assert [%{tool_call_id: "settled-command", is_error: false}] = settled_results
    original_prefix = File.read!(handle.path)

    error =
      ProviderError.malformed(%Backplane.AiProtocol.Error{
        kind: :upstream_error,
        stage: :observation,
        provider_code: "invalid_tool_arguments",
        retry_hint: :retryable,
        message: "Anthropic tool arguments are not complete JSON"
      })

    partial_json = ~s({"cmd": "printf never-execute |)

    partial = %{
      failed().message
      | content: [
          %{type: :text, text: "Continue after the saved result"},
          %{
            type: :tool_call,
            id: "truncated-command",
            name: "exec_command",
            partial_json: partial_json
          }
        ]
    }

    send(second, {:events, [%{failed() | error: error, retry: nil, message: partial}]})
    assert_receive {:retry_provider, replacement, request}, 3_000

    assert [projected_result] = Enum.filter(request.context.messages, &(&1.role == :tool_result))
    keys = [:content, :is_error, :tool_name, :tool_call_id]
    assert Map.take(projected_result, keys) == Map.take(hd(settled_results), keys)
    refute inspect(request.context.messages) =~ "never-execute"
    assert File.read!(marker) == "x"
    assert String.starts_with?(File.read!(handle.path), original_prefix)
    refute_received {:tool_execution_start, "truncated-command", _, _}

    send(replacement, {:events, [completed()]})
    assert_receive {:agent_end, _}, 5_000
    refute_received {:turn_error, _}
    assert {:ok, final} = Log.snapshot(handle.path)
    assert Enum.filter(final.messages, &(&1.role == :tool_result)) == settled_results
    assert Enum.count(Map.values(final.metrics.requests), &(&1.status == :failed)) == 1
    assert File.read!(marker) == "x"

    assert {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(handle.path)

    assert Enum.any?(entries, fn entry ->
             content = get_in(entry, ["message", "content"])

             is_list(content) and
               Enum.any?(content, fn block ->
                 is_map(block) and block["id"] == "truncated-command" and
                   block["partial_json"] == partial_json
               end)
           end)
  end

  test "root exposes the retry error while waiting and requesting until model progress", c do
    handle = start_root(c)
    assert {:accepted, %{turn_id: turn_id}} = Sigma.Agent.prompt(handle.agent, "Finish")
    assert_receive {:retry_provider, first, _}

    send(
      first,
      {:events,
       [
         %ProviderEvent{
           type: :response_failed,
           error: %ProviderError{
             kind: :timeout,
             message: "AI provider HTTP 504: Gateway Timeout",
             retry_class: :stream
           },
           retry: %{class: :stream, retry_after_ms: 500}
         }
       ]}
    )

    assert_receive {:provider_retry_scheduled,
                    %{
                      turn_id: ^turn_id,
                      retry_class: :stream,
                      retry_count: 1,
                      delay_ms: 500,
                      error: "AI provider HTTP 504: Gateway Timeout",
                      status: :waiting
                    } = retry},
                   2_000

    assert %{phase: :streaming_provider, provider_retry: ^retry} =
             Sigma.Agent.subscribe_snapshot(handle.agent)

    assert_receive {:retry_provider, next, _}, 2_000

    assert %{provider_retry: %{status: :requesting, error: error}} =
             Sigma.Agent.status(handle.agent)

    assert error == retry.error

    message = %{completed().message | content: [%{type: :text, text: "progress"}]}

    send(
      next,
      {:events, [%ProviderEvent{type: :content_text_delta, delta: "progress", message: message}]}
    )

    assert_receive {:message_update, _, _}, 2_000
    assert %{provider_retry: nil} = Sigma.Agent.status(handle.agent)

    send(next, {:events, [completed()]})
    assert_receive {:agent_end, _}, 3_000
    assert %{phase: :completed, provider_retry: nil} = Sigma.Agent.status(handle.agent)

    GenServer.cast(handle.agent, {:notify_subscribers, {:provider_retry_scheduled, retry}})
    assert %{phase: :completed, provider_retry: nil} = Sigma.Agent.status(handle.agent)

    assert {:accepted, %{turn_id: next_turn}} = Sigma.Agent.prompt(handle.agent, "Next task")
    assert next_turn != turn_id
    assert_receive {:retry_provider, worker, _}
    GenServer.cast(handle.agent, {:notify_subscribers, {:provider_retry_scheduled, retry}})
    assert %{turn_id: ^next_turn, provider_retry: nil} = Sigma.Agent.status(handle.agent)
    send(worker, {:events, [completed()]})
    assert_receive {:agent_end, _}, 3_000
  end

  test "a terminal partial tool call survives cold session loading without sampling", c do
    handle = start_root(c)
    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Finish")
    assert_receive {:retry_provider, worker, _}
    partial_json = ~s({"cmd": "printf unfinished |)

    partial = %{
      failed().message
      | content: [
          %{
            type: :tool_call,
            id: "unfinished",
            name: "exec_command",
            input_kind: :function,
            partial_json: partial_json
          }
        ]
    }

    send(
      worker,
      {:events,
       [
         %{
           failed()
           | error: ProviderError.malformed("Anthropic tool arguments are not complete JSON"),
             retry: nil,
             message: partial
         }
       ]}
    )

    assert_receive {:agent_end, _}, 3_000
    assert :ok = Sigma.Agent.retire_host(handle.agent)
    supervisor = Runtime.lookup(c.tmp_dir, :supervisor)
    assert :ok = DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
    original = File.read!(handle.path)

    assert {:ok, snapshot} = Log.snapshot(handle.path)
    assert [%{role: :user}, %{stop_reason: :error}] = snapshot.messages

    assert [%{role: :user, content: "Finish"}] =
             Sigma.Agent.ContextBuilder.build(messages: snapshot.context_messages).messages

    reopened = start_root(c)
    assert Process.alive?(reopened.agent)
    assert %{phase: :idle} = Sigma.Agent.status(reopened.agent)
    assert {:ok, selected} = Writer.selected_journal(reopened.writer)

    failed_entry =
      Enum.find(selected.entries, &(get_in(&1, ["message", "stop_reason"]) == "error"))

    assert {:ok, %{content: [decoded]}} = Sigma.Session.EntryDecoder.message(failed_entry)
    assert decoded.partial_json == partial_json
    refute Map.has_key?(decoded, :arguments)

    assert {:ok, nil} =
             Sigma.Agent.Backplane.PlanProjection.latest_entries(selected.entries,
               leaf_id: selected.leaf_id
             )

    refute_receive {:retry_provider, _, _}, 100
    assert File.read!(handle.path) == original
  end

  test "retry false keeps a stream failure terminal", c do
    handle = start_root(c, options: [test_pid: self(), retry: false])
    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Finish the task")
    assert_receive {:retry_provider, first, _}
    send(first, {:events, [failed()]})
    assert_receive {:agent_end, _}, 3_000
    assert_received {:turn_error, _}
    refute_receive {:retry_provider, _, _}, 350
    assert {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(handle.path)
    assert Enum.any?(entries, &(get_in(&1, ["message", "stop_reason"]) == "error"))
  end

  test "cancelling a root during retry backoff creates no replacement", c do
    handle = start_root(c)
    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Finish")
    assert_receive {:retry_provider, first, _}
    send(first, {:events, [failed()]})
    assert_receive {:provider_retry_scheduled, retry}
    assert %{provider_retry: ^retry} = Sigma.Agent.status(handle.agent)
    assert {:cancelling, _} = Sigma.Agent.cancel(handle.agent)
    assert %{provider_retry: nil} = Sigma.Agent.status(handle.agent)
    assert_receive {:agent_end, _}, 3_000
    refute_receive {:retry_provider, _, _}, 350
  end

  test "managed child retries after its failed partial Writer acknowledgement", c do
    child = start_child(c)
    assert {:ok, _} = Backplane.AgentRuntime.Conversation.prompt(child.conversation, "Finish")
    assert_receive {:retry_provider, first, _}
    send(first, {:events, [failed()]})
    assert_receive {:retry_provider, next, request}, 2_000
    assert {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(child.path)
    partial = Enum.find(entries, &(get_in(&1, ["message", "stop_reason"]) == "error"))
    assert partial
    assert Enum.any?(partial["message"]["content"], &(&1["type"] == "tool_call"))
    refute Enum.any?(request.context.messages, &(inspect(&1.content) =~ "never-execute"))
    assert Enum.any?(request.context.messages, &(inspect(&1.content) =~ "partial"))
    send(next, {:events, [completed()]})
    assert_receive {:agent_runtime, _, %{type: :run_completed}}, 3_000
    assert {:ok, snapshot} = Log.snapshot(child.path)
    assert length(snapshot.messages) == 3
  end

  test "managed child Writer failure prevents replacement Provider creation", c do
    child = start_child(c, storage_mod: RejectFailedMessage)
    assert {:ok, _} = Backplane.AgentRuntime.Conversation.prompt(child.conversation, "Finish")
    assert_receive {:retry_provider, first, _}
    send(first, {:events, [failed()]})
    assert_receive {:agent_runtime, _, %{type: :storage_failed}}, 3_000
    refute_receive {:retry_provider, _, _}, 350
    assert {:ok, snapshot} = Log.snapshot(child.path)
    assert Enum.all?(snapshot.messages, &(&1.role == :user))
  end

  test "cancelling a child during retry backoff creates no replacement", c do
    child = start_child(c)
    assert {:ok, _} = Backplane.AgentRuntime.Conversation.prompt(child.conversation, "Finish")
    assert_receive {:retry_provider, first, _}
    send(first, {:events, [failed()]})
    assert_receive {:agent_runtime, _, %{type: :provider_retry_scheduled}}, 2_000
    assert :ok = Backplane.AgentRuntime.Conversation.cancel(child.conversation)
    assert_receive {:agent_runtime, _, %{type: :run_cancelled}}, 3_000
    refute_receive {:retry_provider, _, _}, 350
  end

  test "managed child compaction progress renews its actual Provider idle allowance", c do
    history =
      Enum.flat_map(1..2, fn n ->
        [
          Sigma.Agent.Message.user("old-user-#{n}", "Earlier task"),
          Sigma.Agent.Message.assistant("old-assistant-#{n}", %{
            content: [%{type: :text, text: String.duplicate("earlier work ", 1500)}]
          })
        ]
      end)

    child =
      start_child(c,
        messages: history,
        model: %{id: "retry", provider: "fixture", api: "fixture", context_window: 4096},
        provider_options: [test_pid: self(), receive_timeout: 200, summary_progress: true]
      )

    assert {:ok, _} = Backplane.AgentRuntime.Conversation.prompt(child.conversation, "Continue")
    assert_receive {:retry_provider, worker, request}, 5_000
    assert request.purpose == :turn
    assert {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(child.path)
    assert Enum.any?(entries, &(&1["type"] == "compaction"))
    send(worker, {:events, [completed()]})
    assert_receive {:agent_runtime, _, %{type: :run_completed}}, 3_000
  end

  defp start_child(c, options \\ []) do
    alias Sigma.Agent.Backplane.ChildIO
    path = Path.join(c.tmp_dir, "child.jsonl")

    identity = %{
      agent_id: "generation:retry-child",
      child_session_id: "retry-child",
      root_session_id: "retry-root",
      run_id: "retry-child-run",
      public_run_id: "generation:retry-child-run",
      incarnation: 1,
      observer_incarnation: 1,
      agent_path: "/root/child",
      parent_agent_id: "generation:root"
    }

    config = %{
      model:
        Keyword.get(options, :model, %{
          id: "retry",
          provider: "fixture",
          api: "fixture",
          context_window: 65_536
        }),
      provider: Provider,
      provider_options: Keyword.get(options, :provider_options, test_pid: self()),
      cwd: c.tmp_dir,
      native_tools: false,
      tools: [],
      dispatcher_opts: [],
      hook_specs: [],
      policy: nil
    }

    opts = [
      config: config,
      identity: identity,
      transcript_path: path,
      backplane_store_path: path <> ".runtime"
    ]

    io = start_supervised!({ChildIO, Keyword.merge(opts, options)})
    authority = %{caller: "root", run_id: "root-run", grants: [], tool_revision: 1}
    assert {:ok, prepared} = ChildIO.prepare(io, identity, authority, [])

    conversation =
      start_supervised!(
        {Backplane.AgentRuntime.Conversation, Keyword.put(prepared.options, :subscriber, self())}
      )

    %{io: io, conversation: conversation, path: path}
  end

  defp start_root(c, options \\ []) do
    path = Path.join(c.tmp_dir, "retry-root.jsonl")

    defaults = [
      cwd: c.tmp_dir,
      transcript_path: path,
      provider: Provider,
      model: %{id: "retry", provider: "fixture", api: "fixture", context_window: 65_536},
      native_tools: false,
      tools: [],
      hook_specs: [],
      options: [test_pid: self()]
    ]

    assert {:ok, handle} =
             Runtime.get_session(c.tmp_dir, "retry-root", Keyword.merge(defaults, options))

    :ok = Sigma.Agent.subscribe(handle.agent)

    on_exit(fn ->
      case Runtime.lookup(c.tmp_dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    Map.put(handle, :path, path)
  end

  defp failed do
    %ProviderEvent{
      type: :response_failed,
      error: %ProviderError{
        kind: :transport_unavailable,
        message: "stream lost",
        retry_class: :stream
      },
      retry: %{class: :stream, retry_after_ms: nil},
      response_id: "interrupted-response",
      usage: ProviderUsage.from_map(%{input: 10, output: 2, total_tokens: 12}),
      message: %{
        role: :assistant,
        model: "retry",
        provider: "fixture",
        timestamp: System.system_time(:millisecond),
        stop_reason: :error,
        content: [
          %{type: :text, text: "partial"},
          %{type: :tool_call, id: "unfinished", name: "never-execute", arguments: %{}}
        ],
        response_id: "interrupted-response",
        usage: %{input: 10, output: 2, total_tokens: 12}
      }
    }
  end

  defp completed,
    do: %ProviderEvent{
      type: :response_completed,
      message: %{
        role: :assistant,
        content: [%{type: :text, text: "done"}],
        model: "retry",
        provider: "fixture",
        timestamp: System.system_time(:millisecond),
        stop_reason: :stop,
        usage: %{input: 10, output: 2, total_tokens: 12}
      }
    }
end
