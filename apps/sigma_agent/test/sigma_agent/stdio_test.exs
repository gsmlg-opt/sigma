defmodule Sigma.Agent.StdioTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Stdio
  alias Sigma.Protocol.{Codec, Envelope}

  defmodule StdioProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(_params) do
      message = %{
        role: :assistant,
        content: [%{type: :text, text: "stdio response"}],
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{
          input: 1,
          output: 1,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 2,
          cost: %{total: 0.0}
        },
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, :stop, message}]
    end
  end

  setup context do
    root =
      Path.join(
        System.tmp_dir!(),
        "sigma-stdio-#{context.test}-#{System.unique_integer([:positive])}"
      )

    repo = Path.join(root, "repo")
    sessions_dir = Path.join(root, "sessions")
    File.mkdir_p!(repo)
    File.mkdir_p!(sessions_dir)

    on_exit(fn ->
      case Sigma.Agent.Runtime.lookup(repo, :supervisor) do
        supervisor when is_pid(supervisor) ->
          DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)

        nil ->
          :ok
      end

      File.rm_rf!(root)
    end)

    {:ok, repo: repo, sessions_dir: sessions_dir}
  end

  test "runs a complete fake-provider session over JSON Lines stdio", context do
    session_id = "stdio-session"

    commands = [
      command!("session.create", session_id, %{
        "cwd" => context.repo,
        "metadata" => %{"cwd" => context.repo}
      }),
      command!("subscription.attach", session_id),
      command!("prompt.submit", session_id, %{"content" => "headless stdio"})
    ]

    input_text = Enum.map_join(commands, "\n", fn command -> command |> Codec.encode() |> elem(1) end) <> "\n"
    {:ok, input} = StringIO.open(input_text)
    {:ok, output} = StringIO.open("")

    context = %{
      repo_path: context.repo,
      sessions_dir: context.sessions_dir,
      session_opts: [
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: StdioProvider
      ],
      stdio_linger_ms: 3_000
    }

    assert :ok = Stdio.run(input, output, context)
    {_input, output_text} = StringIO.contents(output)

    events =
      output_text
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        assert {:ok, event} = Codec.decode(line)
        event
      end)

    assert Enum.any?(events, &(&1.type == "session.snapshot"))
    assert Enum.any?(events, &(&1.type == "prompt.admitted"))
    assert Enum.any?(events, &(&1.type == "message.completed"))
    assert Enum.any?(events, &(&1.type == "turn.completed"))
    refute output_text =~ "#PID"
    refute output_text =~ "#Reference"
  end

  defp command!(type, session_id, payload \\ %{}) do
    {:ok, command} = Envelope.command(type, session_id, payload)
    command
  end
end
