defmodule Sigma.Web.HooksConfig do
  @moduledoc "Lossless edits for the matcher-group hooks.json format."

  @timeout_keys ["timeout", "timeoutSec", "timeout_sec"]
  @legacy_events ~w(pre_model_request post_model_request session_start user_prompt_submit pre_tool_use permission_request post_tool_use stop session_end pre_compact post_compact subagent_start subagent_stop interrupt)
  @format_error "Use advanced JSON to edit this hooks format."

  defdelegate events(), to: Sigma.Coding.Hooks.Catalog

  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} when is_map(data) ->
        if valid_hooks?(Map.get(data, "hooks", %{})),
          do: {:ok, data},
          else: {:error, @format_error}

      {:ok, _} ->
        {:error, @format_error}

      {:error, _} ->
        {:error, "Invalid JSON. Correct it in advanced JSON."}
    end
  end

  def decode(_), do: {:error, @format_error}

  def rows(data, event) when is_map(data) do
    data
    |> Map.get("hooks", %{})
    |> Map.get(event, [])
    |> Enum.with_index()
    |> Enum.flat_map(fn {group, group_index} ->
      group
      |> Map.get("hooks", [])
      |> Enum.with_index()
      |> Enum.map(fn {handler, handler_index} ->
        %{
          group_index: group_index,
          handler_index: handler_index,
          matcher: Map.get(group, "matcher") || "",
          handler: handler
        }
      end)
    end)
  end

  def put_command(json, event, location, attrs) do
    with {:ok, data} <- decode(json),
         :ok <- validate_event(event),
         {:ok, command, matcher, timeout} <- command_attrs(attrs),
         :ok <- validate_timeout(event, timeout),
         {:ok, groups} <-
           put_handler(
             Map.get(data, "hooks", %{}) |> Map.get(event, []),
             location,
             command,
             matcher,
             timeout,
             attrs
           ) do
      encode_event(data, event, groups)
    end
  end

  def remove_command(json, event, location) do
    with {:ok, data} <- decode(json),
         :ok <- validate_event(event),
         groups = Map.get(data, "hooks", %{}) |> Map.get(event, []),
         {:ok, group, handler} <- fetch_handler(groups, location),
         :ok <- editable_command(handler) do
      {group_index, handler_index} = location
      handlers = List.delete_at(Map.get(group, "hooks", []), handler_index)

      updated_groups =
        if handlers == [],
          do: List.delete_at(groups, group_index),
          else: List.replace_at(groups, group_index, Map.put(group, "hooks", handlers))

      encode_event(data, event, updated_groups)
    end
  end

  defp valid_hooks?(hooks) when is_map(hooks) do
    Enum.all?(hooks, fn {event, groups} ->
      event not in @legacy_events and is_list(groups) and Enum.all?(groups, &valid_group?/1)
    end)
  end

  defp valid_hooks?(_), do: false

  defp valid_group?(group) when is_map(group) do
    handlers = Map.get(group, "hooks")
    matcher = Map.get(group, "matcher")

    (is_nil(matcher) or is_binary(matcher)) and is_list(handlers) and
      Enum.all?(handlers, &is_map/1)
  end

  defp valid_group?(_), do: false

  defp validate_event(event) do
    if Enum.any?(events(), &(&1.name == event)),
      do: :ok,
      else: {:error, "Unknown hook event. Use advanced JSON to edit it."}
  end

  defp command_attrs(attrs) when is_map(attrs) do
    command = Map.get(attrs, "command")
    matcher = Map.get(attrs, "matcher", "")

    cond do
      not is_binary(command) or String.trim(command) == "" ->
        {:error, "Command is required."}

      not is_binary(matcher) ->
        {:error, "Matcher must be text."}

      true ->
        case parse_timeout(Map.get(attrs, "timeout", "")) do
          {:ok, timeout} -> {:ok, command, matcher, timeout}
          error -> error
        end
    end
  end

  defp command_attrs(_), do: {:error, "Command is required."}

  defp parse_timeout(value) when value in [nil, "", "default"], do: {:ok, nil}
  defp parse_timeout(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_timeout(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      trimmed ->
        case Integer.parse(trimmed) do
          {seconds, ""} when seconds > 0 ->
            {:ok, seconds}

          _ ->
            {:error, "Timeout must be a positive integer in seconds, or blank for the default."}
        end
    end
  end

  defp parse_timeout(_),
    do: {:error, "Timeout must be a positive integer in seconds, or blank for the default."}

  defp put_handler(groups, :new, command, matcher, timeout, attrs) do
    handler = update_handler(%{"type" => "command"}, command, timeout, attrs)
    {:ok, groups ++ [update_matcher(%{"hooks" => [handler]}, matcher)]}
  end

  defp put_handler(groups, location, command, matcher, timeout, attrs) do
    with {:ok, group, handler} <- fetch_handler(groups, location),
         :ok <- editable_command(handler) do
      {group_index, handler_index} = location

      handlers =
        List.replace_at(
          group["hooks"],
          handler_index,
          update_handler(handler, command, timeout, attrs)
        )

      group = group |> Map.put("hooks", handlers) |> update_matcher(matcher)
      {:ok, List.replace_at(groups, group_index, group)}
    end
  end

  defp fetch_handler(groups, {group_index, handler_index})
       when is_integer(group_index) and group_index >= 0 and is_integer(handler_index) and
              handler_index >= 0 do
    with {:ok, group} <- Enum.fetch(groups, group_index),
         {:ok, handler} <- Enum.fetch(Map.get(group, "hooks", []), handler_index) do
      {:ok, group, handler}
    else
      _ -> {:error, "Hook command no longer exists. Reload the configuration."}
    end
  end

  defp fetch_handler(_, _), do: {:error, "Invalid hook command location."}

  defp editable_command(handler) do
    if Map.get(handler, "type", "command") == "command" and
         not Map.has_key?(handler, "url") do
      :ok
    else
      {:error, "Use advanced JSON to edit this handler type."}
    end
  end

  defp update_handler(handler, command, timeout, attrs) do
    command_key =
      if Map.has_key?(handler, "command"),
        do: "command",
        else: if(Map.has_key?(handler, "cmd"), do: "cmd", else: "command")

    timeout_key = Enum.find(@timeout_keys, &Map.has_key?(handler, &1)) || "timeout"

    handler =
      handler
      |> Map.put(command_key, command)
      |> update_option(attrs, "statusMessage")
      |> update_option(attrs, "async")

    if is_nil(timeout),
      do: Map.drop(handler, @timeout_keys),
      else: Map.put(handler, timeout_key, timeout)
  end

  defp validate_timeout(event, timeout) do
    max_timeout = Enum.find(events(), &(&1.name == event)).max_timeout

    if is_integer(timeout) and is_integer(max_timeout) and timeout > max_timeout,
      do: {:error, "Timeout cannot exceed #{max_timeout} seconds for #{event}."},
      else: :ok
  end

  defp update_option(handler, attrs, key) do
    case Map.fetch(attrs, key) do
      :error ->
        handler

      {:ok, value} when value in [nil, ""] ->
        Map.delete(handler, key)

      {:ok, value} when key == "async" ->
        if value in [true, "true"] or Map.has_key?(handler, key),
          do: Map.put(handler, key, value in [true, "true"]),
          else: handler

      {:ok, value} ->
        Map.put(handler, key, value)
    end
  end

  defp update_matcher(group, ""), do: Map.delete(group, "matcher")
  defp update_matcher(group, matcher), do: Map.put(group, "matcher", matcher)

  defp encode_event(data, event, groups) do
    hooks = Map.get(data, "hooks", %{}) |> Map.put(event, groups)
    {:ok, Jason.encode!(Map.put(data, "hooks", hooks), pretty: true)}
  end
end
