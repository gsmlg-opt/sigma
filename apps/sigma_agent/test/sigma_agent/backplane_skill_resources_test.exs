defmodule Sigma.Agent.BackplaneSkillResourcesTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Codex.{ExtensionRuntime, Session}
  alias Sigma.Agent.Backplane.{CodexResources, NativeTools, SkillResources}
  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Session.RepoManager

  @moduletag :tmp_dir
  @skills ~w(skills::list skills::read)

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:skills_provider, self(), params})

      receive do
        {:skills_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2, cost: %{total: 0.0}},
            model: "test",
            provider: "test",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} do
    previous =
      for key <- [:agent_dir, :global_skills_dir],
          into: %{},
          do: {key, Application.fetch_env(:sigma_session, key)}

    global = Path.join(dir, "global")
    Application.put_env(:sigma_session, :agent_dir, Path.join(dir, "agent"))
    Application.put_env(:sigma_session, :global_skills_dir, global)

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end

      for {key, value} <- previous do
        case value do
          {:ok, original} -> Application.put_env(:sigma_session, key, original)
          :error -> Application.delete_env(:sigma_session, key)
        end
      end
    end)

    {:ok, dir: dir, global: global}
  end

  test "real Engine exposes only the two skill extensions even with an empty catalog", ctx do
    agent = agent!(ctx.dir)
    {provider, params} = prompt!(agent)

    assert Enum.sort(Enum.map(params.context.tools, & &1.name)) ==
             Enum.sort(
               NativeTools.names() ++
                 NativeTools.async_names() ++
                 @skills ++
                 NativeTools.memory_names() ++
                 NativeTools.archive_names() ++ Subagents.collaboration_tools()
             )

    {provider, result} = call!(agent, provider, "skills::list", %{"authority" => "executor"})
    assert result["skills"] == []
    assert result["warnings"] == []
    refute result["next_cursor"]
    refute last_result(agent).is_error

    {provider, result} = call!(agent, provider, "skills::list", %{"authority" => "cloud"})
    assert last_result(agent).is_error
    assert result["error"]["class"] == "unsupported_capability"
    refute Map.has_key?(result, "skills")
    finish!(provider)
  end

  test "real catalog preserves source identity and reads packaged instructions and references",
       ctx do
    repo = skill!(repo_root(ctx.dir), "shared", "Repository body")
    skill!(ctx.global, "shared", "Global body")
    File.mkdir_p!(Path.join(repo, "references"))
    File.write!(Path.join(repo, "references/guide.md"), "Guide body")
    File.mkdir_p!(Path.join(repo, "scripts"))
    marker = Path.join(ctx.dir, "executed")
    File.write!(Path.join(repo, "scripts/run.sh"), "#!/bin/sh\ntouch #{marker}\n")

    agent = agent!(ctx.dir)
    {provider, _} = prompt!(agent)
    {provider, listed} = call!(agent, provider, "skills::list", %{"authority" => "executor"})

    assert Enum.sort(Enum.map(listed["skills"], & &1["reference"])) ==
             ["global:shared", "repo:shared"]

    local = Enum.find(listed["skills"], &(&1["reference"] == "repo:shared"))
    global = Enum.find(listed["skills"], &(&1["reference"] == "global:shared"))
    assert local["authority"] == "executor"
    assert local["package"] != global["package"]
    assert local["main_resource"] =~ "skill://"

    {provider, read} = call!(agent, provider, "skills::read", %{"package" => local["package"]})
    assert read["contents"] == File.read!(Path.join(repo, "SKILL.md"))
    assert read["resource"] == local["main_resource"]
    assert File.dir?(read["skill_root"])

    guide = String.replace_suffix(local["main_resource"], "SKILL.md", "references/guide.md")

    {provider, read} =
      call!(agent, provider, "skills::read", %{
        "package" => local["package"],
        "resource" => guide
      })

    assert read["contents"] == "Guide body"

    {provider, read} = call!(agent, provider, "skills::read", %{"package" => global["package"]})
    assert read["contents"] =~ "Global body"
    refute File.exists?(marker)
    refute Enum.any?(Sigma.Agent.messages(agent), &(&1.role == :skill_activation))
    finish!(provider)
  end

  test "manual-only and disabled skills cannot be listed or read with guessed references", ctx do
    skill!(repo_root(ctx.dir), "automatic", "Automatic")
    skill!(repo_root(ctx.dir), "manual", "Manual", "disable-model-invocation: true\n")
    skill!(repo_root(ctx.dir), "disabled", "Disabled")
    assert {:ok, _} = RepoManager.add_repo(ctx.dir)
    assert {:ok, _} = RepoManager.set_disabled_skills(ctx.dir, ["disabled"])
    agent = agent!(ctx.dir)
    {provider, _} = prompt!(agent)
    {provider, listed} = call!(agent, provider, "skills::list", %{"authority" => "executor"})
    assert Enum.map(listed["skills"], & &1["reference"]) == ["repo:automatic"]

    provider =
      Enum.reduce(["repo:manual", "repo:disabled", "manual", "disabled"], provider, fn package,
                                                                                       provider ->
        {provider, result} = call!(agent, provider, "skills::read", %{"package" => package})
        assert last_result(agent).is_error
        refute Map.has_key?(result, "contents")
        provider
      end)

    finish!(provider)
  end

  test "issued resources reject traversal, absolute paths, foreign packages and binary content",
       ctx do
    root = skill!(repo_root(ctx.dir), "safe", "Safe")
    File.write!(Path.join(root, "binary.bin"), <<0, 255, 1>>)
    File.write!(Path.join(ctx.dir, "secret"), "DO NOT LEAK")
    {binding, context, _profile} = bound!(ctx.dir)

    assert {:ok, %{skills: [skill]}} =
             execute(context, binding, "skills::list", %{"authority" => "executor"})

    for resource <- [
          "../secret",
          Path.join(ctx.dir, "secret"),
          "..\\secret",
          "skill://foreign/SKILL.md",
          String.replace_suffix(skill.main_resource, "SKILL.md", "../secret"),
          String.replace_suffix(skill.main_resource, "SKILL.md", "binary.bin")
        ] do
      assert {:error, %Error{}} =
               execute(context, binding, "skills::read", %{
                 "package" => skill.package,
                 "resource" => resource
               })
    end

    assert {:error, %Error{}} =
             execute(context, binding, "skills::read", %{
               "package" => "foreign",
               "resource" => skill.main_resource
             })

    detach!(binding)
  end

  test "catalog pagination pins descriptors while first read prepares the current content", ctx do
    for index <- 1..45 do
      skill!(repo_root(ctx.dir), name(index), "Original #{index}")
    end

    {binding, context, _profile} = bound!(ctx.dir)
    assert {:ok, first} = execute(context, binding, "skills::list", %{"authority" => "executor"})
    assert is_binary(first.next_cursor)
    [entry | _] = first.skills
    skill!(repo_root(ctx.dir), entry.name, "Changed before first read")
    skill!(repo_root(ctx.dir), "added-later", "Not in pinned catalog")
    entries = first.skills ++ list_rest!(context, binding, first.next_cursor)
    assert length(entries) == 45
    assert Enum.uniq_by(entries, & &1.package) == entries
    assert Enum.sort(Enum.map(entries, & &1.name)) == Enum.map(1..45, &name/1)
    assert {:ok, read} = execute(context, binding, "skills::read", %{"package" => entry.package})
    assert read.contents =~ "Changed before first read"
    detach!(binding)
  end

  test "text pagination is immutable UTF-8 and cursors are bound to the exact resource", ctx do
    root = skill!(repo_root(ctx.dir), "long", "Entry")
    File.mkdir_p!(Path.join(root, "references"))
    contents = String.duplicate("你好σ\n", 20_000)
    File.write!(Path.join(root, "references/long.md"), contents)
    File.write!(Path.join(root, "references/other.md"), "Other")
    {binding, context, _profile} = bound!(ctx.dir)

    assert {:ok, %{skills: [skill]}} =
             execute(context, binding, "skills::list", %{"authority" => "executor"})

    resource = String.replace_suffix(skill.main_resource, "SKILL.md", "references/long.md")
    args = %{"package" => skill.package, "resource" => resource}
    assert {:ok, first} = execute(context, binding, "skills::read", args)
    assert is_binary(first.next_cursor)
    assert byte_size(first.contents) <= 64 * 1024
    assert String.valid?(first.contents)
    File.write!(Path.join(root, "references/long.md"), "Changed source")
    assert first.contents <> read_rest!(context, binding, args, first.next_cursor) == contents

    for wrong <- [
          Map.put(args, "package", "foreign"),
          Map.put(args, "resource", skill.main_resource)
        ] do
      assert {:error, %Error{}} =
               execute(
                 context,
                 binding,
                 "skills::read",
                 Map.put(wrong, "cursor", first.next_cursor)
               )
    end

    assert {:error, %Error{}} =
             execute(context, binding, "skills::list", %{
               "authority" => "executor",
               "cursor" => first.next_cursor
             })

    detach!(binding)
  end

  test "policy revocation invalidates already issued packages and continuation cursors", ctx do
    root = skill!(repo_root(ctx.dir), "revoked", "Body")
    File.write!(Path.join(root, "long.md"), String.duplicate("data\n", 30_000))
    assert {:ok, _} = RepoManager.add_repo(ctx.dir)
    {binding, context, _profile} = bound!(ctx.dir)

    assert {:ok, %{skills: [skill]}} =
             execute(context, binding, "skills::list", %{"authority" => "executor"})

    args = %{
      "package" => skill.package,
      "resource" => String.replace_suffix(skill.main_resource, "SKILL.md", "long.md")
    }

    assert {:ok, first} = execute(context, binding, "skills::read", args)
    assert is_binary(first.next_cursor)
    assert {:ok, _} = RepoManager.set_disabled_skills(ctx.dir, ["revoked"])
    assert {:error, %Error{class: :forbidden}} = execute(context, binding, "skills::read", args)

    assert {:error, %Error{class: :forbidden}} =
             execute(context, binding, "skills::read", Map.put(args, "cursor", first.next_cursor))

    detach!(binding)
  end

  test "public Session fences reject forged incarnation and successful next run rotates extensions",
       ctx do
    skill!(repo_root(ctx.dir), "owned", "Owned")
    {binding, context, profile, resources} = bound_resources!(ctx.dir)

    assert {:error, %Error{class: :forbidden}} =
             execute(context, %{binding | run_incarnation: 999}, "skills::list", %{
               "authority" => "executor"
             })

    assert {:ok, %{skills: [skill]}} =
             execute(context, binding, "skills::list", %{"authority" => "executor"})

    assert {:ok, read} = execute(context, binding, "skills::read", %{"package" => skill.package})
    detach!(binding)

    assert {:error, %Error{class: :forbidden}} =
             execute(context, binding, "skills::read", %{"package" => skill.package})

    assert {:ok, next} = CodexResources.bind(resources, authority("next"))
    assert {:ok, next_context} = CodexResources.context(resources, next)
    refute next_context.extension_runtime == context.extension_runtime
    refute Process.alive?(context.extension_runtime)

    assert {:ok, next_profile} =
             NativeTools.profile(next_context, authority("next"), %{hook_specs: []},
               tools: @skills
             )

    assert :ok = Session.attach(next, next_profile)

    assert {:error, %Error{}} =
             execute(next_context, next, "skills::read", %{"package" => skill.package})

    assert {:ok, %{skills: [_]}} =
             execute(next_context, next, "skills::list", %{"authority" => "executor"})

    assert Map.keys(profile.registry.tools) |> Enum.sort() == @skills
    detach!(next)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    refute Process.alive?(next_context.extension_runtime)
    refute File.exists?(read.skill_root)
  end

  test "owner death stops the extension runtime and releases prepared package roots", ctx do
    skill!(repo_root(ctx.dir), "cleanup", "Cleanup")
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(owner), do: send(owner, :stop) end)
    {binding, context, _profile, resources} = bound_resources!(ctx.dir, owner_pid: owner)

    assert {:ok, %{skills: [skill]}} =
             execute(context, binding, "skills::list", %{"authority" => "executor"})

    assert {:ok, read} = execute(context, binding, "skills::read", %{"package" => skill.package})
    detach!(binding)
    monitors = Enum.map([resources, context.extension_runtime], &{&1, Process.monitor(&1)})
    send(owner, :stop)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 10_000
    end

    refute File.exists?(read.skill_root)
  end

  test "failed package cleanup stays unconfirmed and can be retried after ownership repair",
       ctx do
    skill!(repo_root(ctx.dir), "cleanup-failure", "Cleanup failure")
    {binding, context, _profile, resources} = bound_resources!(ctx.dir)

    assert {:ok, %{skills: [skill]}} =
             execute(context, binding, "skills::list", %{"authority" => "executor"})

    assert {:ok, read} =
             execute(context, binding, "skills::read", %{"package" => skill.package})

    detach!(binding)
    marker = Path.join(Path.dirname(read.skill_root), ".sigma-skill-owner")
    token = File.read!(marker)

    snapshot = %{
      root: read.skill_root,
      ownership: %{operation_root: Path.dirname(read.skill_root), token: token}
    }

    on_exit(fn -> apply(Sigma.Session.Skills.Snapshot, :release, [snapshot]) end)
    File.write!(marker, "different-owner")

    try do
      assert {:error, %Error{class: :unknown_outcome}} = CodexResources.close(resources)
      assert File.dir?(read.skill_root)
      assert Process.alive?(resources)
    after
      File.write!(marker, token)
    end

    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    refute File.exists?(read.skill_root)
  end

  test "failed old-run cleanup refuses replacement binding and retains a retryable package",
       ctx do
    skill!(repo_root(ctx.dir), "bind-cleanup", "Bind cleanup")
    {binding, context, _profile, resources} = bound_resources!(ctx.dir)

    assert {:ok, %{skills: [skill]}} =
             execute(context, binding, "skills::list", %{"authority" => "executor"})

    assert {:ok, read} = execute(context, binding, "skills::read", %{"package" => skill.package})
    detach!(binding)

    with_broken_ownership(read, fn ->
      assert {:error, %Error{class: :unknown_outcome}} =
               CodexResources.bind(resources, authority("replacement"))

      assert File.dir?(read.skill_root)
      assert {:error, %Error{class: :forbidden}} = CodexResources.context(resources, binding)
    end)

    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    refute File.exists?(read.skill_root)
  end

  test "expired cache refuses dispatch until failed cleanup can be confirmed", ctx do
    skill!(repo_root(ctx.dir), "ttl-cleanup", "TTL cleanup")
    {binding, _context, _profile} = bound!(ctx.dir)
    cache = start_supervised!({SkillResources, workspace: ctx.dir})
    assert :ok = SkillResources.bind(cache, binding)

    assert {:ok, %{skills: [skill]}} =
             cache_execute(cache, binding, "skills::list", %{"authority" => "executor"})

    assert {:ok, read} =
             cache_execute(cache, binding, "skills::read", %{"package" => skill.package})

    # Advance only this Sigma-owned cache's deadline; no Runtime internals or
    # production clock/configuration API is needed to exercise real expiration.
    :sys.replace_state(cache, &%{&1 | expires_at: System.monotonic_time(:millisecond) - 1})

    with_broken_ownership(read, fn ->
      assert {:error, %Error{class: :unknown_outcome}} =
               cache_execute(cache, binding, "skills::list", %{"authority" => "executor"})

      assert File.dir?(read.skill_root)
    end)

    assert {:ok, %{skills: [fresh]}} =
             cache_execute(cache, binding, "skills::list", %{"authority" => "executor"})

    refute fresh.package == skill.package
    refute File.exists?(read.skill_root)

    assert {:error, %Error{class: :not_found}} =
             cache_execute(cache, binding, "skills::read", %{"package" => skill.package})

    detach!(binding)
  end

  defp with_broken_ownership(read, callback) do
    operation_root = Path.dirname(read.skill_root)
    marker = Path.join(operation_root, ".sigma-skill-owner")
    token = File.read!(marker)

    snapshot = %{
      root: read.skill_root,
      ownership: %{operation_root: operation_root, token: token}
    }

    on_exit(fn -> apply(Sigma.Session.Skills.Snapshot, :release, [snapshot]) end)
    File.write!(marker, "different-owner")

    try do
      callback.()
    after
      File.write!(marker, token)
    end
  end

  defp cache_execute(cache, binding, name, args) do
    operation = %{
      tool_name: name,
      arguments: args,
      run_id: binding.run_id,
      incarnation: binding.run_incarnation
    }

    SkillResources.execute(operation, %{}, %{resources: cache, binding: binding})
  end

  defp agent!(dir) do
    assert {:ok, handle} =
             Runtime.get_session(dir, "skills",
               cwd: dir,
               transcript_path: Path.join(dir, "skills.jsonl"),
               native_tools: true,
               provider: Provider,
               model: %{id: "test", provider: "test", api: "openai-responses"},
               tools: [],
               hook_specs: [],
               options: [test_pid: self()]
             )

    :ok = Sigma.Agent.subscribe(handle.agent)
    handle.agent
  end

  defp prompt!(agent) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Exercise skill resources")
    provider!()
  end

  defp provider! do
    assert_receive {:skills_provider, provider, params}, 8_000
    {provider, params}
  end

  defp call!(agent, provider, name, arguments) do
    send(
      provider,
      {:skills_response,
       [
         %{
           type: :tool_call,
           id: "skill-#{System.unique_integer([:positive])}",
           name: name,
           arguments: arguments,
           input_kind: :function
         }
       ]}
    )

    {provider, _} = provider!()
    {provider, last_result(agent).metadata.structured_result}
  end

  defp last_result(agent),
    do: Sigma.Agent.messages(agent) |> Enum.reverse() |> Enum.find(&(&1.role == :tool_result))

  defp finish!(provider) do
    send(provider, {:skills_response, [%{type: :text, text: "done"}]})
    assert_receive {:agent_end, _}, 5_000
  end

  defp bound!(dir) do
    {binding, context, profile, _resources} = bound_resources!(dir)
    {binding, context, profile}
  end

  defp bound_resources!(dir, opts \\ []) do
    resources =
      start_supervised!(
        {CodexResources, Keyword.merge([workspace: dir, owner_pid: self()], opts)}
      )

    assert {:ok, binding} = CodexResources.bind(resources, authority("first"))
    assert {:ok, context} = CodexResources.context(resources, binding)

    assert Map.has_key?(context, :extension_runtime),
           "native resources must own a skills extension runtime"

    assert {:ok, profile} =
             NativeTools.profile(context, authority("first"), %{hook_specs: []}, tools: @skills)

    assert :ok = Session.attach(binding, profile)
    {binding, context, profile, resources}
  end

  defp authority(run_id),
    do: %{caller: "skills-test", run_id: run_id, grants: @skills, tool_revision: 1}

  defp execute(context, binding, name, args) do
    ExtensionRuntime.call(%{
      tool_name: name,
      arguments: args,
      run_id: binding.run_id,
      incarnation: binding.run_incarnation,
      backend_context: %{runtime: context.extension_runtime}
    })
  end

  defp detach!(binding) do
    assert :ok = Session.prepare_detach(binding)
    assert {:ok, %{status: :retained}} = Session.detach(binding)
  end

  defp list_rest!(_context, _binding, nil), do: []

  defp list_rest!(context, binding, cursor) do
    assert {:ok, page} =
             execute(context, binding, "skills::list", %{
               "authority" => "executor",
               "cursor" => cursor
             })

    page.skills ++ list_rest!(context, binding, page.next_cursor)
  end

  defp read_rest!(_context, _binding, _args, nil), do: ""

  defp read_rest!(context, binding, args, cursor) do
    assert {:ok, page} =
             execute(context, binding, "skills::read", Map.put(args, "cursor", cursor))

    assert String.valid?(page.contents)
    page.contents <> read_rest!(context, binding, args, page.next_cursor)
  end

  defp name(index), do: "skill-" <> String.pad_leading(Integer.to_string(index), 2, "0")
  defp repo_root(dir), do: Path.join([dir, ".agents", "skills"])

  defp skill!(skills_root, name, body, policy \\ "") do
    root = Path.join(skills_root, name)
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "SKILL.md"),
      "---\nname: #{name}\ndescription: #{name}\n#{policy}---\n#{body}"
    )

    root
  end
end
