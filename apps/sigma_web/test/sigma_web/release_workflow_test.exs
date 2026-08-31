defmodule Sigma.Web.ReleaseWorkflowTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @workflow_path Path.join(@repo_root, ".github/workflows/release.yml")

  test "cleans the release target before assembling cached builds" do
    source = File.read!(@workflow_path)

    assert {step_offset, _length} = :binary.match(source, "- name: Build release")
    assert {cleanup_offset, _length} = :binary.match(source, "rm -rf _build/prod/rel/sigma")
    assert {release_offset, _length} = :binary.match(source, "mix release sigma --overwrite")

    assert step_offset < cleanup_offset
    assert cleanup_offset < release_offset
  end
end
