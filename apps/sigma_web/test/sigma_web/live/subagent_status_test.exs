defmodule Sigma.Web.SubagentStatusTest do
  use Sigma.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Sigma.Agent.Runtime
  alias Sigma.Session.{ConfigManager, RepoManager}

  @moduletag :tmp_dir

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:subagent_ui_provider, self(), params})

      receive do
        {:respond, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{
              input: 1,
              output: 1,
              total_tokens: 2,
              cache_read: 0,
              cache_write: 0,
              cost: %{total: 0.0}
            },
            model: "fixture",
            provider: "fixture",
            api: "fixture",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:sigma_session, :agent_dir)
    Application.put_env(:sigma_session, :agent_dir, Path.join(dir, "agent"))

    repo =
      Path.join(System.tmp_dir!(), "sigma-saui-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(repo)
    {:ok, _} = RepoManager.add_repo(repo, name: "Subagent UI fixture")
    session_id = "subagent-ui"
    path = Path.join(ConfigManager.sessions_dir(repo), session_id <> ".jsonl")

    {:ok, handle} =
      Runtime.get_session(repo, session_id,
        cwd: repo,
        transcript_path: path,
        provider: Provider,
        model: %{id: "fixture", provider: "fixture", api: "fixture"},
        tools: [Sigma.Tools.Bash],
        hook_specs: [],
        options: [test_pid: self()],
        permission_config: %{default: :allow, rules: %{"bash" => :ask}}
      )

    Sigma.Agent.subscribe(handle.agent)

    on_exit(fn ->
      Runtime.close_subagents(repo, session_id)

      if pid = Runtime.lookup(repo, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)

      File.rm_rf!(repo)

      if previous,
        do: Application.put_env(:sigma_session, :agent_dir, previous),
        else: Application.delete_env(:sigma_session, :agent_dir)
    end)

    %{
      repo: repo,
      session_id: session_id,
      agent: handle.agent,
      route: "/repository/#{ConfigManager.repository_key(repo)}/sessions/#{session_id}"
    }
  end

  test "real child lifecycle updates the mounted roster without resetting the React islands", c do
    {:ok, view, _} = live(c.conn, c.route)
    initial = render_async(view, 5_000)
    config = chat_config(initial)
    assert has_element?(view, "#session-subagents-open-btn", "0 created")
    assert has_element?(view, "#session-details #session-subagents")
    refute has_element?(view, "#messages #session-subagents, #chat-input-area #session-subagents")

    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "delegate")
    root = provider(c.session_id)

    call(root.pid, "spawn_agent", %{
      "task_name" => "survey",
      "message" => "inspect",
      "fork_turns" => "none"
    })

    child = child_provider()
    root_next = provider(c.session_id)

    assert_eventually(fn ->
      has_element?(view, "#session-subagents-open-btn", "1 created · 1 executing")
    end)

    initial_row = row_id(render(view), "/root/survey")
    assert is_binary(initial_row)
    assert chat_config(render(view)) == config
    assert has_element?(view, "#chat-input-area[phx-update=ignore]")

    finish(root_next.pid)
    assert_eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
    assert_eventually(fn -> has_element?(view, "#stop-subagents-btn") end)
    assert has_element?(view, "#session-runtime-phase", "Completed")

    send(view.pid, {:subagent, %{revision: -1, data: %{status: :completed}}})
    assert has_element?(view, "#session-subagents-open-btn", "1 created · 1 executing")
    %{proxy: {ref, _topic, _}} = view
    drain_chat_snapshots(ref)
    send(view.pid, {:subagent, %{}})
    render(view)
    refute_receive {^ref, {:push_event, "chat:event", %{type: "chat.snapshot"}}}, 50

    finish(child.pid)

    assert_eventually(fn ->
      has_element?(view, "#session-subagents [data-agent-id]", "Completed")
    end)

    assert has_element?(view, "#session-subagents-open-btn", "1 created · 0 executing")
    refute has_element?(view, "#stop-subagents-btn")
    assert row_id(render(view), "/root/survey") == initial_row
    assert chat_config(render(view)) == config

    render_click(view, "filter_subagents", %{"filter" => "running"})
    assert has_element?(view, "#session-subagents", "No matching subagents")
    render_click(view, "filter_subagents", %{"filter" => "stopped"})
    assert has_element?(view, "#session-subagents [data-agent-id]", "Completed")

    {:ok, reloaded, _} = live(c.conn, c.route)
    render_async(reloaded, 5_000)
    assert has_element?(reloaded, "#session-subagents-open-btn", "1 created · 0 executing")
    assert row_id(render(reloaded), "/root/survey") == initial_row
  end

  test "capacity refusal preserves the running root and children and retains their stopped roster",
       c do
    {:ok, view, _} = live(c.conn, c.route)
    render_async(view, 5_000)
    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "fill the available child slots")
    root = provider(c.session_id)

    {root, children} =
      Enum.reduce(1..3, {root, []}, fn n, {root, children} ->
        call(root.pid, "spawn_agent", %{
          "task_name" => "task#{n}",
          "message" => "work until explicitly completed",
          "fork_turns" => "none"
        })

        child = child_provider()
        {provider(c.session_id), [child | children]}
      end)

    assert_eventually(fn ->
      has_element?(view, "#session-subagents-open-btn", "3 created · 3 executing")
    end)

    row_ids = for n <- 1..3, do: row_id(render(view), "/root/task#{n}")
    assert Enum.all?(row_ids, &is_binary/1)

    call(root.pid, "spawn_agent", %{
      "task_name" => "excess",
      "message" => "must be refused at capacity",
      "fork_turns" => "none"
    })

    root = provider(c.session_id)

    assert %{is_error: true} =
             Enum.find(Enum.reverse(root.params.context.messages), fn message ->
               Map.get(message, :tool_name) == "spawn_agent"
             end)

    assert Process.alive?(c.agent)
    assert Process.alive?(root.pid)
    assert Enum.all?(children, &Process.alive?(&1.pid))
    assert_eventually(fn -> Sigma.Agent.status(c.agent).phase == :streaming_provider end)
    refute_receive {:subagent_ui_provider, _, %{session_id: "child_" <> _}}, 50
    assert has_element?(view, "#session-subagents-open-btn", "3 created · 3 executing")

    assert_eventually(fn ->
      has_element?(view, "#session-runtime-phase", "Receiving model output")
    end)

    assert length(Floki.find(Floki.parse_document!(render(view)), "[data-agent-id]")) == 3
    refute has_element?(view, "#session-subagents", "/root/excess")

    Enum.each(children, &finish(&1.pid))

    assert_eventually(fn ->
      has_element?(view, "#session-subagents-open-btn", "3 created · 0 executing")
    end)

    assert Process.alive?(root.pid)
    assert has_element?(view, "[data-subagent-count=stopped]", "3")
    assert for(n <- 1..3, do: row_id(render(view), "/root/task#{n}")) == row_ids
    render_click(view, "filter_subagents", %{"filter" => "stopped"})
    assert length(Floki.find(Floki.parse_document!(render(view)), "[data-agent-id]")) == 3
    finish(root.pid)
    assert_eventually(fn -> has_element?(view, "#session-runtime-phase", "Completed") end)

    {:ok, reloaded, _} = live(c.conn, c.route)
    render_async(reloaded, 5_000)
    assert has_element?(reloaded, "#session-subagents-open-btn", "3 created · 0 executing")
    assert has_element?(reloaded, "[data-subagent-count=stopped]", "3")
  end

  test "child approvals retain source on reload and route one answer without changing root phase",
       c do
    {:ok, view, _} = live(c.conn, c.route)
    render_async(view, 5_000)

    assert {:accepted, _} =
             Sigma.Agent.prompt(
               c.agent,
               "delegate approvals",
               Sigma.Agent.PublicRuntime.prompt_opts(%{interactive_approvals: true}, c.agent)
             )

    root = provider(c.session_id)
    call(root.pid, "spawn_agent", %{"task_name" => "a", "message" => "a", "fork_turns" => "none"})
    a = child_provider()
    root_next = provider(c.session_id)

    call(root_next.pid, "spawn_agent", %{
      "task_name" => "b",
      "message" => "b",
      "fork_turns" => "none"
    })

    b = child_provider()
    root_last = provider(c.session_id)
    finish(root_last.pid)
    assert_eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
    call(a.pid, "bash", %{"command" => "printf approved-a"})
    call(b.pid, "bash", %{"command" => "printf approved-b"})

    assert_eventually(fn ->
      length(Runtime.pending_subagent_questions(c.repo, c.session_id)) == 2
    end)

    assert_eventually(fn ->
      length(Floki.find(Floki.parse_document!(render(view)), "[data-question-source]")) == 2
    end)

    assert has_element?(view, "#session-runtime-phase", "Completed")

    {:ok, reloaded, _} = live(c.conn, c.route)
    render_async(reloaded, 5_000)
    assert has_element?(reloaded, "#ask-user-questions", "From /root/a")
    assert has_element?(reloaded, "#ask-user-questions", "From /root/b")
    assert has_element?(reloaded, "#session-subagents [data-agent-id]", "Waiting for approval")
    questions = Runtime.pending_subagent_questions(c.repo, c.session_id)
    question_a = Enum.find(questions, &(&1.source.agent_path == "/root/a"))
    question_b = Enum.find(questions, &(&1.source.agent_path == "/root/b"))

    reloaded
    |> form("#ask-user-question-form-#{question_a.id}", %{"selected_answer" => "allow_once"})
    |> render_submit()

    a_next = provider(a.params.session_id)
    assert has_element?(reloaded, "#ask-user-question-#{question_b.id}")
    refute has_element?(reloaded, "#ask-user-question-#{question_a.id}")
    assert has_element?(reloaded, "#session-runtime-phase", "Completed")
    assert [%{id: remaining}] = Runtime.pending_subagent_questions(c.repo, c.session_id)
    assert remaining == question_b.id
    finish(a_next.pid)

    reloaded
    |> form("#ask-user-question-form-#{question_b.id}", %{"selected_answer" => "deny_once"})
    |> render_submit()

    b_next = provider(b.params.session_id)
    finish(b_next.pid)
  end

  test "rejected child answer remains visible with its error", c do
    {:ok, view, _} = live(c.conn, c.route)
    render_async(view, 5_000)
    id = "subagent_question_stale"

    send(
      view.pid,
      {:ask_user_question, id,
       %{
         source: %{
           agent_id: "old",
           agent_path: "/root/old",
           child_session_id: "old",
           public_run_id: "old",
           incarnation: 1
         },
         question: "Old request",
         options: [%{label: "Allow", value: "allow_once"}],
         allow_freeform: false
       }}
    )

    render(view)

    view
    |> form("#ask-user-question-form-#{id}", %{"selected_answer" => "allow_once"})
    |> render_submit()

    assert has_element?(view, "#ask-user-question-#{id}", "Old request")
    assert render(view) =~ "Could not answer question: :not_found"
  end

  defp drain_chat_snapshots(ref) do
    receive do
      {^ref, {:push_event, "chat:event", %{type: "chat.snapshot"}}} -> drain_chat_snapshots(ref)
    after
      0 -> :ok
    end
  end

  defp chat_config(html),
    do:
      html
      |> Floki.parse_document!()
      |> Floki.find("#messages")
      |> Floki.attribute("data-chat")
      |> hd()
      |> Jason.decode!()

  defp row_id(html, path) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-agent-id]")
    |> Enum.find(&(Floki.find(&1, "span") |> Floki.text() |> String.contains?(path)))
    |> case do
      nil -> nil
      row -> row |> Floki.attribute("id") |> hd()
    end
  end

  defp provider(session_id) do
    receive do
      {:subagent_ui_provider, pid, %{session_id: ^session_id} = params} ->
        %{pid: pid, params: params}

      {:turn_error, reason} ->
        flunk("root turn failed: #{inspect(reason)}")
    after
      5_000 -> flunk("provider did not start: #{session_id}")
    end
  end

  defp child_provider do
    receive do
      {:subagent_ui_provider, pid, %{session_id: "child_" <> _} = params} ->
        %{pid: pid, params: params}
    after
      5_000 -> flunk("child provider did not start")
    end
  end

  defp call(pid, name, arguments),
    do:
      send(
        pid,
        {:respond,
         [
           %{
             type: :tool_call,
             id: "call_#{System.unique_integer([:positive])}",
             name: name,
             arguments: arguments
           }
         ]}
      )

  defp finish(pid), do: send(pid, {:respond, [%{type: :text, text: "done"}]})
  defp assert_eventually(fun, attempts \\ 200)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          assert_eventually(fun, attempts - 1)
        )
  end
end
