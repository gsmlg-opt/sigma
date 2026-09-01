defmodule Sigma.ReleaseSmokeProvider do
  @behaviour Sigma.Ai.Provider

  @impl true
  def stream(_params) do
    started = %{
      role: :assistant,
      content: [],
      model: "release-smoke-model",
      provider: "release-smoke",
      api: "fake",
      usage: usage(0),
      stop_reason: nil,
      timestamp: System.system_time(:millisecond)
    }

    completed = %{
      started
      | content: [%{type: :text, text: "release smoke response"}],
        usage: usage(1),
        stop_reason: :stop
    }

    [
      {:start, started},
      {:text_delta, 0, "release smoke response", completed},
      {:done, :stop, completed}
    ]
  end

  defp usage(output) do
    %{
      input: 1,
      output: output,
      cache_read: 0,
      cache_write: 0,
      total_tokens: 1 + output,
      cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
    }
  end
end

smoke_root =
  Path.join(
    System.tmp_dir!(),
    "sigma-release-agent-smoke-#{System.unique_integer([:positive])}"
  )

File.mkdir_p!(smoke_root)

try do
  session_id = "release-smoke-session"

  {:ok, handle} =
    Sigma.Agent.Runtime.get_session(
      smoke_root,
      session_id,
      cwd: smoke_root,
      model: %{id: "release-smoke-model", api: "fake", provider: "release-smoke"},
      provider: Sigma.ReleaseSmokeProvider,
      idle_timeout_ms: 5_000
    )

  :ok = Sigma.Agent.subscribe(handle.agent)
  {:accepted, _admission} = Sigma.Agent.prompt(handle.agent, "release smoke prompt")

  receive do
    {:agent_end, messages} ->
      case List.last(messages) do
        %{role: :assistant, content: [%{type: :text, text: "release smoke response"}]} ->
          %{event_count: event_count, message_count: 2} =
            Sigma.Agent.SessionProcess.status(handle.session)

          true = event_count > 0
          IO.puts("release agent smoke ok")

        message ->
          raise "unexpected release smoke assistant message: #{inspect(message)}"
      end
  after
    5_000 -> raise "timed out waiting for release smoke agent turn"
  end
after
  File.rm_rf!(smoke_root)
end
