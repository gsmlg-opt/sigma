defmodule Sigma.Agent.TestTools.FileWrite do
  @moduledoc false
  @behaviour Sigma.Coding.Tool

  def name, do: "test_fixture_file_write"
  def description, do: "Write a file for runtime integration tests"

  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "content" => %{"type" => "string"}
      },
      "required" => ["path", "content"]
    }
  end

  def metadata,
    do: %{effect: :write, concurrency: :sequential, default_deadline_ms: 5_000}

  def execute(_id, %{"path" => path, "content" => content}, opts) do
    with :ok <- File.write(Path.expand(path, Keyword.fetch!(opts, :cwd)), content) do
      {:ok, %{content: [%{type: :text, text: "Fixture file saved"}], details: %{path: path}}}
    end
  end
end

defmodule Sigma.Agent.TestTools.HostInput do
  @moduledoc false
  @behaviour Sigma.Coding.Tool

  def name, do: "test_fixture_host_input"
  def description, do: "Exercise the generic host input callback in tests"

  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "question" => %{"type" => "string"},
        "options" => %{"type" => "array", "items" => %{"type" => "string"}},
        "allow_freeform" => %{"type" => "boolean"}
      },
      "required" => ["question"]
    }
  end

  def metadata,
    do: %{effect: :process, concurrency: :sequential, default_deadline_ms: 5_000}

  def execute(id, arguments, opts) do
    request = %{
      tool_call_id: id,
      arguments: arguments,
      question: String.trim(arguments["question"]),
      options: Map.get(arguments, "options", [])
    }

    case Keyword.get(opts, :ask_user_question_fn) do
      ask when is_function(ask, 2) ->
        with {:ok, answer} <- ask.(request, opts) do
          {:ok, %{content: [%{type: :text, text: "User answer: #{answer}"}], details: request}}
        end

      _ ->
        {:error, "Test fixture has no user question handler"}
    end
  end
end
