defmodule PiCoding.Tools.AskUserQuestion do
  @moduledoc """
  Tool for asking the connected user a question during an agent turn.
  """
  @behaviour PiCoding.Tool

  @impl true
  def name, do: "AskUserQuestion"

  @impl true
  def description do
    "Ask the user a question and wait for their answer. Use this when the current task needs a user choice or information that cannot be inferred from the repository."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "question" => %{
          "type" => "string",
          "description" => "The concise question to ask the user."
        },
        "options" => %{
          "type" => "array",
          "description" =>
            "Selectable answers to show before the freeform input. If the question has concrete choices or examples, put them here instead of only mentioning them in placeholder.",
          "items" => %{
            "oneOf" => [
              %{"type" => "string"},
              %{
                "type" => "object",
                "properties" => %{
                  "label" => %{"type" => "string"},
                  "value" => %{"type" => "string"},
                  "description" => %{"type" => "string"}
                },
                "required" => ["label"]
              }
            ]
          }
        },
        "allow_freeform" => %{
          "type" => "boolean",
          "description" =>
            "Whether the user may type a custom answer instead of selecting an option."
        },
        "placeholder" => %{
          "type" => "string",
          "description" =>
            "Placeholder text for the final custom-answer input only. Do not put selectable choices here."
        },
        "timeout_ms" => %{
          "type" => "integer",
          "description" => "Optional answer timeout in milliseconds.",
          "minimum" => 1_000
        }
      },
      "required" => ["question"]
    }
  end

  @impl true
  def execute(_tool_call_id, params, opts) do
    with {:ok, request} <- normalize_request(params),
         {:ok, answer} <- ask_user(request, opts) do
      {:ok,
       %{
         content: [%{type: :text, text: "User answer: #{answer}", text_signature: nil}],
         details: Map.put(request, :answer, answer)
       }}
    end
  end

  defp ask_user(request, opts) do
    case Keyword.get(opts, :ask_user_question_fn) do
      ask_fn when is_function(ask_fn, 2) ->
        ask_fn.(request, opts)

      ask_fn when is_function(ask_fn, 1) ->
        ask_fn.(request)

      _ ->
        {:error,
         "AskUserQuestion is not available because no user question handler is configured."}
    end
  end

  defp normalize_request(params) do
    question = params |> get_param("question") |> to_string() |> String.trim()

    cond do
      question == "" ->
        {:error, "Question is required."}

      true ->
        options =
          params
          |> get_first_param(["options", "choices", "suggestions", "answers"], [])
          |> normalize_options()

        placeholder = string_param(params, "placeholder")
        {options, placeholder} = maybe_promote_placeholder_examples(options, placeholder)

        request = %{
          question: question,
          options: options,
          allow_freeform: allow_freeform?(params, options),
          placeholder: placeholder,
          timeout_ms: timeout_ms(params)
        }

        {:ok, request}
    end
  end

  defp normalize_options(options) when is_list(options) do
    options
    |> Enum.map(&normalize_option/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_options(_options), do: []

  defp normalize_option(option) when is_binary(option) do
    label = String.trim(option)
    if label == "", do: nil, else: %{label: label, value: label, description: nil}
  end

  defp normalize_option(option) when is_map(option) do
    label = option |> get_param("label") |> to_string() |> String.trim()
    value = option |> get_param("value", label) |> to_string()
    description = string_param(option, "description")

    if label == "" do
      nil
    else
      %{label: label, value: value, description: description}
    end
  end

  defp normalize_option(_option), do: nil

  defp maybe_promote_placeholder_examples([], placeholder) when is_binary(placeholder) do
    case example_options_from_placeholder(placeholder) do
      [] -> {[], placeholder}
      options -> {options, nil}
    end
  end

  defp maybe_promote_placeholder_examples(options, placeholder), do: {options, placeholder}

  defp example_options_from_placeholder(placeholder) do
    placeholder
    |> String.trim()
    |> String.replace(~r/^(e\.g\.?|eg\.?|for example|examples?)[:,]?\s*/i, "")
    |> String.split(~r/\s*(?:,|;|\||\/|\bor\b)\s*/u, trim: true)
    |> Enum.map(&String.trim(&1, " \"'`"))
    |> Enum.reject(&(&1 == ""))
    |> case do
      [_single] -> []
      examples -> Enum.map(examples, &%{label: &1, value: &1, description: nil})
    end
  end

  defp allow_freeform?(params, []), do: get_param(params, "allow_freeform", true) != false

  defp allow_freeform?(params, _options) do
    get_param(params, "allow_freeform", true) != false
  end

  defp timeout_ms(params) do
    case get_param(params, "timeout_ms") do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp string_param(params, key) do
    case get_param(params, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp get_param(params, key, default \\ nil) when is_map(params) do
    Map.get(params, key, Map.get(params, String.to_atom(key), default))
  end

  defp get_first_param(params, keys, default) when is_map(params) do
    Enum.find_value(keys, default, fn key ->
      case get_param(params, key) do
        nil -> nil
        value -> value
      end
    end)
  end
end
