defmodule Sigma.Agent.Backplane.UserInput do
  @moduledoc """
  Resolves an explicitly hosted native `request_user_input` through Sigma's UI.

  The complete supported question batch is admitted before any host question is
  opened. Questions are presented sequentially with their original options and
  descriptions, a visible header prefix and a freeform answer. User text is
  returned unchanged in Codex's answer shape; no option is selected implicitly.

  The embedding interaction responder owns this blocking callback, supplies the
  current-request predicate and handles public Runtime cancellation on errors.
  Killing that owned worker removes its pending Sigma question through the
  existing host monitor. The responder owner must be the question Agent or a host
  that guarantees its lifetime. This adapter does not enable production tools, async
  questions or restart recovery.
  """

  @doc """
  Builds a native interaction callback; human waits default to infinity.

  Accepts a Sigma Agent PID or a trusted `(question, options)` host callback.
  The latter preserves managed-child source identity through `Subagents.ask/4`.
  """
  def resolver(host, opts \\ [])

  def resolver(agent_pid, opts) when is_pid(agent_pid) do
    resolver(
      fn request, options -> Sigma.Agent.ask_user_question(agent_pid, request, options) end,
      opts
    )
  end

  def resolver(ask, opts) when is_function(ask, 2) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    fn request, current? ->
      if valid_request?(request) do
        resolve_questions(ask, request.questions, current?, timeout, %{})
      else
        {:error, :invalid_user_input_request}
      end
    end
  end

  defp resolve_questions(_agent, [], _current?, _timeout, answers),
    do: {:ok, %{answers: answers}}

  defp resolve_questions(ask, [question | rest], current?, timeout, answers) do
    with :ok <- ensure_current(current?),
         reply <- ask.(host_question(question), timeout: timeout),
         :ok <- ensure_current(current?),
         {:ok, text} <- answer_text(reply) do
      answers = Map.put(answers, question["id"], %{answers: [text]})
      resolve_questions(ask, rest, current?, timeout, answers)
    end
  end

  defp ensure_current(current?) do
    if current?.() == true, do: :ok, else: {:error, :stale_interaction}
  end

  defp answer_text({:ok, text}) when is_binary(text) do
    if nonblank?(text), do: {:ok, text}, else: {:error, :invalid_user_input_answer}
  end

  defp answer_text({:error, _reason} = error), do: error
  defp answer_text(_), do: {:error, :invalid_user_input_answer}

  defp host_question(question) do
    %{
      question: "[#{question["header"]}] #{question["question"]}",
      allow_freeform: true,
      options:
        Enum.map(question["options"], fn option ->
          %{
            label: option["label"],
            value: option["label"],
            description: option["description"]
          }
        end)
    }
  end

  defp valid_request?(%{kind: :request_user_input, questions: questions} = request)
       when map_size(request) == 2 and is_list(questions) and length(questions) in 1..3 do
    Enum.all?(questions, &valid_question?/1) and
      length(Enum.uniq(Enum.map(questions, & &1["id"]))) == length(questions)
  end

  defp valid_request?(_), do: false

  defp valid_question?(question) when is_map(question) do
    exact_keys?(question, ["id", "header", "question", "options"]) and
      nonblank?(question["id"]) and nonblank?(question["header"]) and
      String.length(question["header"]) <= 12 and nonblank?(question["question"]) and
      valid_options?(question["options"])
  end

  defp valid_question?(_), do: false

  defp valid_options?(options) when is_list(options) and length(options) in 2..3,
    do: Enum.all?(options, &valid_option?/1)

  defp valid_options?(_), do: false

  defp valid_option?(option) when is_map(option) do
    exact_keys?(option, ["label", "description"]) and
      nonblank?(option["label"]) and nonblank?(option["description"])
  end

  defp valid_option?(_), do: false

  defp exact_keys?(map, keys),
    do: map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))

  defp nonblank?(text) when is_binary(text), do: String.trim(text) != ""
  defp nonblank?(_), do: false
end
