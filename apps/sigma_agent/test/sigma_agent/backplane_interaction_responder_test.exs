defmodule Sigma.Agent.BackplaneInteractionResponderTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Backplane.InteractionResponder

  # Exercise the responder's public Conversation calls deterministically. The
  # real Conversation, Store and Sigma question lifecycle are covered separately.
  defmodule ConversationEndpoint do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    def init(owner) do
      {:ok,
       %{
         owner: owner,
         status: %{
           phase: :idle,
           run: %{run_id: "interaction-run", incarnation: 1, state: :running},
           conversation: %{pending_interaction: nil}
         }
       }}
    end

    def handle_call(:status, _from, state), do: {:reply, state.status, state}

    def handle_call({:status, status}, _from, state),
      do: {:reply, :ok, %{state | status: status}}

    def handle_call({:resolve, id, answer}, _from, state) do
      send(state.owner, {:resolved, id, answer})

      {:reply, :ok,
       %{
         state
         | status: %{state.status | phase: :running, conversation: %{pending_interaction: nil}}
       }}
    end

    def handle_call(:cancel, _from, state) do
      send(state.owner, :public_cancel)
      {:reply, :ok, %{state | status: %{state.status | phase: :cancelling}}}
    end
  end

  test "requires at least one correctly arity handler" do
    for handlers <- [
          [],
          [user_input_request_fn: fn _ -> :ok end],
          [permission_request_fn: :invalid],
          [runtime_permission_request_fn: fn _ -> :approved end],
          [runtime_permission_request_fn: :invalid]
        ] do
      assert {:error, _} = start_supervised({InteractionResponder, options(handlers)})
    end
  end

  test "a Runtime-permission-only handler resolves the built-in decision without client identity fields" do
    test = self()

    run =
      start_responder!(
        runtime_permission_request_fn: fn request, current? ->
          send(test, {:runtime_permission, request, current?.()})
          :approved
        end
      )

    request!(run, %{kind: :permission, operation: %{tool_name: "update_plan"}})
    assert_receive {:runtime_permission, %{kind: :permission}, true}
    assert_receive {:resolved, "question-1", :approved}
    refute_receive :public_cancel
  end

  test "a user-input-only handler resolves the exact requested answer map" do
    test = self()
    answers = %{"scope" => %{answers: ["Local"]}}

    run =
      start_responder!(
        user_input_request_fn: fn request, current? ->
          send(test, {:question, request, current?.()})
          {:ok, %{answers: answers}}
        end
      )

    event = request!(run, user_request())
    assert_receive {:question, %{kind: :request_user_input}, true}
    assert_receive {:resolved, "question-1", %{answers: ^answers}}
    assert_receive {:agent_runtime, "interaction-run", ^event}
    refute_receive :public_cancel
  end

  test "permission-only configuration forwards user input without invoking a handler" do
    test = self()
    run = start_responder!(permission_request_fn: fn _ -> send(test, :permission_called) end)
    event = request!(run, user_request())
    assert_receive {:agent_runtime, "interaction-run", ^event}
    refute_receive :permission_called
    refute_receive {:resolved, _, _}
    refute_receive :public_cancel
  end

  test "user-input-only configuration leaves independent built-in permission forward-only" do
    test = self()
    run = start_responder!(user_input_request_fn: fn _, _ -> send(test, :user_called) end)
    event = request!(run, %{kind: :permission, operation: %{name: "example"}})
    assert_receive {:agent_runtime, "interaction-run", ^event}
    refute_receive :user_called
    refute_receive {:resolved, _, _}
  end

  for {name, response} <- [
        missing: {:ok, %{answers: %{}}},
        extra: {:ok, %{answers: %{"scope" => %{answers: ["a"]}, "extra" => %{answers: ["b"]}}}},
        empty: {:ok, %{answers: %{"scope" => %{answers: [""]}}}},
        whitespace: {:ok, %{answers: %{"scope" => %{answers: ["  "]}}}},
        multiple: {:ok, %{answers: %{"scope" => %{answers: ["a", "b"]}}}},
        malformed: :allow,
        cancelled: {:error, :cancelled}
      ] do
    test "#{name} user result cancels publicly instead of resolving an error to Control" do
      response = unquote(Macro.escape(response))
      run = start_responder!(user_input_request_fn: fn _, _ -> response end)
      request!(run, user_request())
      assert_receive :public_cancel
      refute_receive {:resolved, _, _}
    end
  end

  for failure <- [:raise, :normal_exit, :kill] do
    test "user handler #{failure} cancels publicly" do
      failure = unquote(failure)

      run =
        start_responder!(
          user_input_request_fn: fn _, _ ->
            fail_handler(failure)
          end
        )

      request!(run, user_request())
      assert_receive :public_cancel
      refute_receive {:resolved, _, _}
    end
  end

  test "forged current-identity events cannot start a worker without exact pending content" do
    test = self()
    run = start_responder!(user_input_request_fn: fn _, _ -> send(test, :user_called) end)
    event = event(user_request())
    send(run.responder, {:agent_runtime, "interaction-run", event})
    refute_receive :user_called
    status = Backplane.AgentRuntime.Conversation.status(run.conversation)
    pending = %{id: event.interaction_id, request: event.request}

    :ok =
      GenServer.call(
        run.conversation,
        {:status,
         %{status | phase: :waiting_interaction, conversation: %{pending_interaction: pending}}}
      )

    forged = %{event | request: %{event.request | questions: [%{"id" => "forged"}]}}
    send(run.responder, {:agent_runtime, "interaction-run", forged})
    refute_receive :user_called
    refute_receive {:agent_runtime, _, _}
  end

  test "current guard and final resolution fence a response after the pending checkpoint changed" do
    test = self()

    run =
      start_responder!(
        user_input_request_fn: fn _, current? ->
          send(test, {:waiter, self(), current?})
          receive do: (:reply -> :ok)
          send(test, {:still_current, current?.()})
          {:ok, %{answers: %{"scope" => %{answers: ["Local"]}}}}
        end
      )

    request!(run, user_request())
    assert_receive {:waiter, waiter, current?}
    assert current?.()
    status = Backplane.AgentRuntime.Conversation.status(run.conversation)

    :ok =
      GenServer.call(
        run.conversation,
        {:status, %{status | phase: :running, conversation: %{pending_interaction: nil}}}
      )

    refute current?.()
    send(waiter, :reply)
    assert_receive {:still_current, false}
    refute_receive {:resolved, _, _}
    refute_receive :public_cancel
  end

  defp fail_handler(:raise), do: raise("question failed")
  defp fail_handler(:normal_exit), do: Process.exit(self(), :normal)
  defp fail_handler(:kill), do: Process.exit(self(), :kill)

  defp options(handlers) do
    [run_id: "interaction-run", incarnation: 1, owner_pid: self(), subscriber: self()] ++ handlers
  end

  defp start_responder!(handlers) do
    conversation = start_supervised!({ConversationEndpoint, self()})
    responder = start_supervised!({InteractionResponder, options(handlers)})
    assert :ok = InteractionResponder.attach(responder, conversation)
    %{conversation: conversation, responder: responder}
  end

  defp request!(run, request) do
    event = event(request)
    status = Backplane.AgentRuntime.Conversation.status(run.conversation)
    pending = %{id: event.interaction_id, request: request}

    :ok =
      GenServer.call(
        run.conversation,
        {:status,
         %{status | phase: :waiting_interaction, conversation: %{pending_interaction: pending}}}
      )

    send(run.responder, {:agent_runtime, "interaction-run", event})
    event
  end

  defp event(request) do
    %{
      type: :interaction_requested,
      run_id: "interaction-run",
      incarnation: 1,
      interaction_id: "question-1",
      request: request
    }
  end

  defp user_request do
    %{
      kind: :request_user_input,
      questions: [
        %{
          "id" => "scope",
          "header" => "Scope",
          "question" => "Which scope?",
          "options" => [%{"label" => "Local", "description" => "Use the current project."}]
        }
      ]
    }
  end
end
