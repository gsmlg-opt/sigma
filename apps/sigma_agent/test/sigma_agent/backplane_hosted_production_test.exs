defmodule Sigma.Agent.BackplaneHostedProductionTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Agent.Backplane.HostedTools
  alias Sigma.Ai.Providers.OpenAIResponses
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @model %{id: "hosted-model", provider: "hosted-provider", api: "openai-responses"}
  @enabled %{supported: true, enabled: true, mode: :cached}

  setup %{tmp_dir: dir} do
    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    :ok
  end

  test "real Runtime streams hosted observations and replays persisted native history after reopen",
       %{tmp_dir: dir} do
    with_server(fn base_url, server ->
      handle = session!(dir, base_url)
      assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Find a source")
      request = request!(server, 1)
      assert_declarations(request)
      events = finished!(handle.agent)

      assert Enum.any?(events, fn
               {:provider_hosted_event, "web_search", %{"type" => "response.output_item.done"}} ->
                 true

               _ ->
                 false
             end)

      [assistant] = Enum.filter(Sigma.Agent.messages(handle.agent), &(&1.role == :assistant))
      assert [%{type: :text, text: "Found it"}] = assistant.content
      assert is_nil(assistant.usage.input)
      assert is_nil(assistant.usage.output)
      assert is_nil(assistant.usage.input_tokens)
      envelope = assistant.metadata["openai_responses_hosted"]
      assert envelope["version"] == 1
      assert envelope["origin"]["provider"] == @model.provider
      assert envelope["origin"]["model"] == @model.id
      assert envelope["origin"]["endpoint_sha256"] =~ ~r/^[0-9a-f]{64}$/
      expected = native_output()

      assert envelope["items"] ==
               Enum.with_index(expected, fn item, index ->
                 %{"output_index" => index, "item" => item}
               end)

      assert {:ok, _checkpoint} = Writer.flush(handle.writer)
      journal = journal_messages(dir)
      persisted = Enum.find(journal, &(&1["role"] == "assistant"))
      assert persisted["metadata"]["openai_responses_hosted"] == envelope
      refute Enum.any?(journal, &(&1["role"] == "tool_result"))

      assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Follow up")
      follow_up = request!(server, 2)
      assert_declarations(follow_up)
      assert_native_history(follow_up, expected)
      finished!(handle.agent)
      assert {:ok, _checkpoint} = Writer.flush(handle.writer)

      supervisor = Runtime.lookup(dir, "hosted", :supervisor)
      monitor = Process.monitor(handle.agent)
      assert {:ok, %{retained_history?: false}} = Runtime.can_stop_session(dir, "hosted")

      assert :ok =
               DynamicSupervisor.terminate_child(Runtime.lookup(dir, :sessions), supervisor)

      assert_receive {:DOWN, ^monitor, :process, old_agent, _reason}, 5_000
      assert old_agent == handle.agent
      assert {:ok, snapshot} = Log.snapshot(transcript_path(dir))

      reopened =
        session!(dir, base_url,
          messages: snapshot.messages,
          context_messages: snapshot.context_messages,
          context_window: snapshot.context_window,
          active_leaf: snapshot.active_leaf_id,
          context_revision: length(snapshot.branch_entry_ids),
          context_source: :journal_replay
        )

      refute reopened.agent == handle.agent

      assert Enum.any?(Sigma.Agent.messages(reopened.agent), fn message ->
               message.metadata["openai_responses_hosted"] == envelope
             end)

      assert {:accepted, _} = Sigma.Agent.prompt(reopened.agent, "Continue after reopen")
      replayed = request!(server, 3)
      assert_declarations(replayed)
      assert_native_history(replayed, expected)
      finished!(reopened.agent)
      assert {:ok, _checkpoint} = Writer.flush(reopened.writer)
      refute Enum.any?(journal_messages(dir), &(&1["role"] == "tool_result"))
      refute_receive {:hosted_http, ^server, _index, _path, _body}, 100
    end)
  end

  test "changing provider identity, model or actual endpoint rejects hosted history before HTTP",
       %{tmp_dir: dir} do
    with_server(fn base_url, server ->
      with_server(fn other_url, other_server ->
        handle = session!(dir, base_url)
        assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Find a source")
        request!(server, 1)
        finished!(handle.agent)

        for {model, endpoint} <- [
              {%{@model | provider: "other-provider"}, base_url},
              {%{@model | id: "other-model"}, base_url},
              {@model, other_url}
            ] do
          assert {:ok, entry_id} =
                   Runtime.change_model(
                     dir,
                     "hosted",
                     model.provider,
                     model.id,
                     OpenAIResponses,
                     model,
                     provider_options(endpoint)
                   )

          assert is_binary(entry_id) and entry_id != ""
          assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Use changed origin")
          events = collect_turn()

          assert Enum.any?(events, fn
                   {:turn_error, %{kind: :invalid_request, message: message}} ->
                     message =~ "hosted_history_origin"

                   _ ->
                     false
                 end)

          assert Sigma.Agent.status(handle.agent).phase == :failed
          refute_local_effects(events)
          refute_receive {:hosted_http, ^server, _index, _path, _body}, 100
          refute_receive {:hosted_http, ^other_server, _index, _path, _body}, 100
        end
      end)
    end)
  end

  test "child configuration omits root hosted enablement while retaining ordinary provider options" do
    root = %{
      provider: OpenAIResponses,
      model: @model,
      native_tools: true,
      provider_options: [
        hosted_web_search: @enabled,
        api_key: "fixture",
        base_url: "http://127.0.0.1:4580"
      ],
      mcp_session: %{clients: %{}}
    }

    child = Subagents.configuration(root)
    refute Keyword.has_key?(child.provider_options, :hosted_web_search)
    assert child.provider_options[:api_key] == "fixture"
    assert child.provider_options[:base_url] == "http://127.0.0.1:4580"
    assert child.provider == OpenAIResponses
    assert child.native_tools

    assert {:ok, root_hosted} =
             HostedTools.configuration(root.provider, root.model, root.provider_options)

    assert {:ok, [%{type: "web_search"}]} =
             Backplane.AgentRuntime.Codex.Hosted.declarations(%{provider_hosted: root_hosted})

    assert {:ok, child_hosted} =
             HostedTools.configuration(child.provider, child.model, child.provider_options)

    assert is_nil(child_hosted)

    assert {:ok, []} =
             Backplane.AgentRuntime.Codex.Hosted.declarations(%{provider_hosted: child_hosted})
  end

  defp session!(dir, base_url, opts \\ []) do
    defaults = [
      cwd: dir,
      transcript_path: transcript_path(dir),
      provider: OpenAIResponses,
      model: @model,
      native_tools: true,
      native_memory_root: Path.join(dir, "memories"),
      tools: [],
      hook_specs: [],
      options: provider_options(base_url)
    ]

    assert {:ok, handle} = Runtime.get_session(dir, "hosted", Keyword.merge(defaults, opts))
    assert :ok = Sigma.Agent.subscribe(handle.agent)
    handle
  end

  defp provider_options(base_url),
    do: [
      base_url: base_url,
      api_key: "fixture",
      receive_timeout: 2_000,
      hosted_web_search: @enabled
    ]

  defp transcript_path(dir), do: Path.join(dir, "hosted.jsonl")

  defp journal_messages(dir) do
    dir
    |> transcript_path()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["type"] == "message"))
    |> Enum.map(& &1["message"])
  end

  defp assert_declarations(request) do
    assert Enum.filter(request["tools"], &(&1["type"] == "web_search")) == [
             %{"type" => "web_search", "external_web_access" => false}
           ]

    # Qualified local names become OpenAI namespace declarations on the wire.
    namespaces = Enum.filter(request["tools"], &(&1["type"] == "namespace"))
    assert [%{"tools" => clock}] = Enum.filter(namespaces, &(&1["name"] == "clock"))
    assert Enum.any?(clock, &(&1["name"] == "curr_time" and &1["type"] == "function"))

    local =
      Enum.filter(request["tools"], &(&1["type"] in ["function", "custom"])) ++
        Enum.flat_map(namespaces, & &1["tools"])

    assert Enum.all?(local, &(&1["type"] in ["function", "custom"]))
    assert Enum.any?(local, &(&1["name"] == "apply_patch"))
    refute Enum.any?(local, &(&1["name"] == "web_search"))
    refute Enum.any?(namespaces, &(&1["name"] == "web_search"))
  end

  defp assert_native_history(request, expected) do
    positions =
      Enum.map(expected, fn item ->
        assert Enum.count(request["input"], &(&1 == item)) == 1
        Enum.find_index(request["input"], &(&1 == item))
      end)

    assert positions == Enum.sort(positions)
    assert Enum.at(positions, 1) == hd(positions) + 1
  end

  defp finished!(agent) do
    events = collect_turn()
    refute Enum.any?(events, &match?({:turn_error, _}, &1))
    assert Sigma.Agent.status(agent).phase == :completed
    refute_local_effects(events)
    events
  end

  defp refute_local_effects(events) do
    refute Enum.any?(events, &match?({:hosted_http, _, _, _, _}, &1))

    refute Enum.any?(events, fn
             {:tool_execution_start, _, _, _} -> true
             {:tool_execution_end, _, _, _, _} -> true
             _ -> false
           end)
  end

  defp collect_turn(events \\ []) do
    receive do
      {:agent_end, _messages} = event -> Enum.reverse([event | events])
      event -> collect_turn([event | events])
    after
      8_000 -> flunk("Runtime did not finish the hosted turn")
    end
  end

  defp request!(server, index) do
    assert_receive {:hosted_http, ^server, ^index, "/responses", body}, 8_000
    body
  end

  defp native_output do
    [
      %{
        "type" => "reasoning",
        "id" => "rs1",
        "summary" => [%{"type" => "summary_text", "text" => "Check the source"}],
        "encrypted_content" => "opaque-persisted-reasoning"
      },
      %{
        "type" => "web_search_call",
        "id" => "ws1",
        "status" => "completed",
        "action" => %{"type" => "search", "query" => "example"}
      },
      %{
        "type" => "message",
        "id" => "msg1",
        "role" => "assistant",
        "status" => "completed",
        "content" => [
          %{
            "type" => "output_text",
            "text" => "Found it",
            "annotations" => [
              %{
                "type" => "url_citation",
                "start_index" => 0,
                "end_index" => 5,
                "url" => "https://example.com/source",
                "title" => "Source"
              }
            ]
          }
        ]
      }
    ]
  end

  defp response_frames(1) do
    output = native_output()

    [
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => hd(output)},
      %{"type" => "response.output_item.done", "output_index" => 1, "item" => Enum.at(output, 1)},
      %{"type" => "response.output_text.delta", "delta" => "Found it"},
      terminal(output, 1)
    ]
  end

  defp response_frames(index) do
    text = "Follow-up #{index}"

    output = [
      %{
        "type" => "message",
        "id" => "msg#{index}",
        "role" => "assistant",
        "status" => "completed",
        "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
      }
    ]

    [%{"type" => "response.output_text.delta", "delta" => text}, terminal(output, index)]
  end

  defp terminal(output, index) do
    %{
      "type" => "response.completed",
      "response" => %{"id" => "resp#{index}", "status" => "completed", "output" => output}
    }
  end

  defp with_server(fun) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    owner = self()
    server = make_ref()
    worker = Task.async(fn -> serve(listener, owner, server, 1) end)

    try do
      fun.("http://127.0.0.1:#{port}", server)
    after
      :gen_tcp.close(listener)
      Task.shutdown(worker, :brutal_kill)
    end
  end

  defp serve(listener, owner, server, index) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        try do
          request = receive_request(socket, "")
          [headers, request_body] = String.split(request, "\r\n\r\n", parts: 2)
          [_, path, _] = headers |> String.split("\r\n", parts: 2) |> hd() |> String.split(" ")
          send(owner, {:hosted_http, server, index, path, Jason.decode!(request_body)})

          body =
            Enum.map_join(response_frames(index), fn frame ->
              "data: " <> Jason.encode!(frame) <> "\n\n"
            end)

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n",
              "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
              body
            ])
        after
          :gen_tcp.close(socket)
        end

        serve(listener, owner, server, index + 1)

      {:error, :closed} ->
        :ok
    end
  end

  defp receive_request(socket, acc) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 2_000)
    acc = acc <> bytes

    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)

        if byte_size(body) >= String.to_integer(length),
          do: acc,
          else: receive_request(socket, acc)

      _ ->
        receive_request(socket, acc)
    end
  end
end
