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

    input_text =
      Enum.map_join(commands, "\n", fn command -> command |> Codec.encode() |> elem(1) end) <>
        "\n"

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

  test "dispatches negotiated Skill invoke, status, and cancel over stdio", context do
    session_id = "stdio-skill-commands"
    invocation_id = "invocation-stdio-cancel"
    skill_dir = Path.join([context.repo, ".agents", "skills", "review"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: review\ndescription: Review code\n---\nReview $ARGUMENTS"
    )

    assert {:ok, _record} =
             Sigma.Session.SkillInvocationStore.reserve(context.sessions_dir, session_id, %{
               "invocationId" => invocation_id,
               "requestKey" => "request-stdio",
               "fingerprint" => "fingerprint",
               "state" => "preparing"
             })

    commands = [
      command!("session.create", session_id, %{
        "cwd" => context.repo,
        "metadata" => %{"cwd" => context.repo}
      }),
      command!("skill.invoke", session_id, %{
        "requiredCapabilities" => ["skills.v1"],
        "repositoryId" => "repo-stdio",
        "requestKey" => "request-stdio-invoke",
        "reference" => "repo:review",
        "arguments" => "lib/example.ex"
      }),
      command!("skill.invocation.status", session_id, %{
        "requiredCapabilities" => ["skills.v1"],
        "invocationId" => invocation_id
      }),
      command!("skill.invocation.cancel", session_id, %{
        "requiredCapabilities" => ["skills.v1"],
        "invocationId" => invocation_id
      }),
      command!("skill.invoke", session_id, %{
        "repositoryId" => "repo-stdio",
        "requestKey" => "legacy-request",
        "reference" => "repo:review"
      })
    ]

    input_text =
      Enum.map_join(commands, "\n", fn command -> command |> Codec.encode() |> elem(1) end)

    {:ok, input} = StringIO.open(input_text <> "\n")
    {:ok, output} = StringIO.open("")

    context_map = %{
      repo_path: context.repo,
      sessions_dir: context.sessions_dir,
      session_opts: [
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: StdioProvider
      ],
      stdio_linger_ms: 1_000,
      skill_expander: &Sigma.Session.SkillExpander.expand/2,
      skill_invocation_store: %{
        find: fn current_session_id, request_key ->
          Sigma.Session.SkillInvocationStore.find(
            context.sessions_dir,
            current_session_id,
            request_key
          )
        end,
        list: fn current_session_id ->
          Sigma.Session.SkillInvocationStore.list(context.sessions_dir, current_session_id)
        end,
        reserve: fn current_session_id, record ->
          Sigma.Session.SkillInvocationStore.reserve(
            context.sessions_dir,
            current_session_id,
            record
          )
        end,
        update: fn current_session_id, current_invocation_id, changes ->
          Sigma.Session.SkillInvocationStore.update(
            context.sessions_dir,
            current_session_id,
            current_invocation_id,
            changes
          )
        end
      }
    }

    assert :ok = Stdio.run(input, output, context_map)
    {_input, output_text} = StringIO.contents(output)

    events =
      output_text
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> line |> Codec.decode() |> elem(1) end)

    assert %{payload: invoke_payload} =
             Enum.find(
               events,
               &(&1.type == "skill.invocation.updated" and
                   &1.payload["requestKey"] == "request-stdio-invoke")
             )

    assert "sha256:" <> _digest = invoke_payload["artifactDigest"]
    assert invoke_payload["resolvedRef"]["artifact_digest"] == invoke_payload["artifactDigest"]
    assert invoke_payload["resolvedRef"]["source_id"] =~ "repo-"

    assert Enum.any?(events, fn event ->
             event.type == "skill.invocation.updated" and
               event.payload["invocationId"] == invocation_id and
               event.payload["state"] == "cancelled"
           end)

    assert Enum.any?(
             events,
             &(&1.type == "session.error" and &1.error.code == "required_capability_missing")
           )
  end

  defp command!(type, session_id, payload \\ %{}) do
    {:ok, command} = Envelope.command(type, session_id, payload)
    command
  end
end
