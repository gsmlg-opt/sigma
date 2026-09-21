defmodule Sigma.Agent.BackplanePublicRuntimeTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{PublicRuntime, Runtime}
  alias Sigma.Protocol.{Codec, Envelope}

  @moduletag :tmp_dir

  defmodule FileProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      if Enum.any?(params.context.messages, &(&1.role == :tool_result)) do
        message = message([%{type: :text, text: "Saved the file."}], :stop)

        [
          {:start, %{message | content: []}},
          {:text_delta, 0, "Saved the file.", message},
          {:done, :stop, message}
        ]
      else
        message =
          message(
            [
              %{
                type: :tool_call,
                id: "write-call",
                name: "write",
                arguments: %{"path" => "result.txt", "content" => "written by Sigma"}
              }
            ],
            :tool_use
          )

        [{:start, %{message | content: []}}, {:done, :tool_use, message}]
      end
    end

    defp message(content, reason) do
      %{
        role: :assistant,
        content: content,
        model: "scripted",
        provider: "test",
        usage: %{input: 2, output: 1, total_tokens: 3},
        stop_reason: reason,
        timestamp: System.system_time(:millisecond)
      }
    end
  end

  setup %{tmp_dir: root} do
    repo = Path.join(root, "repo")
    sessions = Path.join(root, "sessions")
    File.mkdir_p!(repo)
    File.mkdir_p!(sessions)
    configured_engine = Application.fetch_env(:sigma_agent, :execution_engine)
    Application.delete_env(:sigma_agent, :execution_engine)

    on_exit(fn ->
      stop_repository(repo)

      case configured_engine do
        {:ok, engine} -> Application.put_env(:sigma_agent, :execution_engine, engine)
        :error -> Application.delete_env(:sigma_agent, :execution_engine)
      end
    end)

    %{repo: repo, sessions: sessions}
  end

  test "public commands default to Backplane through a real write and durable history", ctx do
    {context, subscription} = create_session(ctx, "shared-write")

    assert {:ok, admitted} =
             command(context, "prompt.submit", "shared-write", %{"content" => "Save it"})

    events = collect_until(subscription, "turn.completed")

    assert File.read!(Path.join(ctx.repo, "result.txt")) == "written by Sigma"
    assert Enum.any?(events, &(&1.type == "message.delta"))

    for event <- events do
      assert {:ok, encoded} = Codec.encode(event)
      refute encoded =~ "#PID"
      refute encoded =~ "#Reference"
    end

    transcript = Path.join(ctx.sessions, "shared-write.jsonl")
    assert {:ok, snapshot} = Sigma.Session.Log.snapshot(transcript)

    assert [%{role: :user}, %{role: :assistant}, %{role: :tool_result}, %{role: :assistant}] =
             snapshot.messages

    assert File.dir?(transcript <> ".runtime")

    stop_repository(ctx.repo)
    {:ok, store} = start_supervised({Sigma.Agent.Backplane.Store, path: transcript <> ".runtime"})
    assert {:ok, %{run: run}} = Sigma.Agent.Backplane.Store.load(store, admitted.turn_id, [])
    assert run.state == :completed
    assert run.execution_budget.used == 3
    assert Enum.any?(run.execution_intents, fn {_id, intent} -> intent.type == :tool end)
  end

  test "interactive approval preserves request correlation before actual file execution", ctx do
    {context, subscription} = create_session(ctx, "shared-approval", :ask)
    context = Map.put(context, :interactive_approvals, true)

    assert {:ok, _} =
             command(context, "prompt.submit", "shared-approval", %{"content" => "Save it"})

    permission = receive_type(subscription, "permission.required")
    refute File.exists?(Path.join(ctx.repo, "result.txt"))

    assert {:error, %{error: %{code: "not_found"}}} =
             command(context, "permission.resolve", "shared-approval", %{
               "requestId" => "wrong",
               "decision" => "allow"
             })

    refute File.exists?(Path.join(ctx.repo, "result.txt"))

    assert {:ok, _} =
             command(context, "permission.resolve", "shared-approval", %{
               "requestId" => permission.payload["requestId"],
               "decision" => "allow"
             })

    collect_until(subscription, "turn.completed")
    assert File.read!(Path.join(ctx.repo, "result.txt")) == "written by Sigma"
  end

  test "cancelling an interactive approval never executes the pending write", ctx do
    {context, subscription} = create_session(ctx, "shared-cancel", :ask)
    context = Map.put(context, :interactive_approvals, true)

    assert {:ok, _} =
             command(context, "prompt.submit", "shared-cancel", %{"content" => "Save it"})

    permission = receive_type(subscription, "permission.required")
    assert {:ok, _} = command(context, "turn.cancel", "shared-cancel")
    collect_until(subscription, "turn.cancelled")

    assert {:error, %{error: %{code: "not_found"}}} =
             command(context, "permission.resolve", "shared-cancel", %{
               "requestId" => permission.payload["requestId"],
               "decision" => "allow"
             })

    refute File.exists?(Path.join(ctx.repo, "result.txt"))
  end

  test "denying an interactive approval reaches continuation without writing", ctx do
    {context, subscription} = create_session(ctx, "shared-deny", :ask)
    context = Map.put(context, :interactive_approvals, true)
    assert {:ok, _} = command(context, "prompt.submit", "shared-deny", %{"content" => "Save it"})
    permission = receive_type(subscription, "permission.required")

    assert {:ok, _} =
             command(context, "permission.resolve", "shared-deny", %{
               "requestId" => permission.payload["requestId"],
               "decision" => "deny"
             })

    collect_until(subscription, "turn.completed")
    refute File.exists?(Path.join(ctx.repo, "result.txt"))

    assert {:ok, snapshot} =
             Sigma.Session.Log.snapshot(Path.join(ctx.sessions, "shared-deny.jsonl"))

    assert Enum.any?(snapshot.messages, &match?(%{role: :tool_result, is_error: true}, &1))
  end

  test "explicit Sigma fallback executes without opening a Backplane sidecar", ctx do
    {context, subscription} =
      create_session(Map.put(ctx, :engine_opts, execution_engine: :sigma), "fallback")

    assert {:ok, _} = command(context, "prompt.submit", "fallback", %{"content" => "Save it"})
    collect_until(subscription, "turn.completed")
    assert File.read!(Path.join(ctx.repo, "result.txt")) == "written by Sigma"
    refute File.exists?(Path.join(ctx.sessions, "fallback.jsonl.runtime"))
    assert :sys.get_state(Runtime.lookup(ctx.repo, "fallback", :agent)).execution_engine == :sigma
  end

  test "application fallback is overridable per session and existing sessions retain their engine",
       ctx do
    Application.put_env(:sigma_agent, :execution_engine, :sigma)
    create_session(ctx, "app-fallback")

    {context, subscription} =
      create_session(Map.put(ctx, :engine_opts, execution_engine: :backplane), "override")

    assert {:ok, _} = command(context, "prompt.submit", "override", %{"content" => "Save it"})
    collect_until(subscription, "turn.completed")
    assert File.dir?(Path.join(ctx.sessions, "override.jsonl.runtime"))
    Application.delete_env(:sigma_agent, :execution_engine)

    assert :sys.get_state(Runtime.lookup(ctx.repo, "app-fallback", :agent)).execution_engine ==
             :sigma

    assert :sys.get_state(Runtime.lookup(ctx.repo, "override", :agent)).execution_engine ==
             :backplane
  end

  defp create_session(ctx, id, permission \\ :allow) do
    context = %{
      repo_path: ctx.repo,
      sessions_dir: ctx.sessions,
      session_opts:
        Keyword.merge(
          [
            provider: FileProvider,
            model: %{id: "scripted", provider: "test"},
            tools: [Sigma.Coding.Tools.Write],
            permission_config: %{default: :allow, rules: %{"write" => permission}}
          ],
          Map.get(ctx, :engine_opts, [])
        )
    }

    assert {:ok, %{type: "session.snapshot"}} =
             command(context, "session.create", id, %{"cwd" => ctx.repo})

    assert {:ok, %{payload: %{"subscriptionId" => sub}}} =
             command(context, "subscription.attach", id, %{
               "requiredCapabilities" => ["metrics.v1"]
             })

    {context, sub}
  end

  defp command(context, type, session, payload \\ %{}) do
    {:ok, envelope} = Envelope.command(type, session, payload)
    PublicRuntime.execute(envelope, context)
  end

  defp receive_type(subscription, type) do
    subscription |> collect_until(type) |> List.last()
  end

  defp collect_until(subscription, type, events \\ []) do
    receive do
      {:sigma_protocol, ^subscription, event} ->
        if event.type == type,
          do: Enum.reverse([event | events]),
          else: collect_until(subscription, type, [event | events])
    after
      5_000 -> flunk("missing #{type}; received #{inspect(Enum.map(events, & &1.type))}")
    end
  end

  defp stop_repository(repo) do
    case Runtime.lookup(repo, :supervisor) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
    end
  end
end
