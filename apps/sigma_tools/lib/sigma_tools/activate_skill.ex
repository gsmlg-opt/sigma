defmodule Sigma.Tools.ActivateSkill do
  @moduledoc "Activates a resolved local skill inside the current Agent turn."

  @behaviour Sigma.Coding.Tool

  alias Sigma.Coding.ToolError
  alias Sigma.Session.Skills.{Catalog, Snapshot}

  @impl true
  def name, do: "activate_skill"

  @impl true
  def description do
    "Activate one enabled local skill for this turn. Manual-only skills require explicit user invocation."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "reference" => %{
          "type" => "string",
          "description" => "Skill name or qualified repo:<name>/global:<name> reference"
        },
        "arguments" => %{
          "type" => "string",
          "description" => "Optional arguments for the skill"
        }
      },
      "required" => ["reference"]
    }
  end

  @impl true
  def execute(_tool_call_id, params, opts) do
    reference = Map.get(params, "reference")
    arguments = Map.get(params, "arguments", "")
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    with true <- is_binary(reference) and reference != "",
         catalog <- Catalog.build(cwd),
         {:ok, skill} <- Catalog.resolve(catalog, reference, :automatic) do
      activate(skill, arguments, opts)
    else
      false ->
        {:error, ToolError.new(:invalid_arguments, "Skill reference is required")}

      {:error, :manual_invocation_required} ->
        {:error,
         ToolError.new(:manual_invocation_required, "Skill requires explicit user invocation")}

      {:error, :skill_not_found} ->
        {:error, ToolError.new(:skill_not_found, "Skill not found: #{reference}")}

      {:error, :ambiguous_skill} ->
        {:error, ToolError.new(:ambiguous_skill, "Skill reference is ambiguous: #{reference}")}

      {:error, :skill_disabled} ->
        {:error, ToolError.new(:skill_disabled, "Skill is disabled: #{reference}")}

      {:error, reason} ->
        {:error, ToolError.new(:skill_unavailable, reason)}
    end
  end

  defp activate(skill, arguments, opts) do
    if activated?(opts, skill.skill_id) do
      {:ok,
       %{
         content: [%{type: :text, text: "Skill already activated for this turn."}],
         details: %{skill_id: skill.skill_id, deduplicated?: true}
       }}
    else
      cancelled? = Keyword.get(opts, :skill_cancelled?, fn -> false end)

      with {:ok, snapshot} <- Snapshot.prepare(skill, cancelled?: cancelled?),
           :ok <- register_resource(opts, snapshot) do
        activation = %{
          skill_id: skill.skill_id,
          source_id: skill.source_id,
          digest: snapshot.digest,
          resource_root: snapshot.root,
          manifest: snapshot.manifest
        }

        remember_activation(opts, activation)
        instructions = expand_arguments(snapshot.entry_body, arguments)
        {:ok, %{content: [%{type: :text, text: instructions}], details: activation}}
      else
        {:error, reason} ->
          {:error, ToolError.new(:skill_unavailable, reason)}
      end
    end
  end

  defp register_resource(opts, snapshot) do
    resource = %{
      root: snapshot.root,
      ref: snapshot.ref,
      digest: snapshot.digest,
      release: fn -> Snapshot.release(snapshot) end
    }

    case Keyword.get(opts, :register_skill_resource) do
      callback when is_function(callback, 1) ->
        case callback.(resource) do
          :ok -> :ok
          {:error, reason} -> release_registration(snapshot, reason)
          _other -> release_registration(snapshot, :resource_unavailable)
        end

      _callback ->
        release_registration(snapshot, :resource_owner_unavailable)
    end
  end

  defp release_registration(snapshot, reason) do
    _ = Snapshot.release(snapshot)
    {:error, reason}
  end

  defp activated?(opts, skill_id) do
    case {Keyword.get(opts, :tool_state), Keyword.get(opts, :turn_id)} do
      {table, turn_id} when not is_nil(table) ->
        :ets.member(table, {:skill_activation, turn_id, skill_id})

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp remember_activation(opts, activation) do
    case {Keyword.get(opts, :tool_state), Keyword.get(opts, :turn_id)} do
      {table, turn_id}
      when not is_nil(table) and
             (is_reference(table) or is_integer(table) or is_atom(table)) ->
        :ets.insert(table, {{:skill_activation, turn_id, activation.skill_id}, activation})

      _ ->
        :ok
    end
  end

  defp expand_arguments(body, arguments) do
    if String.contains?(body, "$ARGUMENTS") do
      String.replace(body, "$ARGUMENTS", arguments)
    else
      if arguments == "", do: body, else: body <> "\n\nSkill arguments:\n" <> arguments
    end
  end
end
