defmodule Sigma.Protocol.Questions do
  @moduledoc "Display-safe live host questions and bounded Protocol V1 replies."

  alias Sigma.Protocol.{Codec, Envelope}

  @max_string_bytes 32_768
  @source_strings [:agent_id, :agent_path, :child_session_id, :public_run_id]

  def permission?(request) when is_map(request),
    do: get(request, :kind) in [:permission, "permission"]

  def permission?(_), do: false

  @doc "Projects one generic host request without leaking arbitrary host metadata."
  def request(id, request) when is_map(request) and not is_struct(request) do
    with true <- nonblank?(id) and not permission?(request),
         true <- nonblank?(get(request, :question)),
         {:ok, options} <- options(get(request, :options, [])),
         freeform when is_boolean(freeform) <- get(request, :allow_freeform, true),
         {:ok, placeholder} <- optional_string(get(request, :placeholder)),
         {:ok, call_id} <- optional_string(get(request, :tool_call_id)),
         {:ok, source} <- source(get(request, :source)),
         payload <- %{
           "requestId" => id,
           "request" =>
             %{
               "question" => get(request, :question),
               "options" => options,
               "allowFreeform" => freeform
             }
             |> put_optional("placeholder", placeholder)
             |> put_optional("toolCallId", call_id)
             |> put_optional("source", source)
         },
         {:ok, event} <- Envelope.event("question.required", "projection", payload),
         {:ok, _} <- Codec.encode(event) do
      {:ok, payload}
    else
      _ -> {:error, :invalid_question_request}
    end
  end

  def request(_, _), do: {:error, :invalid_question_request}

  @doc "Projects only currently live generic questions; it does not recover waiters."
  def snapshot(requests) when is_list(requests) do
    Enum.reduce_while(requests, {:ok, []}, fn request, {:ok, projected} ->
      if permission?(request) do
        {:cont, {:ok, projected}}
      else
        case request(get(request, :id), request) do
          {:ok, question} -> {:cont, {:ok, [question | projected]}}
          error -> {:halt, error}
        end
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      error -> error
    end
  end

  def snapshot(_), do: {:error, :invalid_question_request}

  @doc "Validates a reply against the exact live request without changing accepted text."
  def reply(payload, pending) when is_map(payload) and is_map(pending) do
    id = get(pending, :id)

    with {:ok, %{"request" => request}} <- request(id, pending),
         true <- payload["requestId"] == id do
      case payload do
        %{"action" => "cancel"} when map_size(payload) == 2 ->
          {:ok, {:error, :cancelled}}

        %{"action" => "answer", "answer" => text} when map_size(payload) == 3 ->
          if nonblank?(text) and
               (request["allowFreeform"] or Enum.any?(request["options"], &(&1["value"] == text))) do
            {:ok, {:ok, text}}
          else
            {:error, :invalid_question_response}
          end

        _ ->
          {:error, :invalid_question_response}
      end
    else
      _ -> {:error, :invalid_question_response}
    end
  end

  def reply(_, _), do: {:error, :invalid_question_response}

  defp options(options) when is_list(options) and length(options) <= 200 do
    Enum.reduce_while(options, {:ok, []}, fn option, {:ok, acc} ->
      case option(option) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, options} -> {:ok, Enum.reverse(options)}
      error -> error
    end
  end

  defp options(_), do: {:error, :invalid_question_request}

  defp option(text) when is_binary(text) do
    if nonblank?(text),
      do: {:ok, %{"label" => text, "value" => text, "description" => nil}},
      else: {:error, :invalid_question_request}
  end

  defp option(option) when is_map(option) and not is_struct(option) do
    label = get(option, :label)
    value = get(option, :value, label)

    with true <- nonblank?(label) and nonblank?(value),
         {:ok, description} <- optional_string(get(option, :description)) do
      {:ok, %{"label" => label, "value" => value, "description" => description}}
    else
      _ -> {:error, :invalid_question_request}
    end
  end

  defp option(_), do: {:error, :invalid_question_request}

  defp source(nil), do: {:ok, nil}

  defp source(source) when is_map(source) and not is_struct(source) do
    with true <-
           Enum.all?(@source_strings, &(is_nil(get(source, &1)) or nonblank?(get(source, &1)))),
         incarnation <- get(source, :incarnation),
         true <- is_nil(incarnation) or (is_integer(incarnation) and incarnation > 0) do
      projected = Map.new(@source_strings, &{Atom.to_string(&1), get(source, &1)})
      projected = Map.reject(projected, fn {_key, value} -> is_nil(value) end)
      {:ok, put_optional(projected, "incarnation", incarnation)}
    else
      _ -> {:error, :invalid_question_request}
    end
  end

  defp source(_), do: {:error, :invalid_question_request}

  defp optional_string(nil), do: {:ok, nil}

  defp optional_string(value) when is_binary(value) and byte_size(value) <= @max_string_bytes do
    if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_question_request}
  end

  defp optional_string(_), do: {:error, :invalid_question_request}

  defp nonblank?(value) when is_binary(value) and byte_size(value) <= @max_string_bytes,
    do: String.valid?(value) and String.trim(value) != ""

  defp nonblank?(_), do: false

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_, _, default), do: default

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
