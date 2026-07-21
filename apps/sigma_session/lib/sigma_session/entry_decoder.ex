defmodule Sigma.Session.EntryDecoder do
  @moduledoc false

  alias Sigma.Agent.Message

  @message_fields %{
    "id" => :id,
    "timestamp" => :timestamp,
    "api" => :api,
    "provider" => :provider,
    "model" => :model,
    "response_model" => :response_model,
    "response_id" => :response_id,
    "error_message" => :error_message,
    "tool_call_id" => :tool_call_id,
    "tool_name" => :tool_name,
    "is_error" => :is_error,
    "attachments" => :attachments,
    "metadata" => :metadata,
    "redacted" => :redacted,
    "command" => :command,
    "exit_code" => :exit_code,
    "summary" => :summary,
    "from_id" => :from_id,
    "tokens_before" => :tokens_before
  }

  @content_fields %{
    "id" => :id,
    "name" => :name,
    "text" => :text,
    "text_signature" => :text_signature,
    "thinking" => :thinking,
    "thinking_signature" => :thinking_signature,
    "redacted" => :redacted,
    "data" => :data,
    "mime_type" => :mime_type,
    "arguments" => :arguments,
    "thought_signature" => :thought_signature
  }

  @usage_fields %{
    "input" => :input,
    "output" => :output,
    "cache_read" => :cache_read,
    "cache_write" => :cache_write,
    "total_tokens" => :total_tokens
  }

  @cost_fields %{
    "input" => :input,
    "output" => :output,
    "cache_read" => :cache_read,
    "cache_write" => :cache_write,
    "total" => :total
  }

  @roles %{
    "system" => :system,
    "user" => :user,
    "assistant" => :assistant,
    "tool_result" => :tool_result,
    "thought" => :thought,
    "status" => :status,
    "notification" => :notification,
    "branch_summary" => :branch_summary,
    "compaction_summary" => :compaction_summary,
    "bash_execution" => :bash_execution,
    "artifact" => :artifact
  }

  @stop_reasons %{
    "stop" => :stop,
    "length" => :length,
    "tool_use" => :tool_use,
    "error" => :error,
    "aborted" => :aborted
  }

  @levels %{"info" => :info, "warning" => :warning, "error" => :error}

  @content_types %{
    "text" => :text,
    "thinking" => :thinking,
    "image" => :image,
    "tool_call" => :tool_call
  }

  def message(%{"message" => data}) when is_map(data) do
    with {:ok, role} <- required_enum(Map.get(data, "role"), @roles, :role),
         {:ok, stop_reason} <-
           optional_enum(Map.get(data, "stop_reason"), @stop_reasons, :stop_reason),
         {:ok, level} <- optional_enum(Map.get(data, "level"), @levels, :level),
         {:ok, content} <- content(Map.get(data, "content")),
         {:ok, usage} <- usage(Map.get(data, "usage")) do
      attrs =
        data
        |> take_known(@message_fields)
        |> Map.put(:role, role)
        |> maybe_put(:stop_reason, stop_reason)
        |> maybe_put(:level, level)
        |> Map.put(:content, content)
        |> maybe_put(:usage, usage)

      {:ok, struct(Message, attrs)}
    end
  end

  def message(_entry), do: {:error, :invalid_message}

  def compaction(%{"id" => id, "timestamp" => timestamp, "summary" => summary})
      when is_binary(id) and is_binary(timestamp) and is_binary(summary) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} ->
        {:ok,
         %Message{
           id: id,
           role: :compaction_summary,
           content: summary,
           timestamp: DateTime.to_unix(datetime, :millisecond)
         }}

      {:error, _reason} ->
        {:error, :invalid_compaction_timestamp}
    end
  end

  def compaction(_entry), do: {:error, :invalid_compaction}

  defp required_enum(value, values, field) when is_binary(value) do
    case Map.fetch(values, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> unknown_enum(field, value)
    end
  end

  defp required_enum(_value, _values, field), do: invalid_enum(field)

  defp optional_enum(nil, _values, _field), do: {:ok, nil}
  defp optional_enum(value, values, field), do: required_enum(value, values, field)

  defp unknown_enum(:role, value), do: {:error, {:unknown_role, value}}
  defp unknown_enum(:stop_reason, value), do: {:error, {:unknown_stop_reason, value}}
  defp unknown_enum(:level, value), do: {:error, {:unknown_level, value}}

  defp invalid_enum(:role), do: {:error, :invalid_role}
  defp invalid_enum(:stop_reason), do: {:error, :invalid_stop_reason}
  defp invalid_enum(:level), do: {:error, :invalid_level}

  defp content(nil), do: {:ok, nil}
  defp content(value) when is_binary(value), do: {:ok, value}

  defp content(items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case content_item(item) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp content(_value), do: {:error, :invalid_content}

  defp content_item(%{"type" => type} = item) when is_binary(type) do
    case Map.fetch(@content_types, type) do
      {:ok, content_type} ->
        {:ok, item |> take_known(@content_fields) |> Map.put(:type, content_type)}

      :error ->
        {:error, {:unknown_content_type, type}}
    end
  end

  defp content_item(_item), do: {:error, :invalid_content_item}

  defp usage(nil), do: {:ok, nil}

  defp usage(data) when is_map(data) do
    cost =
      case Map.get(data, "cost") do
        nil -> nil
        value when is_map(value) -> take_known(value, @cost_fields)
        _value -> :invalid
      end

    case cost do
      :invalid -> {:error, :invalid_usage_cost}
      nil -> {:ok, take_known(data, @usage_fields)}
      value -> {:ok, data |> take_known(@usage_fields) |> Map.put(:cost, value)}
    end
  end

  defp usage(_data), do: {:error, :invalid_usage}

  defp take_known(data, fields) do
    Enum.reduce(fields, %{}, fn {string_key, atom_key}, acc ->
      case Map.fetch(data, string_key) do
        {:ok, value} -> Map.put(acc, atom_key, value)
        :error -> acc
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
