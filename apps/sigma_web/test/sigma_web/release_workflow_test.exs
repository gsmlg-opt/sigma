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

  test "smokes the installed Linux archive before publishing" do
    source = File.read!(@workflow_path)

    assert {verify_offset, _length} = :binary.match(source, "- name: Verify release artifacts")

    assert {smoke_offset, _length} =
             :binary.match(source, "- name: Smoke installed Linux release")

    assert {commit_offset, _length} =
             :binary.match(source, "- name: Commit version and create tag")

    assert verify_offset < smoke_offset
    assert smoke_offset < commit_offset
    assert source =~ ~S|sigma-v${VERSION}-linux-amd64.tar.gz|
    assert source =~ "sigma-user-service"
    assert source =~ "Application.spec(:backplane_mcp_protocol, :vsn)"
    assert source =~ ~S|test "$dependency_version" = "0.6.2"|
    assert source =~ ~S|if [[ "$http_code" == 200 ]]|
    assert source =~ ~S|kill -TERM "$smoke_pid"|
    assert source =~ "for _cleanup_attempt in $(seq 1 20)"
    assert source =~ ~S|kill -KILL "$smoke_pid"|
    assert source =~ ~S(wait "$smoke_pid" || true)
    assert source =~ ~S(ss -H -ltn "sport = :${smoke_port}")
  end
end
