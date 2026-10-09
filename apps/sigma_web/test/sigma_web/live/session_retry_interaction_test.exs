defmodule Sigma.Web.SessionRetryInteractionTest do
  use Sigma.Web.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Sigma.Agent.Message
  alias Sigma.Session.{ConfigManager, Log, RepoManager}

  @moduletag :tmp_dir

  defmodule InteractionProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      fixture = Application.fetch_env!(:sigma_web, :retry_interaction_fixture)
      last_message = List.last(params.context.messages)

      {content, stop_reason} =
        if last_message && last_message.role == :tool_result do
          send(fixture.test_pid, {:retry_tool_result, last_message})
          {[%{type: :text, text: "Retry interaction completed"}], :stop}
        else
          {[
             %{
               type: :tool_call,
               id: "retry_interaction_call",
               name: fixture.tool_name,
               arguments: fixture.arguments
             }
           ], :tool_use}
        end

      message = %{
        role: :assistant,
        content: content,
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{
          input: 1,
          output: 1,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 2,
          cost: %{total: 0.0, input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}
        },
        stop_reason: stop_reason,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, message}, {:done, stop_reason, message}]
    end
  end

  setup %{tmp_dir: tmp_dir} do
    workdir = Path.join(tmp_dir, "repository")
    previous_agent_dir = Application.get_env(:sigma_session, :agent_dir)
    previous_provider = Application.get_env(:sigma_web, :mock_provider_module)
    previous_fixture = Application.get_env(:sigma_web, :retry_interaction_fixture)

    Application.put_env(:sigma_session, :agent_dir, Path.join(tmp_dir, "agent"))
    Application.put_env(:sigma_web, :mock_provider_module, InteractionProvider)
    File.mkdir_p!(workdir)
    {:ok, _repo} = RepoManager.add_repo(workdir, name: "Retry interactions")

    on_exit(fn ->
      if supervisor = Sigma.Agent.Runtime.lookup(workdir, :supervisor) do
        :ok = DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
      end

      restore_env(:sigma_session, :agent_dir, previous_agent_dir)
      restore_env(:sigma_web, :mock_provider_module, previous_provider)
      restore_env(:sigma_web, :retry_interaction_fixture, previous_fixture)
    end)

    {:ok, workdir: workdir}
  end

  for transport <- [:liveview, :protocol] do
    if transport == :protocol do
      @tag :protocol_retry
    end

    test "retry through #{transport} retains the question handler", %{
      conn: conn,
      workdir: workdir
    } do
      Application.put_env(:sigma_web, :retry_interaction_fixture, %{
        test_pid: self(),
        tool_name: "ask",
        arguments: %{
          "question" => "Which retry path should I use?",
          "options" => [%{"label" => "Project", "value" => "project"}],
          "allow_freeform" => false
        }
      })

      assert {:ok, _permissions} = ConfigManager.update_permissions(%{"default" => "allow"})
      {view, storage_path} = confirmed_retry(conn, workdir, unquote(transport))

      assert_eventually(fn -> has_element?(view, "#ask-user-questions form") end)
      assert render(view |> element("#ask-user-questions")) =~ "Which retry path should I use?"

      view
      |> form("#ask-user-questions form", %{"selected_answer" => "project"})
      |> render_submit()

      assert_receive {:retry_tool_result, result}, 1_000
      refute result.is_error
      assert Enum.any?(result.content, &(&1.text == "User answer: project"))
      assert_completed(view, storage_path)
      refute has_element?(view, "#ask-user-questions")
    end
  end

  test "confirmed retry requests guarded bash approval before executing", %{
    conn: conn,
    workdir: workdir
  } do
    target = Path.join(workdir, "approved-retry")

    Application.put_env(:sigma_web, :retry_interaction_fixture, %{
      test_pid: self(),
      tool_name: "bash",
      arguments: %{"command" => "printf permitted > #{target}"}
    })

    assert {:ok, _permissions} =
             ConfigManager.update_permissions(%{
               "default" => "allow",
               "rules" => %{"bash" => "ask"}
             })

    {view, storage_path} = confirmed_retry(conn, workdir)

    assert_eventually(fn -> has_element?(view, "#ask-user-questions form") end)
    assert render(view |> element("#ask-user-questions")) =~ "Allow bash for this tool call?"
    refute File.exists?(target)

    assert [_form] =
             render(view) |> Floki.parse_document!() |> Floki.find("#ask-user-questions form")

    view
    |> form("#ask-user-questions form", %{"selected_answer" => "allow_once"})
    |> render_submit()

    assert_receive {:retry_tool_result, result}, 1_000
    refute result.is_error
    assert File.read(target) == {:ok, "permitted"}
    assert_completed(view, storage_path)
    refute has_element?(view, "#ask-user-questions")
  end

  defp confirmed_retry(conn, workdir, transport \\ :liveview) do
    session_id = "retry-interaction-#{System.unique_integer([:positive])}"
    encoded_workdir = Base.url_encode64(workdir, padding: false)
    path = "/repository/#{encoded_workdir}/sessions/#{session_id}"
    storage_path = Path.join(ConfigManager.sessions_dir(workdir), "#{session_id}.jsonl")
    File.mkdir_p!(Path.dirname(storage_path))

    user = %{
      Message.user("retry-user", "retry this interaction")
      | metadata: %{turn_id: "original-turn"}
    }

    :ok = Log.persist_event(storage_path, {:agent_start, workdir})
    :ok = Log.persist_event(storage_path, {:message_end, user})

    :ok =
      Log.persist_event(
        storage_path,
        {:message_end, Message.assistant("original-answer", %{content: "Original answer"})}
      )

    {:ok, view, _html} = live(conn, path)
    render_async(view, 3_000)

    case transport do
      :liveview ->
        assert render_click(view, "prepare_retry", %{"msg-id" => "retry-user"}) =~ "Retry once"
        render_click(view, "confirm_retry")
        assert_redirect(view, path)

        {:ok, retried_view, _html} = live(conn, path)
        render_async(retried_view, 3_000)
        {retried_view, storage_path}

      :protocol ->
        {:ok, {agent, _policy}} =
          Sigma.Web.SessionManager.get_agent(session_id, repo_path: workdir)

        {:ok, snapshot} = Log.snapshot(storage_path)

        assert {:ok, command} =
                 Sigma.Protocol.Envelope.command("session.retry", session_id, %{
                   "messageId" => "retry-user",
                   "expectedSourceRevision" => length(snapshot.branch_entry_ids) + 1,
                   "expectedSourceLeaf" => snapshot.active_leaf_id
                 })

        assert {:ok, %{payload: %{"retry" => %{"status" => "accepted"}}}} =
                 Sigma.Agent.PublicRuntime.execute(command, %{
                   repo_path: workdir,
                   sessions_dir: ConfigManager.sessions_dir(workdir),
                   interactive_approvals: true,
                   question_resolver: fn request, opts ->
                     Sigma.Agent.ask_user_question(agent, request, opts)
                   end
                 })

        {view, storage_path}
    end
  end

  defp assert_completed(view, storage_path) do
    assert_eventually(fn ->
      {:ok, snapshot} = Log.snapshot(storage_path)

      Enum.any?(snapshot.messages, fn message ->
        message.role == :assistant and
          Enum.any?(List.wrap(message.content), fn
            %{type: :text, text: "Retry interaction completed"} -> true
            _ -> false
          end)
      end)
    end)

    assert_eventually(fn -> render(view) =~ "Retry interaction completed" end)
  end

  defp assert_eventually(fun),
    do: assert_eventually(fun, System.monotonic_time(:millisecond) + 2_000)

  defp assert_eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition was not met before timeout")
      end

      Process.sleep(20)
      assert_eventually(fun, deadline)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
