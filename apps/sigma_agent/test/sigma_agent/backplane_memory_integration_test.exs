defmodule Sigma.Agent.BackplaneMemoryIntegrationTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Runtime

  @moduletag :tmp_dir
  @memory ~w(memories::add_ad_hoc_note memories::list memories::read memories::search)
  @filename "2026-10-25T12-30-00-user-preference.md"
  @path "extensions/ad_hoc/notes/" <> @filename

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:memory_provider, self(), params})

      receive do
        {:memory_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            model: "test",
            provider: "test",
            api: "openai-responses",
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2},
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} do
    previous = Application.fetch_env(:sigma_session, :agent_dir)
    agent_dir = Path.join(dir, "agent")
    File.mkdir_p!(agent_dir)
    Application.put_env(:sigma_session, :agent_dir, agent_dir)

    on_exit(fn ->
      stop_repository(dir)

      case Registry.lookup(
             Sigma.Agent.RepositoryRegistry,
             {:memory_resources, Path.join(agent_dir, "memories")}
           ) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
        [] -> :ok
      end

      case previous do
        {:ok, value} -> Application.put_env(:sigma_session, :agent_dir, value)
        :error -> Application.delete_env(:sigma_session, :agent_dir)
      end
    end)

    {:ok, dir: dir, memory_root: Path.join(agent_dir, "memories")}
  end

  test "actual Engine advertises four persistent Memory tools with explicit-write policy", ctx do
    agent = session!(ctx.dir, system_prompt: "Custom coding instructions.")
    prompt!(agent, "Inspect available capabilities")
    {provider, params} = provider!()
    names = Enum.map(params.context.tools, & &1.name)
    assert Enum.all?(@memory, &(&1 in names))
    assert "memories::search" in names
    assert params.context.system_prompt =~ "Custom coding instructions."
    assert params.context.system_prompt =~ "explicitly asks"
    assert params.context.system_prompt =~ "memories::add_ad_hoc_note"
    refute File.exists?(ctx.memory_root)
    finish!(provider)
  end

  test "direct Memory results persist across turns, fresh Sessions and runtime restart", ctx do
    agent = session!(ctx.dir)
    prompt!(agent, "Please remember my preference verbatim")
    {provider, _} = provider!()
    note = "# Preference\n\nKeep 中文 and CRLF.\r\n"

    provider =
      call!(provider, "memories::add_ad_hoc_note", %{"filename" => @filename, "note" => note})

    assert result!(agent) == %{"is_error" => false}
    assert File.read!(Path.join(ctx.memory_root, @path)) == note

    send_call(provider, "memories::read", %{"path" => @path, "line_offset" => 3})
    {provider, params} = provider!()
    assert result!(agent)["content"] == "Keep 中文 and CRLF.\r\n"
    assert result!(agent)["start_line_number"] == 3
    assert result!(agent)["truncated"] == false
    assert model_memory_read!(params) == result!(agent)
    finish!(provider)

    prompt!(agent, "Recall the preference")
    {provider, params} = provider!()
    assert model_memory_read!(params)["start_line_number"] == 3
    provider = call!(provider, "memories::read", %{"path" => @path})
    assert result!(agent)["content"] == note
    finish!(provider)

    fresh = session!(ctx.dir, session_id: "fresh-memory")
    prompt!(fresh, "Read the shared user memory")
    {provider, _} = provider!()
    provider = call!(provider, "memories::read", %{"path" => @path})
    assert result!(fresh)["content"] == note
    finish!(provider)

    stop_repository(ctx.dir)
    restarted = session!(ctx.dir, session_id: "restarted-memory")
    prompt!(restarted, "Read after runtime restart")
    {provider, _} = provider!()
    provider = call!(provider, "memories::read", %{"path" => @path})
    assert result!(restarted)["content"] == note
    finish!(provider)
  end

  test "real Code Mode shares one extension dispatcher with Skills and Memory", ctx do
    agent = session!(ctx.dir)
    prompt!(agent, "Please remember this explicit request")
    {provider, _} = provider!()

    code = """
    const created = await tools.memories__add_ad_hoc_note({filename: '#{@filename}', note: 'Nested memory 中文'});
    const read = await tools.memories__read({path: '#{@path}'});
    const skills = await tools.skills__list({authority: 'executor'});
    return {created, read, skills, names: ALL_TOOLS.map(tool => tool.tool_name)};
    """

    provider = call!(provider, "exec", code)
    result = result!(agent)
    assert result["status"] == "completed"
    assert result["value"]["created"] == %{}
    assert result["value"]["read"]["content"] == "Nested memory 中文"
    assert is_list(result["value"]["skills"]["skills"])
    assert Enum.all?(@memory, &(&1 in result["value"]["names"]))
    assert "memories::search" in result["value"]["names"]
    finish!(provider)
  end

  test "the existing permission gate denies a Memory mutation before file creation", ctx do
    agent = session!(ctx.dir, permission_config: %{default: :deny, rules: %{}})
    prompt!(agent, "Please remember this only if permitted")
    {provider, _} = provider!()

    provider =
      call!(provider, "memories::add_ad_hoc_note", %{
        "filename" => @filename,
        "note" => "Must not be written"
      })

    assert last_result!(agent).is_error
    assert last_result!(agent).metadata.structured_result["error"]["class"] == "forbidden"
    refute File.exists?(ctx.memory_root)
    finish!(provider)
  end

  test "a replacement generation keeps the Agent's original trusted memory root", ctx do
    agent = session!(ctx.dir)
    prompt!(agent, "Please remember the original root")
    {provider, _} = provider!()

    provider =
      call!(provider, "memories::add_ad_hoc_note", %{
        "filename" => @filename,
        "note" => "Original"
      })

    finish!(provider)

    replacement_dir = Path.join(ctx.dir, "replacement-agent")
    File.mkdir_p!(replacement_dir)
    Application.put_env(:sigma_session, :agent_dir, replacement_dir)

    prompt!(agent, "Cancel this generation")
    {provider, _} = provider!()
    send_call(provider, "clock::sleep", %{"duration_ms" => 60_000})
    assert_receive {:tool_execution_start, _, "clock::sleep", _}, 5_000
    assert {:cancelling, _} = Sigma.Agent.cancel(agent)
    assert_receive {:turn_cancelled}, 5_000

    prompt!(agent, "Read the original user memory")
    {provider, _} = provider!()
    provider = call!(provider, "memories::read", %{"path" => @path})
    assert result!(agent)["content"] == "Original"
    refute File.exists?(Path.join(replacement_dir, "memories"))
    finish!(provider)
  end

  test "a dead shared writer is not retried and the next run reconnects", ctx do
    agent = session!(ctx.dir)
    prompt!(agent, "Please remember this before a writer restart")
    {provider, _} = provider!()

    provider =
      call!(provider, "memories::add_ad_hoc_note", %{"filename" => @filename, "note" => "Durable"})

    [{writer, _}] =
      Registry.lookup(Sigma.Agent.RepositoryRegistry, {:memory_resources, ctx.memory_root})

    assert :ok = DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, writer)

    second = "2026-10-25T12-30-01-uncertain.md"

    send_call(provider, "memories::add_ad_hoc_note", %{
      "filename" => second,
      "note" => "Do not retry"
    })

    assert_receive {:turn_error, %{message: message}}, 8_000
    assert message =~ ":unknown_outcome"
    assert_receive {:agent_end, _}, 8_000
    refute File.exists?(Path.join(ctx.memory_root, "extensions/ad_hoc/notes/" <> second))
    prompt!(agent, "Read after writer restart")
    {provider, _} = provider!()
    provider = call!(provider, "memories::read", %{"path" => @path})
    assert result!(agent)["content"] == "Durable"

    [{replacement, _}] =
      Registry.lookup(Sigma.Agent.RepositoryRegistry, {:memory_resources, ctx.memory_root})

    refute replacement == writer
    refute File.exists?(Path.join(ctx.memory_root, "extensions/ad_hoc/notes/" <> second))
    finish!(provider)
  end

  defp session!(dir, opts \\ []) do
    {id, opts} = Keyword.pop(opts, :session_id, "memory")

    defaults = [
      cwd: dir,
      transcript_path: Path.join(dir, id <> ".jsonl"),
      provider: Provider,
      model: %{id: "test", provider: "test", api: "openai-responses"},
      native_tools: true,
      tools: [],
      hook_specs: [],
      options: [test_pid: self()]
    ]

    assert {:ok, handle} = Runtime.get_session(dir, id, Keyword.merge(defaults, opts))
    :ok = Sigma.Agent.subscribe(handle.agent)
    handle.agent
  end

  defp stop_repository(dir) do
    case Runtime.lookup(dir, :supervisor) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
    end
  end

  defp prompt!(agent, text), do: assert({:accepted, _} = Sigma.Agent.prompt(agent, text))

  defp provider! do
    assert_receive {:memory_provider, pid, params}, 10_000
    {pid, params}
  end

  defp call!(provider, name, arguments) do
    send_call(provider, name, arguments)
    {next, _} = provider!()
    next
  end

  defp send_call(provider, name, arguments) do
    send(
      provider,
      {:memory_response,
       [
         %{
           type: :tool_call,
           id: "memory-#{System.unique_integer([:positive])}",
           name: name,
           arguments: arguments,
           input_kind: if(is_binary(arguments), do: :custom, else: :function)
         }
       ]}
    )
  end

  defp last_result!(agent) do
    Sigma.Agent.messages(agent) |> Enum.reverse() |> Enum.find(&(&1.role == :tool_result))
  end

  defp model_memory_read!(params) do
    message =
      params.context.messages
      |> Enum.reverse()
      |> Enum.find(&(&1.role == :tool_result and &1.tool_name == "memories::read"))

    [%{type: :text, text: json}] = message.content
    Jason.decode!(json)
  end

  defp result!(agent) do
    result = last_result!(agent)
    refute result.is_error
    result.metadata.structured_result
  end

  defp finish!(provider) do
    send(provider, {:memory_response, [%{type: :text, text: "done"}]})
    assert_receive {:agent_end, _}, 8_000
  end
end
