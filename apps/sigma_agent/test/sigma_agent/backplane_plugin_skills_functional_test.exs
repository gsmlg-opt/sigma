defmodule Sigma.Agent.BackplanePluginSkillsFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.ToolRegistry
  alias Backplane.AgentRuntime.Codex.Session
  alias Backplane.PluginProtocol.Archive
  alias Sigma.Agent.Backplane.{PluginSkills, SkillResources}

  @moduletag :tmp_dir
  @tools ~w(skills::list skills::read)

  setup %{tmp_dir: dir} do
    previous =
      Map.new([:agent_dir, :global_skills_dir], fn key ->
        {key, Application.fetch_env(:sigma_session, key)}
      end)

    global = Path.join(dir, "global")
    Application.put_env(:sigma_session, :agent_dir, Path.join(dir, "agent"))
    Application.put_env(:sigma_session, :global_skills_dir, global)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, original} -> Application.put_env(:sigma_session, key, original)
          :error -> Application.delete_env(:sigma_session, key)
        end
      end
    end)

    %{dir: dir, global: global}
  end

  test "installed skills merge with local catalogs and preserve complete instructions and resources",
       c do
    local_skill!(Path.join(c.dir, ".agents/skills"), "Repository body")
    local_skill!(c.global, "Global body")
    plugin = plugin!(c.dir, "release-one", "https://registry.example", "plugin-example", "first")
    before = package_state(plugin)
    {resources, session, binding} = resources!(c.dir, [plugin.record])

    assert {:ok, loaded} = PluginSkills.load([plugin.record])
    assert [%{skill: skill}] = Map.values(loaded.entries)
    assert skill.metadata["metadata"] == %{"custom" => "exact plugin metadata"}
    assert skill.description == "插件完整说明 e\u0301"

    assert {:ok, list} = execute(resources, binding, "skills::list", %{"authority" => "executor"})
    assert length(list.skills) == 3
    assert list.warnings == []
    assert is_nil(list.next_cursor)
    assert Enum.any?(list.skills, &(&1.reference == "repo:example"))
    assert Enum.any?(list.skills, &(&1.reference == "global:example"))
    installed = Enum.find(list.skills, &String.starts_with?(&1.reference, "plugin:"))
    assert installed.reference == PluginSkills.reference(skill)
    assert installed.description == skill.description

    assert {:ok, main} =
             execute(resources, binding, "skills::read", %{"package" => installed.package})

    assert main.contents == plugin.files["skills/example/SKILL.md"]
    assert main.resource == installed.main_resource
    assert File.dir?(main.skill_root)

    resource =
      String.replace_suffix(installed.main_resource, "SKILL.md", "references/guide.md")

    args = %{"package" => installed.package, "resource" => resource}
    assert {:ok, first} = execute(resources, binding, "skills::read", args)
    assert is_binary(first.next_cursor)
    assert String.valid?(first.contents)

    assert first.contents <> read_rest!(resources, binding, args, first.next_cursor) ==
             plugin.files["skills/example/references/guide.md"]

    assert package_state(plugin) == before
    refute File.exists?(plugin.marker)
    close!(resources, session, binding)
    refute File.exists?(main.skill_root)
    assert package_state(plugin) == before
    refute File.exists?(plugin.marker)
  end

  test "a run pins installed releases and the next binding refreshes the skill snapshot", c do
    first = plugin!(c.dir, "release-one", "https://registry.example", "plugin-example", "first")
    {resources, session, binding} = resources!(c.dir, [first.record])
    assert {:ok, %{skills: [original]}} = list(resources, binding)

    assert {:ok, read} =
             execute(resources, binding, "skills::read", %{"package" => original.package})

    assert read.contents == first.files["skills/example/SKILL.md"]
    second = plugin!(c.dir, "release-two", "https://registry.example", "plugin-example", "second")
    assert {:ok, %{skills: [still_pinned]}} = list(resources, binding)
    assert still_pinned.reference == original.reference

    assert {:ok, pinned} =
             execute(resources, binding, "skills::read", %{"package" => still_pinned.package})

    assert pinned.contents == first.files["skills/example/SKILL.md"]
    detach!(binding)
    next = bind!(resources, session, "next", [second.record])
    refute File.exists?(read.skill_root)
    refute File.exists?(pinned.skill_root)
    assert {:ok, %{skills: [current]}} = list(resources, next)
    refute current.reference == original.reference
    refute current.package == original.package

    assert {:ok, current_read} =
             execute(resources, next, "skills::read", %{"package" => current.package})

    assert current_read.contents == second.files["skills/example/SKILL.md"]
    refute File.exists?(first.marker)
    refute File.exists?(second.marker)
    close!(resources, session, next)
    refute File.exists?(current_read.skill_root)
  end

  test "same-named skills retain distinct registry plugin and release identities", c do
    first = plugin!(c.dir, "release-one", "https://one.example", "plugin-one", "first")
    second = plugin!(c.dir, "release-one", "https://two.example", "plugin-two", "second")
    {resources, session, binding} = resources!(c.dir, [first.record, second.record])
    assert {:ok, %{skills: entries}} = list(resources, binding)
    assert length(entries) == 2
    assert Enum.uniq_by(entries, & &1.reference) == entries
    assert Enum.uniq_by(entries, & &1.package) == entries
    assert Enum.all?(entries, &(&1.name == "example"))

    reads =
      Enum.map(entries, fn entry ->
        assert {:ok, read} =
                 execute(resources, binding, "skills::read", %{"package" => entry.package})

        read
      end)

    assert Enum.sort(Enum.map(reads, & &1.contents)) ==
             Enum.sort([
               first.files["skills/example/SKILL.md"],
               second.files["skills/example/SKILL.md"]
             ])

    close!(resources, session, binding)
    assert Enum.all?(reads, &(not File.exists?(&1.skill_root)))
  end

  defp resources!(workspace, plugins) do
    resources = start_supervised!({SkillResources, workspace: workspace})
    session = start_supervised!({Session, owner_pid: self()})
    binding = bind!(resources, session, "first", plugins)
    {resources, session, binding}
  end

  defp bind!(resources, session, run_id, plugins) do
    authority = %{caller: "plugin-skills", run_id: run_id, grants: @tools, tool_revision: 1}
    assert {:ok, binding} = Session.bind(session, authority)
    assert :ok = SkillResources.bind(resources, binding, plugins: plugins)
    assert :ok = Session.attach(binding, %{authority: authority, registry: %ToolRegistry{}})
    binding
  end

  defp execute(resources, binding, name, arguments) do
    SkillResources.execute(
      %{
        tool_name: name,
        arguments: arguments,
        run_id: binding.run_id,
        incarnation: binding.run_incarnation
      },
      %{},
      %{resources: resources, binding: binding}
    )
  end

  defp list(resources, binding),
    do: execute(resources, binding, "skills::list", %{"authority" => "executor"})

  defp read_rest!(_resources, _binding, _arguments, nil), do: ""

  defp read_rest!(resources, binding, arguments, cursor) do
    assert {:ok, page} =
             execute(resources, binding, "skills::read", Map.put(arguments, "cursor", cursor))

    assert String.valid?(page.contents)
    page.contents <> read_rest!(resources, binding, arguments, page.next_cursor)
  end

  defp detach!(binding) do
    assert :ok = Session.prepare_detach(binding)
    assert {:ok, %{status: :retained}} = Session.detach(binding)
  end

  defp close!(resources, session, binding) do
    detach!(binding)
    assert :ok = SkillResources.close(resources)
    assert {:ok, %{status: :confirmed}} = Session.close(session)
  end

  defp local_skill!(root, body) do
    File.mkdir_p!(Path.join(root, "example"))

    File.write!(
      Path.join(root, "example/SKILL.md"),
      "---\nname: example\ndescription: Local example\n---\n" <> body
    )
  end

  defp plugin!(dir, release, registry, id, body) do
    marker = Path.join(dir, id <> "-" <> release <> "-activated")
    root = Path.join([dir, "packages", id, release])

    files = %{
      "plugin.json" =>
        Jason.encode!(%{
          "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
          "name" => "example"
        }),
      "mcp.json" =>
        Jason.encode!(%{
          "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
          "mcpServers" => %{
            "example" => %{"type" => "stdio", "command" => "./mcp-server"}
          }
        }),
      "mcp-server" => "#!/bin/sh\nprintf activated > '" <> marker <> "'\n",
      "skills/example/SKILL.md" =>
        "---\r\nname: example\r\ndescription: 插件完整说明 e\u0301\r\nmetadata:\r\n  custom: exact plugin metadata\r\n---\r\n  " <>
          body <> " 中文 e\u0301 👩‍💻\r\n",
      "skills/example/references/guide.md" =>
        String.duplicate("  #{body} 中文 e\u0301 👩‍💻\r\n", 3_000),
      "skills/example/scripts/run.sh" => "#!/bin/sh\nprintf activated > '" <> marker <> "'\n"
    }

    for {relative, bytes} <- files do
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
      File.chmod!(path, if(relative == "mcp-server", do: 0o755, else: 0o644))
    end

    assert {:ok, snapshot} = Archive.read_directory_with_metadata(root)
    assert {:ok, canonical} = Archive.pack(snapshot.files, modes: snapshot.modes)
    digest = Archive.digest(canonical)

    record = %{
      "request_id" => "request-" <> id <> "-" <> release,
      "registry_url" => registry,
      "plugin_id" => id,
      "release_id" => release,
      "artifact_digest" => digest,
      "content_digest" => digest,
      "root" => root,
      "data_dir" => Path.join([dir, "data", id]),
      "status" => "installed",
      "started_at" => 1,
      "installed_at" => 2
    }

    %{record: record, files: files, marker: marker}
  end

  defp package_state(plugin) do
    Map.new(plugin.files, fn {relative, _bytes} ->
      path = Path.join(plugin.record["root"], relative)
      stat = File.stat!(path, time: :posix)
      {relative, {File.read!(path), stat.mtime, stat.inode}}
    end)
  end
end
