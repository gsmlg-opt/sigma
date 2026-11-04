defmodule Sigma.Agent.BackplaneMemorySearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.ToolRegistry
  alias Backplane.AgentRuntime.Codex.Session
  alias Sigma.Agent.Backplane.MemoryResources
  alias Sigma.Agent.Runtime

  @moduletag :tmp_dir

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:search_provider, self(), params})

      receive do
        {:search_response, content} ->
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
    root = Path.join(agent_dir, "memories")
    File.mkdir_p!(root)
    Application.put_env(:sigma_session, :agent_dir, agent_dir)
    resources = start_supervised!({MemoryResources, root: root}, restart: :temporary)

    on_exit(fn ->
      stop_repository(dir)

      case previous do
        {:ok, value} -> Application.put_env(:sigma_session, :agent_dir, value)
        :error -> Application.delete_env(:sigma_session, :agent_dir)
      end
    end)

    {:ok, dir: dir, root: root, resources: resources, binding: binding!("search-first")}
  end

  test "default substring search preserves query order, sorted paths and CRLF line contexts",
       ctx do
    write!(ctx, "a.md", "intro\r\nbeta 中文\r\ngap\r\nalpha beta\r\n尾\r\n")
    write!(ctx, "nested/z.md", "alpha")

    assert {:ok, result} =
             search(ctx, %{"queries" => [" beta ", "alpha"], "context_lines" => 1})

    assert result.queries == ["beta", "alpha"]
    assert result.match_mode == %{"type" => "any"}
    assert result.path == nil
    assert result.next_cursor == nil
    assert result.truncated == false

    assert result.matches == [
             %{
               path: "a.md",
               match_line_number: 2,
               content_start_line_number: 1,
               content: "intro\nbeta 中文\ngap",
               matched_queries: ["beta"]
             },
             %{
               path: "a.md",
               match_line_number: 4,
               content_start_line_number: 3,
               content: "gap\nalpha beta\n尾",
               matched_queries: ["beta", "alpha"]
             },
             %{
               path: "nested/z.md",
               match_line_number: 1,
               content_start_line_number: 1,
               content: "alpha",
               matched_queries: ["alpha"]
             }
           ]
  end

  test "same-line and within-lines modes retain only minimal matching windows", ctx do
    write!(ctx, "windows.md", "alpha\nalpha\nbeta\nmiddle\nalpha beta\n")
    args = %{"queries" => ["beta", "alpha"], "path" => "windows.md"}

    assert {:ok, same_line} =
             search(ctx, Map.put(args, "match_mode", %{"type" => "all_on_same_line"}))

    assert Enum.map(same_line.matches, & &1.match_line_number) == [5]
    assert hd(same_line.matches).content == "alpha beta"

    mode = %{"type" => "all_within_lines", "line_count" => 3}

    assert {:ok, within_lines} =
             search(ctx, Map.merge(args, %{"match_mode" => mode, "context_lines" => 1}))

    assert within_lines.match_mode == mode
    assert Enum.map(within_lines.matches, & &1.match_line_number) == [2, 5]
    assert Enum.map(within_lines.matches, & &1.content_start_line_number) == [1, 4]

    assert Enum.map(within_lines.matches, & &1.content) == [
             "alpha\nalpha\nbeta\nmiddle",
             "middle\nalpha beta"
           ]

    assert Enum.all?(within_lines.matches, &(&1.matched_queries == ["beta", "alpha"]))
  end

  test "case folding and separator normalization preserve original Unicode content and queries",
       ctx do
    write!(ctx, "unicode.md", "mCp_服务\r\nCAFÉ--menu\r\nÉcole\r\n")
    queries = ["MCP-服务", "café menu", "école"]

    assert {:ok, result} =
             search(ctx, %{
               "queries" => queries,
               "case_sensitive" => false,
               "normalized" => true
             })

    assert result.queries == queries
    assert Enum.map(result.matches, & &1.content) == ["mCp_服务", "CAFÉ--menu", "École"]
    assert Enum.map(result.matches, & &1.matched_queries) == Enum.map(queries, &[&1])

    assert {:ok, exact} = search(ctx, %{"queries" => ["mCp_服务"]})
    assert [%{content: "mCp_服务", match_line_number: 1}] = exact.matches
  end

  test "directory and file paths select their actual recursive memory contents", ctx do
    write!(ctx, "root.md", "match root")
    write!(ctx, "folder/a.md", "match first")
    write!(ctx, "folder/deep/b.md", "match second")

    assert {:ok, directory} =
             search(ctx, %{"queries" => ["match"], "path" => "folder"})

    assert directory.path == "folder"
    assert Enum.map(directory.matches, & &1.path) == ["folder/a.md", "folder/deep/b.md"]

    assert {:ok, file} =
             search(ctx, %{"queries" => ["match"], "path" => "folder/deep/b.md"})

    assert [%{path: "folder/deep/b.md", content: "match second"}] = file.matches
  end

  test "separator normalization retains Unicode Alphabetic combining marks", ctx do
    mark = "\u0345"
    write!(ctx, "alphabetic.md", "a_#{mark}\nplain a\n")

    assert {:ok, result} =
             search(ctx, %{"queries" => ["a" <> mark], "normalized" => true})

    assert [%{content: content, match_line_number: 1}] = result.matches
    assert content == "a_" <> mark
  end

  test "default and maximum result pages contain 200 ordered matches and stable retries", ctx do
    write!(ctx, "pages.md", Enum.map_join(1..205, "\n", &"match #{&1}"))

    assert {:ok, default} = search(ctx, %{"queries" => ["match"]})
    assert length(default.matches) == 200
    assert default.truncated

    args = %{"queries" => ["match"], "max_results" => 500}
    assert {:ok, first} = search(ctx, args)
    assert Enum.map(first.matches, & &1.match_line_number) == Enum.to_list(1..200)
    assert first.truncated

    next_args = Map.put(args, "cursor", first.next_cursor)
    assert {:ok, second} = search(ctx, next_args)
    assert {:ok, ^second} = search(ctx, next_args)
    assert Enum.map(second.matches, & &1.match_line_number) == Enum.to_list(201..205)
    assert second.truncated == false
    assert second.next_cursor == nil
  end

  test "a reopened shared writer searches the same persisted memory bytes", ctx do
    contents = "before\nDurable 中文\nafter\n"
    write!(ctx, "durable.md", contents)
    args = %{"queries" => ["Durable"], "context_lines" => 1}
    assert {:ok, first} = search(ctx, args)
    GenServer.stop(ctx.resources)
    reopened = start_supervised!({MemoryResources, root: ctx.root}, id: :reopened_search)
    next = %{ctx | resources: reopened, binding: binding!("search-second")}

    assert {:ok, ^first} = search(next, args)
    assert File.read!(Path.join(ctx.root, "durable.md")) == contents
  end

  @tag timeout: 60_000
  test "actual Engine and real Code Mode retain complete search results across turns and Sessions",
       ctx do
    write!(ctx, "daily.md", "before\nalpha 中文\nbeta\nafter\n")
    agent = session!(ctx.dir, "search-engine")
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Search my existing memory")
    {provider, initial} = provider!()
    assert Enum.any?(initial.context.tools, &(&1.name == "memories::search"))

    args = %{
      "queries" => ["alpha", "beta"],
      "match_mode" => %{"type" => "all_within_lines", "line_count" => 2},
      "path" => "daily.md",
      "context_lines" => 1
    }

    {provider, direct_params} = call!(provider, "memories::search", args)
    direct = result!(agent)
    assert model_result!(direct_params, "memories::search") == direct
    assert direct["queries"] == ["alpha", "beta"]
    assert direct["match_mode"] == args["match_mode"]
    assert direct["path"] == "daily.md"
    assert direct["next_cursor"] == nil
    assert direct["truncated"] == false
    assert hd(direct["matches"])["content"] == "before\nalpha 中文\nbeta\nafter"
    assert hd(direct["matches"])["match_line_number"] == 2
    assert hd(direct["matches"])["content_start_line_number"] == 1
    finish!(provider)

    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Search through Code Mode")
    {provider, _} = provider!()
    code = "return await tools.memories__search(#{Jason.encode!(args)});"
    {provider, nested_params} = call!(provider, "exec", code)
    nested = result!(agent)
    assert nested["status"] == "completed"
    assert nested["value"] == Map.delete(direct, "is_error")
    assert model_result!(nested_params, "exec")["value"] == nested["value"]
    finish!(provider)

    stop_repository(ctx.dir)
    fresh = session!(ctx.dir, "search-restored")
    assert {:accepted, _} = Sigma.Agent.prompt(fresh, "Search after session restart")
    {provider, _} = provider!()
    {provider, params} = call!(provider, "memories::search", args)
    assert result!(fresh) == direct
    assert model_result!(params, "memories::search") == direct
    finish!(provider)
  end

  defp write!(ctx, path, contents) do
    absolute = Path.join(ctx.root, path)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, contents)
  end

  defp binding!(run_id) do
    session = start_supervised!({Session, owner_pid: self()}, id: make_ref())

    authority = %{
      caller: "search-test",
      run_id: run_id,
      grants: ["memories::search"],
      tool_revision: 1
    }

    assert {:ok, binding} = Session.bind(session, authority)
    assert :ok = Session.attach(binding, %{authority: authority, registry: %ToolRegistry{}})
    binding
  end

  defp search(ctx, args) do
    MemoryResources.execute(
      %{
        tool_name: "memories::search",
        arguments: args,
        run_id: ctx.binding.run_id,
        incarnation: ctx.binding.run_incarnation
      },
      %{},
      %{resources: ctx.resources, binding: ctx.binding}
    )
  end

  defp session!(dir, id) do
    assert {:ok, handle} =
             Runtime.get_session(dir, id,
               cwd: dir,
               transcript_path: Path.join(dir, id <> ".jsonl"),
               provider: Provider,
               model: %{id: "test", provider: "test", api: "openai-responses"},
               native_tools: true,
               tools: [],
               hook_specs: [],
               options: [test_pid: self()]
             )

    :ok = Sigma.Agent.subscribe(handle.agent)
    handle.agent
  end

  defp stop_repository(dir) do
    case Runtime.lookup(dir, :supervisor) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
    end
  end

  defp provider! do
    assert_receive {:search_provider, pid, params}, 10_000
    {pid, params}
  end

  defp call!(provider, name, arguments) do
    send(
      provider,
      {:search_response,
       [
         %{
           type: :tool_call,
           id: "search-#{System.unique_integer([:positive])}",
           name: name,
           arguments: arguments,
           input_kind: if(is_binary(arguments), do: :custom, else: :function)
         }
       ]}
    )

    provider!()
  end

  defp result!(agent) do
    result =
      Sigma.Agent.messages(agent) |> Enum.reverse() |> Enum.find(&(&1.role == :tool_result))

    refute result.is_error
    result.metadata.structured_result
  end

  defp model_result!(params, name) do
    message =
      params.context.messages
      |> Enum.reverse()
      |> Enum.find(&(&1.role == :tool_result and &1.tool_name == name))

    [%{type: :text, text: json}] = message.content
    Jason.decode!(json)
  end

  defp finish!(provider) do
    send(provider, {:search_response, [%{type: :text, text: "done"}]})
    assert_receive {:agent_end, _}, 8_000
  end
end
