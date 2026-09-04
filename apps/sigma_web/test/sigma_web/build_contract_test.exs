defmodule Sigma.Web.BuildContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @ci_path Path.join(@repo_root, ".github/workflows/ci.yml")
  @test_path Path.join(@repo_root, ".github/workflows/test.yml")
  @release_path Path.join(@repo_root, ".github/workflows/release.yml")
  @patch_task_path Path.join(@repo_root, "apps/sigma_web/lib/mix/tasks/deps.patch.ex")
  @release_smoke_path Path.join(@repo_root, "scripts/verify-release-agent-smoke.exs")

  test "normal setup, asset, and release aliases never patch installed dependencies" do
    aliases = Sigma.MixProject.project()[:aliases]

    refute alias_commands(aliases[:setup]) =~ "deps.patch"
    refute alias_commands(aliases[:"assets.setup"]) =~ "deps.patch"
    refute alias_commands(aliases[:"assets.build"]) =~ "deps.patch"
    refute alias_commands(aliases[:"assets.deploy"]) =~ "deps.patch"
    refute alias_commands(aliases[:"sigma.rel-build"]) =~ "deps.patch"
    refute File.exists?(@patch_task_path)
  end

  test "CI exposes Elixir, Rust, assets, and release smoke as independent jobs" do
    source = File.read!(@ci_path)

    assert source =~ ~r/^  elixir:/m
    assert source =~ ~r/^  rust:/m
    assert source =~ ~r/^  assets:/m
    assert source =~ ~r/^  release_smoke:/m
    assert source =~ "mix compile --warnings-as-errors"
    assert source =~ "cargo test --manifest-path"
    assert source =~ "mix assets.setup"
    assert source =~ "mix test --only assets"
    assert source =~ "verify-release-agent-smoke.exs"
  end

  test "the core ExUnit job is independent from asset installation" do
    source = File.read!(@test_path)

    assert source =~ "mix deps.get"
    assert source =~ "mix test"
    refute source =~ "Set up Bun"
    refute source =~ "mix assets.setup"
  end

  test "the core ExUnit job force-rebuilds cached applications before testing" do
    source = File.read!(@test_path)

    assert {cache_offset, _length} =
             :binary.match(source, "- name: Restore exact test cache")

    assert {compile_offset, _length} =
             :binary.match(source, "mix compile --force --warnings-as-errors")

    assert {test_offset, _length} = :binary.match(source, "- name: Run unit tests")

    assert cache_offset < compile_offset
    assert compile_offset < test_offset
  end

  test "workflow caches never fall back across lockfile revisions" do
    sources = Enum.map_join([@ci_path, @test_path, @release_path], "\n", &File.read!/1)

    refute sources =~ "restore-keys:"
  end

  test "release verification gates every artifact build at the resolved source SHA" do
    source = File.read!(@release_path)

    assert source =~ ~r/^  verify:/m
    assert source =~ "needs: resolve"
    assert source =~ ~S|ref: ${{ needs.resolve.outputs.source_sha }}|
    assert source =~ ~r/build:\n(?:.*\n){0,8}\s+needs:\n\s+- resolve\n\s+- verify/m
    assert source =~ "verify-release-agent-smoke.exs"
    assert source =~ ~S|candidate_ref="release-candidate/v${VERSION}"|
    assert source =~ ~S|"${SOURCE_SHA}:refs/heads/${BRANCH}"|
    refute source =~ "- name: Set release version"
  end

  test "the reusable installed-release smoke drives a fake-provider agent turn" do
    source = File.read!(@release_smoke_path)

    assert source =~ "defmodule Sigma.ReleaseSmokeProvider"
    assert source =~ "Sigma.Agent.Runtime.get_session"
    assert source =~ "Sigma.Agent.prompt"
    assert source =~ "{:agent_end, messages}"
    assert source =~ "release smoke response"
  end

  defp alias_commands(commands) do
    commands
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end
end
