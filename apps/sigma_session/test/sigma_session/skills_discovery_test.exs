defmodule Sigma.Session.Skills.DiscoveryTest do
  use ExUnit.Case, async: false

  alias Sigma.Session.{ConfigManager, Skills}
  alias Sigma.Session.Skills.Catalog

  @tag :tmp_dir
  test "global source can be disabled before filesystem discovery and retains item choices", %{
    tmp_dir: dir
  } do
    previous =
      Map.new([:agent_dir, :global_skills_dir], &{&1, Application.fetch_env(:sigma_session, &1)})

    global = Path.join(dir, "global")
    Application.put_env(:sigma_session, :agent_dir, Path.join(dir, "agent"))
    Application.put_env(:sigma_session, :global_skills_dir, global)

    on_exit(fn ->
      for {key, original} <- previous do
        case original do
          {:ok, value} -> Application.put_env(:sigma_session, key, value)
          :error -> Application.delete_env(:sigma_session, key)
        end
      end
    end)

    skill!(global, "global-marker")
    skill!(Skills.repository_skills_dir(dir), "repository-marker")
    assert ConfigManager.load_global_skills?()
    ConfigManager.set_global_skill_enabled("global-marker", false)
    assert :ok = ConfigManager.set_load_global_skills(false)

    owner = self()
    tracer = spawn(fn -> trace_calls(owner) end)
    :erlang.trace_pattern({File, :dir?, 1}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      assert Skills.list_global().skills == []
      assert Skills.list_global_for_repository(dir).skills == []
      assert Enum.map(Catalog.build(dir).skills, & &1.name) == ["repository-marker"]
      :erlang.trace(self(), false, [:call])
      skill!(global, "later-marker")
      :erlang.trace(self(), true, [:call, {:tracer, tracer}])
      assert Enum.map(Catalog.build(dir).skills, & &1.name) == ["repository-marker"]
      :erlang.trace(self(), false, [:call])
      delivered = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^delivered}
      send(tracer, :flush)
      assert_receive {:directory_calls, calls}
      refute global in calls
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({File, :dir?, 1}, false, [:local])
      Process.exit(tracer, :kill)
    end

    assert :ok = ConfigManager.set_load_global_skills(true)
    assert Enum.any?(Skills.list_global().skills, &(&1.name == "later-marker" and &1.enabled?))

    assert Enum.any?(
             Skills.list_global().skills,
             &(&1.name == "global-marker" and not &1.enabled?)
           )
  end

  defp trace_calls(owner, paths \\ []) do
    receive do
      {:trace, _, :call, {File, :dir?, [path]}} -> trace_calls(owner, [path | paths])
      :flush -> send(owner, {:directory_calls, paths})
    end
  end

  defp skill!(root, name) do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "SKILL.md"), "---\nname: #{name}\ndescription: Marker\n---\nBody")
  end
end
