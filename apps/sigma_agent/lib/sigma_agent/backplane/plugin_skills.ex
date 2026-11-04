defmodule Sigma.Agent.Backplane.PluginSkills do
  @moduledoc false

  alias Backplane.AgentRuntime.Error
  alias Backplane.PluginProtocol
  alias Backplane.PluginProtocol.Archive
  alias Backplane.SkillProtocol.Eligibility
  alias Sigma.Session.Skills.{Protocol, Skill}

  # A resource binding receives installed receipts, never a live registry. Only
  # the public package readers run here; MCP servers and scripts stay inactive.
  def load(installations) when is_list(installations) do
    Enum.reduce_while(installations, {:ok, %{entries: %{}, diagnostics: []}}, fn record,
                                                                                 {:ok, acc} ->
      with :ok <- verify(record),
           {:ok, package} <- PluginProtocol.load_directory(record["root"]) do
        {entries, diagnostics} = entries(record, package.skills)

        {:cont,
         {:ok,
          %{
            entries: Map.merge(acc.entries, entries),
            diagnostics: acc.diagnostics ++ package.diagnostics ++ diagnostics
          }}}
      else
        {:error, %Error{}} = error -> {:halt, error}
        {:error, cause} -> {:halt, failure("installed plugin skills could not be loaded", cause)}
      end
    end)
  end

  def load(_), do: failure("installed plugin skill receipts must be a list", nil)

  def verify(%{"status" => "installed", "root" => root, "content_digest" => digest})
      when is_binary(root) and is_binary(digest) do
    with {:ok, snapshot} <- Archive.read_directory_with_metadata(root),
         {:ok, bytes} <- Archive.pack(snapshot.files, modes: snapshot.modes) do
      if Archive.digest(bytes) == digest,
        do: :ok,
        else: failure("installed plugin content changed", :installed_content_changed)
    else
      {:error, cause} -> failure("installed plugin content could not be read", cause)
    end
  end

  def verify(_), do: failure("installed plugin skill receipt is invalid", nil)

  def reference(%{source: :plugin, source_id: source_id, source_key: source_key}),
    do: "plugin:" <> source_id <> "/" <> source_key

  defp entries(record, skills) do
    source_id =
      Archive.digest(
        Jason.encode!([
          record["registry_url"],
          record["plugin_id"],
          record["release_id"],
          record["artifact_digest"],
          record["content_digest"]
        ])
      )

    Enum.reduce(skills, {%{}, []}, fn plugin_skill, {entries, diagnostics} ->
      case apply(Protocol, :parse_document, [plugin_skill.content]) do
        {:ok, document} ->
          if apply(Eligibility, :evaluate, [document, :automatic, %{enabled: true}]) ==
               {:ok, :eligible} do
            skill =
              struct(Skill,
                name: document.name,
                description: document.description,
                path: Path.join(record["root"], plugin_skill.path),
                source: :plugin,
                skill_id: source_id <> ":" <> plugin_skill.name,
                source_id: source_id,
                source_key: plugin_skill.name,
                metadata: document.metadata,
                argument_hint: document.metadata["argument-hint"],
                disable_model_invocation?: document.metadata["disable-model-invocation"] == true
              )

            entry = %{skill: skill, installation: record}
            {Map.put(entries, skill.skill_id, entry), diagnostics}
          else
            {entries, diagnostics}
          end

        {:error, error} ->
          diagnostic = %{
            path: plugin_skill.path,
            message: apply(Protocol, :primary_diagnostic_message, [error])
          }

          {entries, diagnostics ++ [diagnostic]}
      end
    end)
  end

  defp failure(message, cause),
    do: {:error, Error.new(:execution_failure, message, cause: cause)}
end
