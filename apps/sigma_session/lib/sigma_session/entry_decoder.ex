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

  @status_types %{}

  @content_types %{
    "text" => :text,
    "thinking" => :thinking,
    "image" => :image,
    "tool_call" => :tool_call
  }

  def message(%{"message" => data} = entry) when is_map(data) do
    with {:ok, id} <- message_id(Map.get(data, "id")),
         {:ok, timestamp} <-
           message_timestamp(Map.get(data, "timestamp"), Map.get(entry, "timestamp")),
         {:ok, role} <- required_enum(Map.get(data, "role"), @roles, :role),
         {:ok, stop_reason} <-
           optional_enum(Map.get(data, "stop_reason"), @stop_reasons, :stop_reason),
         {:ok, level} <- optional_enum(Map.get(data, "level"), @levels, :level),
         {:ok, status_type} <-
           optional_enum(Map.get(data, "status_type"), @status_types, :status_type),
         {:ok, content} <- content(Map.get(data, "content")),
         :ok <- validate_content_for_role(role, content),
         :ok <- validate_role_fields(role, data),
         {:ok, usage} <- usage(Map.get(data, "usage")) do
      attrs =
        data
        |> take_known(@message_fields)
        |> Map.put(:id, id)
        |> Map.put(:timestamp, timestamp)
        |> Map.put(:role, role)
        |> maybe_put(:stop_reason, stop_reason)
        |> maybe_put(:level, level)
        |> maybe_put(:status_type, status_type)
        |> Map.put(:content, content)
        |> maybe_put(:usage, usage)

      {:ok, struct(Message, attrs)}
    end
  end

  def message(_entry), do: {:error, :invalid_message}

  defp message_id(id) when is_binary(id), do: {:ok, id}
  defp message_id(_id), do: {:error, :invalid_message_id}

  defp message_timestamp(timestamp, _entry_timestamp) when is_integer(timestamp),
    do: {:ok, timestamp}

  defp message_timestamp(nil, entry_timestamp) when is_integer(entry_timestamp),
    do: {:ok, entry_timestamp}

  defp message_timestamp(nil, entry_timestamp) when is_binary(entry_timestamp) do
    case DateTime.from_iso8601(entry_timestamp) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_unix(datetime, :millisecond)}
      {:error, _reason} -> {:error, :invalid_message_timestamp}
    end
  end

  defp message_timestamp(_timestamp, _entry_timestamp),
    do: {:error, :invalid_message_timestamp}

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
  defp unknown_enum(:status_type, value), do: {:error, {:unknown_status_type, value}}

  defp invalid_enum(:role), do: {:error, :invalid_role}
  defp invalid_enum(:stop_reason), do: {:error, :invalid_stop_reason}
  defp invalid_enum(:level), do: {:error, :invalid_level}
  defp invalid_enum(:status_type), do: {:error, :invalid_status_type}

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
        decoded = item |> take_known(@content_fields) |> Map.put(:type, content_type)

        case validate_content_item(content_type, decoded) do
          :ok -> {:ok, decoded}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, {:unknown_content_type, type}}
    end
  end

  defp content_item(_item), do: {:error, :invalid_content_item}

  defp validate_content_item(:text, item) do
    with :ok <- required_content_field(item, :text, :text, &is_binary/1),
         :ok <- nullable_content_field(item, :text, :text_signature, &is_binary/1) do
      :ok
    end
  end

  defp validate_content_item(:thinking, item) do
    with :ok <- required_content_field(item, :thinking, :thinking, &is_binary/1),
         :ok <- nullable_content_field(item, :thinking, :thinking_signature, &is_binary/1),
         :ok <- optional_content_field(item, :thinking, :redacted, &is_boolean/1) do
      :ok
    end
  end

  defp validate_content_item(:image, item) do
    with :ok <- required_content_field(item, :image, :data, &is_binary/1),
         :ok <- required_content_field(item, :image, :mime_type, &is_binary/1) do
      :ok
    end
  end

  defp validate_content_item(:tool_call, item) do
    with :ok <- required_content_field(item, :tool_call, :id, &is_binary/1),
         :ok <- required_content_field(item, :tool_call, :name, &is_binary/1),
         :ok <- required_content_field(item, :tool_call, :arguments, &is_map/1),
         :ok <- nullable_content_field(item, :tool_call, :thought_signature, &is_binary/1) do
      :ok
    end
  end

  defp required_content_field(item, content_type, field, validator) do
    case Map.fetch(item, field) do
      {:ok, value} ->
        if validator.(value),
          do: :ok,
          else: {:error, {:invalid_content_field, content_type, field}}

      :error ->
        {:error, {:invalid_content_field, content_type, field}}
    end
  end

  defp nullable_content_field(item, content_type, field, validator) do
    case Map.fetch(item, field) do
      {:ok, nil} -> :ok
      {:ok, value} -> optional_content_value(value, content_type, field, validator)
      :error -> :ok
    end
  end

  defp optional_content_field(item, content_type, field, validator) do
    case Map.fetch(item, field) do
      {:ok, value} -> optional_content_value(value, content_type, field, validator)
      :error -> :ok
    end
  end

  defp optional_content_value(value, content_type, field, validator) do
    if validator.(value),
      do: :ok,
      else: {:error, {:invalid_content_field, content_type, field}}
  end

  defp validate_content_for_role(:system, content) when is_binary(content), do: :ok
  defp validate_content_for_role(:system, _content), do: invalid_content_for_role(:system)

  defp validate_content_for_role(:user, content) when is_binary(content), do: :ok

  defp validate_content_for_role(:user, content) when is_list(content),
    do: validate_content_types(:user, content, [:text, :image])

  defp validate_content_for_role(:user, _content), do: invalid_content_for_role(:user)

  defp validate_content_for_role(:tool_result, content)
       when is_binary(content) or is_nil(content),
       do: :ok

  defp validate_content_for_role(:tool_result, content) when is_list(content),
    do: validate_content_types(:tool_result, content, [:text, :image])

  defp validate_content_for_role(:tool_result, _content),
    do: invalid_content_for_role(:tool_result)

  defp validate_content_for_role(_role, _content), do: :ok

  defp validate_content_types(role, content, allowed_types) do
    if Enum.all?(content, &(Map.get(&1, :type) in allowed_types)),
      do: :ok,
      else: invalid_content_for_role(role)
  end

  defp invalid_content_for_role(role), do: {:error, {:invalid_content_for_role, role}}

  defp validate_role_fields(:tool_result, data) do
    with :ok <- required_tool_result_identity(data, "tool_call_id", :tool_call_id),
         :ok <- required_tool_result_identity(data, "tool_name", :tool_name),
         :ok <- optional_tool_result_error(Map.get(data, "is_error")) do
      :ok
    end
  end

  defp validate_role_fields(_role, _data), do: :ok

  defp required_tool_result_identity(data, string_key, atom_key) do
    case Map.get(data, string_key) do
      value when is_binary(value) and byte_size(value) > 0 -> :ok
      _value -> {:error, {:invalid_tool_result_field, atom_key}}
    end
  end

  defp optional_tool_result_error(nil), do: :ok
  defp optional_tool_result_error(value) when is_boolean(value), do: :ok
  defp optional_tool_result_error(_value), do: {:error, {:invalid_tool_result_field, :is_error}}

  defp usage(nil), do: {:ok, nil}

  defp usage(data) when is_map(data) do
    with :ok <- required_usage_field(data, "input", :input),
         :ok <- required_usage_field(data, "output", :output),
         {:ok, decoded} <-
           take_validated(data, @usage_fields, &is_integer/1, :invalid_usage_field),
         {:ok, cost} <- usage_cost(Map.get(data, "cost")) do
      {:ok, maybe_put(decoded, :cost, cost)}
    end
  end

  defp usage(_data), do: {:error, :invalid_usage}

  defp required_usage_field(data, string_key, atom_key) do
    case Map.get(data, string_key) do
      value when is_integer(value) -> :ok
      _value -> {:error, {:invalid_usage_field, atom_key}}
    end
  end

  defp usage_cost(nil), do: {:ok, nil}

  defp usage_cost(data) when is_map(data) do
    take_validated(data, @cost_fields, &is_number/1, :invalid_cost_field)
  end

  defp usage_cost(_data), do: {:error, :invalid_usage_cost}

  defp take_validated(data, fields, validator, error_tag) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {string_key, atom_key}, {:ok, acc} ->
      case Map.fetch(data, string_key) do
        {:ok, value} ->
          if validator.(value),
            do: {:cont, {:ok, Map.put(acc, atom_key, value)}},
            else: {:halt, {:error, {error_tag, atom_key}}}

        :error ->
          {:cont, {:ok, acc}}
      end
    end)
  end

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
