defmodule Sigma.Agent.IncidentsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias Sigma.Agent.Incidents

  setup do
    directory =
      Path.join(System.tmp_dir!(), "sigma-incidents-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    context = Incidents.context(Path.join(directory, "root.jsonl"), "root-header")
    %{directory: directory, context: context}
  end

  test "context uses only an absolute root transcript and safe immutable header", c do
    assert c.context.directory == Path.join(c.directory, ".incidents/root-header")
    refute File.exists?(c.context.directory)
    assert Incidents.context(nil, "root-header") == nil
    assert Incidents.context("relative.jsonl", "root-header") == nil
    assert Incidents.context(Path.join(c.directory, "root.jsonl"), "../escape") == nil
    assert :ok = Incidents.record(nil, %{kind: :run_failed})
    assert File.ls!(c.directory) == []
  end

  test "the exact first observation survives retries and concurrent writers", c do
    attrs = %{
      kind: :provider_failure,
      stage: :provider_response,
      run_id: "run-1",
      provider_attempt_id: "attempt-1",
      error: %{kind: :rate_limit, status: 429, message: "first secret"}
    }

    assert :ok = Incidents.record(c.context, attrs)
    [path] = paths(c.context)
    before = {File.read!(path), File.stat!(path, time: :posix)}

    outcomes =
      1..12
      |> Task.async_stream(fn _ ->
        Incidents.record(c.context, %{attrs | error: %{kind: :timeout, message: "later secret"}})
      end)
      |> Enum.to_list()

    assert Enum.all?(outcomes, &(&1 == {:ok, :ok}))
    assert {File.read!(path), File.stat!(path, time: :posix)} == before
    assert File.ls!(c.context.directory) == [Path.basename(path)]
    assert read!(path)["error"] == %{"class" => "rate_limit", "status" => 429}
  end

  test "recovery observations retain the failed-to-replacement join", c do
    for kind <- [
          :run_failed,
          :retirement_failed,
          :recovery_started,
          :recovery_admitted,
          :recovery_blocked,
          :recovery_cancelled
        ] do
      assert :ok =
               Incidents.record(c.context, %{
                 kind: kind,
                 run_id: "old-run",
                 source_run_id: "old-run",
                 target_run_id: "new-run",
                 continuation_id: "continuation-1",
                 stage: :automatic_continuation,
                 recovery_state: :blocked,
                 blocked_component: :native_resources,
                 incarnation: 2,
                 invocation_id: "invocation-1",
                 summary: "must not replace the static summary",
                 prompt: "private prompt"
               })
    end

    events = Enum.map(paths(c.context), &read!/1)
    assert length(events) == 6
    assert Enum.uniq_by(events, & &1["event_id"]) == events

    for event <- events do
      assert event["schema_version"] == 1
      assert event["format"] == "sigma.incident"
      assert event["source_run_id"] == "old-run"
      assert event["target_run_id"] == "new-run"
      assert event["continuation_id"] == "continuation-1"
      assert event["stage"] == "automatic_continuation"
      assert event["incarnation"] == 2
      refute Map.has_key?(event, "prompt")
      refute event["summary"] =~ "must not"
    end

    assert events |> Enum.map(& &1["incident_id"]) |> Enum.uniq() |> length() == 1

    assert :ok =
             Incidents.record(c.context, %{
               kind: :tool_failure,
               run_id: "old-run",
               tool_call_id: "call"
             })

    assert paths(c.context) |> Enum.map(&read!(&1)["incident_id"]) |> Enum.uniq() |> length() == 1
  end

  test "typed classifications survive without Provider options, causes or arbitrary codes", c do
    secret = "credential-payload-" <> String.duplicate("x", 50_000)

    assert :ok =
             Incidents.record_provider(c.context, "run-1", "attempt-1", %{
               kind: :invalid_request,
               status: 400,
               code: "context_length_exceeded",
               message: secret,
               raw: %{api_key: secret},
               cause: %{details: secret}
             })

    [path] = paths(c.context)

    assert read!(path)["error"] == %{
             "class" => "invalid_request",
             "status" => 400,
             "code" => "context_length_exceeded"
           }

    refute File.read!(path) =~ "credential-payload"
    assert byte_size(File.read!(path)) < 16_384

    assert :ok =
             Incidents.record_provider(c.context, "run-1", "attempt-2", %{
               class: "private-class",
               code: "private-token",
               status: 12345
             })

    assert Enum.any?(paths(c.context), &(read!(&1)["error"] == %{}))

    assert :ok =
             Incidents.record_provider(c.context, "run-1", "attempt-3", %{
               kind: :rate_limited,
               http_status: 429,
               provider_code: "rate_limit_exceeded",
               details: %{secret: secret}
             })

    assert Enum.any?(paths(c.context), fn path ->
             read!(path)["error"] == %{
               "class" => "rate_limited",
               "status" => 429,
               "code" => "rate_limit_exceeded"
             }
           end)
  end

  test "structured command failure is collected even when the outer tool succeeds", c do
    message = %{
      role: :tool_result,
      tool_name: "exec",
      tool_call_id: "call-1",
      is_error: false,
      content: [%{type: :text, text: "private output"}],
      metadata: %{
        structured_result: %{
          "value" => %{
            "command" => %{
              "status" => "completed",
              "exit_code" => 7,
              "output" => "private output"
            }
          }
        }
      }
    }

    assert :ok = Incidents.record_tool(c.context, "run-1", message)
    [path] = paths(c.context)
    assert read!(path)["exit_code"] == 7
    assert read!(path)["tool_call_id"] == "call-1"
    refute File.read!(path) =~ "private output"

    success = put_in(message, [:metadata, :structured_result], %{"exit_code" => 0})
    assert :ok = Incidents.record_tool(c.context, "run-1", %{success | tool_call_id: "call-2"})
    assert paths(c.context) == [path]
    assert :ok = Incidents.record_tool(c.context, "run-1", %{success | role: :assistant})
    assert paths(c.context) == [path]
  end

  test "tool errors and child subjects share the trusted root directory", c do
    child =
      Incidents.context(Path.join(c.directory, "root.jsonl"), "root-header", %{
        kind: :child,
        id: "child-session",
        session_id: "child-session",
        agent_path: "/root/child/grandchild",
        provider_options: %{api_key: "secret"}
      })

    assert :ok =
             Incidents.record_tool(child, "child-run", %{
               role: :tool_result,
               tool_name: "write_stdin",
               tool_call_id: "call-1",
               is_error: true,
               metadata: %{
                 structured_result: %{"error" => %{"class" => "unsupported_capability"}}
               }
             })

    [path] = paths(c.context)
    event = read!(path)

    assert event["subject"] == %{
             "kind" => "child",
             "id" => "child-session",
             "session_id" => "child-session",
             "agent_path" => "/root/child/grandchild"
           }

    assert event["error"] == %{"class" => "unsupported_capability"}
    refute File.read!(path) =~ "api_key"
  end

  test "unavailable storage returns only a bounded auxiliary diagnostic", c do
    File.write!(Path.join(c.directory, ".incidents"), "not a directory")

    log =
      capture_log(fn ->
        assert {:error, :directory_failed} =
                 Incidents.record(c.context, %{kind: :runtime_failure, error: "private cause"})
      end)

    assert log =~ "incident collection failed: directory_failed"
    refute log =~ "private cause"
    refute log =~ c.directory
  end

  test "evidence references are bounded and selected explicitly", c do
    assert :ok =
             Incidents.record(c.context, %{
               kind: :run_failed,
               evidence_refs: List.duplicate(%{run_id: "run-1", raw: "secret evidence"}, 100)
             })

    [path] = paths(c.context)
    assert read!(path)["evidence_refs"] == List.duplicate(%{"run_id" => "run-1"}, 8)
    refute File.read!(path) =~ "secret evidence"
  end

  test "versions include only loaded application versions and the known build commit", c do
    previous = Application.fetch_env(:sigma_web, :build_info)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sigma_web, :build_info, value)
        :error -> Application.delete_env(:sigma_web, :build_info)
      end
    end)

    commit = String.duplicate("a", 40)

    Application.put_env(:sigma_web, :build_info, %{git_sha: commit, options: "private build data"})

    assert :ok = Incidents.record(c.context, %{kind: :run_failed, run_id: "build-1"})
    [path] = paths(c.context)
    versions = read!(path)["versions"]
    assert versions["sigma_commit"] == commit
    refute File.read!(path) =~ "private build data"

    for app <- [
          :sigma_agent,
          :backplane_agent_runtime,
          :backplane_ai_protocol,
          :backplane_skill_protocol
        ] do
      if version = Application.spec(app, :vsn) do
        assert versions[Atom.to_string(app)] == to_string(version)
      else
        refute Map.has_key?(versions, Atom.to_string(app))
      end
    end

    Application.put_env(:sigma_web, :build_info, %{git_sha: "private invalid commit"})
    assert :ok = Incidents.record(c.context, %{kind: :run_failed, run_id: "build-2"})
    [other] = paths(c.context) -- [path]
    refute Map.has_key?(read!(other)["versions"], "sigma_commit")
  end

  defp paths(context), do: Path.wildcard(Path.join(context.directory, "*.json"))
  defp read!(path), do: path |> File.read!() |> Formata.JSON.decode!()
end
