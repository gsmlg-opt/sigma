defmodule Sigma.Agent.Backplane.NativeTools do
  @moduledoc false

  alias Backplane.AgentRuntime.{Codex, Error}
  alias Backplane.AgentRuntime.Codex.CodeMode
  alias Sigma.Agent.Backplane.ToolPostHooks

  @discovery_names ~w(tool_search)
  @environment_names ~w(wait_for_environment)
  @async_names ~w(request_user_input_async send_message_to_user_async)
  @mcp_names ~w(list_mcp_resources list_mcp_resource_templates read_mcp_resource mcp_events)
  @plugin_names ~w(list_available_plugins_to_install request_plugin_install)
  @skill_names ~w(skills::list skills::read)
  @memory_names ~w(memories::add_ad_hoc_note memories::list memories::read memories::search)
  @history_names ~w(history::list_windows history::list_items history::read_item history::search_contents)
  @note_names ~w(notes::list_files_by_prefix notes::read_file notes::search_contents notes::append_to_file notes::write_file)
  @goal_names ~w(get_goal create_goal update_goal)
  @board_names ~w(collaboration::create_channel collaboration::get_channels collaboration::list_threads collaboration::search_posts collaboration::read_thread collaboration::read_post collaboration::subscribe collaboration::unsubscribe collaboration::post)
  @code_mode_names ~w(exec wait)
  @names ~w(exec_command write_stdin apply_patch update_plan view_image clock::curr_time clock::sleep exec wait request_user_input get_context_remaining new_context)

  def names, do: @names
  def async_names, do: @async_names
  def resource_names, do: @mcp_names
  def plugin_names, do: @plugin_names
  def discovery_names, do: @discovery_names
  def environment_names, do: @environment_names
  def skill_names, do: @skill_names
  def memory_names, do: @memory_names
  def history_names, do: @history_names
  def note_names, do: @note_names
  def goal_names, do: @goal_names
  def board_names, do: @board_names
  def archive_names, do: @history_names ++ @note_names

  def profile(context, authority, hook_context, opts \\ []) do
    context = Map.put_new(context, :root?, true)

    {selected, families} =
      code_mode_family(Keyword.get(opts, :tools, @names), context, [:local, :interactive])

    with :ok <- validate_selection(selected, authority),
         {:ok, families} <- resource_family(selected, context, families),
         {:ok, families} <- extension_family(selected, context, families),
         {:ok, profile} <-
           Codex.profile(:configured, context, %{authority | grants: selected},
             families: families,
             tools: selected
           ) do
      profile
      |> resource_context(context)
      |> ToolPostHooks.decorate(hook_context)
    end
  end

  # WORKAROUND(upstream): gsmlg-opt/backplane#161 — Code Mode verifies its Deno
  # lifecycle only on Linux. Where the public capability check is unsupported
  # (macOS), omit the family and its exec/wait tools instead of failing every
  # native turn. Remove once Code Mode reports :verified on macOS.
  # TODO(upstream): gsmlg-opt/backplane#161
  defp code_mode_family(selected, context, families) do
    if CodeMode.lifecycle_capability(context) == :verified,
      do: {selected, families ++ [:code_mode]},
      else: {selected -- @code_mode_names, families}
  end

  defp extension_family(selected, context, families) do
    memory? = Enum.any?(selected, &(&1 in @memory_names))
    history? = Enum.any?(selected, &(&1 in @history_names))
    notes? = Enum.any?(selected, &(&1 in @note_names))
    goal? = Enum.any?(selected, &(&1 in @goal_names))
    board? = Enum.any?(selected, &(&1 in @board_names))

    if memory? or history? or notes? or goal? or board? or
         Enum.any?(selected, &(&1 in @skill_names)) do
      if is_pid(context[:extension_runtime]) and is_map(context[:session_binding]) and
           (not memory? or is_pid(context[:memory_resources])) and
           (not history? or is_map(context[:history_resources])) and
           (not notes? or is_pid(context[:notes_resources])) and
           (not goal? or (is_pid(context[:goal]) and is_map(context[:goal_binding]))) and
           (not board? or is_map(context[:message_board_resources])),
         do: {:ok, families ++ [:extensions]},
         else:
           {:error,
            Error.new(
              :validation,
              "extensions require trusted resource hosts and a Session binding"
            )}
    else
      {:ok, families}
    end
  end

  defp resource_family(selected, context, families) do
    cond do
      Enum.any?(selected, &(&1 in @mcp_names)) and
          not is_function(context[:mcp_clients], 0) ->
        {:error, Error.new(:validation, "MCP resources require a trusted client getter")}

      Enum.any?(selected, &(&1 in @plugin_names)) and not is_map(context[:plugin_resources]) ->
        {:error, Error.new(:validation, "plugins require a configured host")}

      Enum.any?(selected, &(&1 in (@mcp_names ++ @discovery_names ++ @plugin_names))) ->
        {:ok, families ++ [:dynamic]}

      true ->
        {:ok, families}
    end
  end

  defp resource_context(profile, context) do
    tools =
      Map.new(profile.registry.tools, fn {name, descriptor} ->
        case name do
          name when name in @mcp_names ->
            backend = Map.put(descriptor.backend_context, :mcp_clients, context.mcp_clients)
            {name, %{descriptor | backend_context: backend}}

          name when name in @plugin_names ->
            backend =
              Map.put(descriptor.backend_context, :plugin_resources, context.plugin_resources)

            {name, %{descriptor | backend_context: backend}}

          _ ->
            {name, descriptor}
        end
      end)

    %{profile | registry: %{profile.registry | tools: tools}}
  end

  defp validate_selection(selected, authority) do
    cond do
      not is_list(selected) or
          Enum.any?(
            selected,
            &(&1 not in (@names ++
                           @async_names ++
                           @mcp_names ++
                           @plugin_names ++
                           @discovery_names ++
                           @environment_names ++
                           @skill_names ++
                           @memory_names ++
                           @history_names ++ @note_names ++ @goal_names ++ @board_names))
          ) ->
        {:error, Error.new(:validation, "unsupported native tool selection")}

      Enum.any?(selected, &(&1 not in authority.grants)) ->
        {:error, Error.new(:forbidden, "native tools exceed caller grants")}

      true ->
        :ok
    end
  end
end
