alias Sigma.Agent.Message
alias Sigma.Session.{ConfigManager, Log, RepoManager}

[agent_dir, workdir, session_id] = Enum.reject(System.argv(), &(&1 == "--"))
Application.put_env(:sigma_session, :agent_dir, agent_dir)

File.mkdir_p!(agent_dir)
File.mkdir_p!(workdir)
{:ok, _repo} = RepoManager.add_repo(workdir, name: "Session UI Browser Fixture")

sessions_dir = ConfigManager.ensure_sessions_dir(workdir)
storage_path = Path.join(sessions_dir, session_id <> ".jsonl")
File.rm(storage_path)

:ok = Log.persist_event(storage_path, {:agent_start, workdir})

for index <- 1..28 do
  turn_id = "fixture-turn-#{index}"
  user_id = "fixture-user-#{index}"
  assistant_id = "fixture-assistant-#{index}"

  prompt =
    if index == 1,
      do: "Inspect the parser and explain the failure boundary.",
      else: "Follow-up #{index}: keep the diagnosis concise and preserve all prior evidence."

  answer =
    if index == 14 do
      suffix = String.duplicate("very_long_identifier_segment_", 12)

      """
      The parser keeps the raw input local to the decoding boundary.

      ```elixir
      defmodule SessionUi.LongCodeFixture do
        def decode(#{suffix}), do: {:ok, #{suffix}}
      end
      ```

      The code block must scroll locally without widening the transcript.
      """
    else
      "Fixture response #{index}. The journal remains replayable and the active branch stays explicit."
    end

  user = %{Message.user(user_id, prompt) | metadata: %{turn_id: turn_id}}

  assistant =
    Message.assistant(assistant_id, %{
      content: answer,
      model: "mock-model",
      provider: "test",
      usage: %{input: 100 + index, output: 20 + index, total_tokens: 120 + index * 2}
    })
    |> Map.put(:metadata, %{turn_id: turn_id, request_id: "fixture-request-#{index}"})

  :ok = Log.persist_event(storage_path, {:message_end, user})
  :ok = Log.persist_event(storage_path, {:message_end, assistant})

  :ok =
    Log.persist_event(
      storage_path,
      {:metrics, :turn_finished,
       %{
         turn_id: turn_id,
         session_id: session_id,
         revision: 1,
         status: :completed,
         wall_time_ms: 900 + index
       }}
    )

  :ok =
    Log.persist_event(
      storage_path,
      {:metrics, :request_finished,
       %{
         request_id: "fixture-request-#{index}",
         message_id: assistant_id,
         turn_id: turn_id,
         session_id: session_id,
         purpose: :turn,
         provider: "test",
         model: "mock-model",
         revision: 1,
         status: :completed,
         input_tokens_total: 100 + index,
         output_tokens_total: 20 + index,
         visible_output_tokens: 20 + index,
         elapsed_ms: 500 + index,
         ttft_ms: 40 + index
       }}
    )
end

:ok =
  Log.persist_event(
    storage_path,
    {:metrics, :tool_finished,
     %{
       tool_id: "fixture-tool",
       turn_id: "fixture-turn-28",
       request_id: "fixture-request-28",
       revision: 1,
       status: :completed,
       elapsed_ms: 125
     }}
  )

:ok =
  Log.persist_event(
    storage_path,
    {:metrics, :compaction,
     %{
       compaction_id: "fixture-compaction",
       revision: 1,
       status: :committed,
       source_leaf_id: "fixture-assistant-20",
       request_ids: [],
       before_tokens: 16_000,
       after_tokens: 4_000,
       finished_at: DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  )

File.write!(
  Path.join(sessions_dir, session_id <> ".meta.json"),
  Formata.JSON.encode!(%{
    "cwd" => workdir,
    "title" => "Session UI Browser Fixture",
    "provider_id" => "test",
    "model_id" => "mock-model"
  })
)

IO.puts(storage_path)
