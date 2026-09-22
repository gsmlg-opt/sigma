defmodule Sigma.Session.Skills.RemoteSourceTest do
  use ExUnit.Case, async: true

  alias Backplane.SkillProtocol.{Bundle, Error, Resource, SkillRef, Wire}
  alias Sigma.Session.Skills.{RemoteCache, RemoteSource}

  @moduletag :tmp_dir

  test "package redirects are refused and credential failures are redacted", %{tmp_dir: tmp_dir} do
    assert {:ok, redirecting} =
             remote(tmp_dir, fn _request -> {:ok, %{status: 302, body: ""}} end)

    assert {:error, %Error{message: "redirect response was refused"}} =
             RemoteSource.catalog(redirecting)

    secret = "credential-that-must-not-escape"

    assert {:ok, redacting} =
             remote(tmp_dir,
               credential_supplier: fn -> {:error, secret} end,
               transport: fn _request -> flunk("transport must not run") end
             )

    assert {:error, error} = RemoteSource.catalog(redacting)
    refute inspect(error) =~ secret
  end

  test "online preparation resolves once, binds only the verified cache, and supports explicit offline reuse",
       %{tmp_dir: tmp_dir} do
    fixture = bundle_fixture(tmp_dir, "rev-1")
    owner = self()
    transport = fixture_transport(fixture, owner)
    assert {:ok, remote} = remote(tmp_dir, transport)

    assert {:ok, prepared} = RemoteSource.prepare(remote, "remote-skill")
    assert_receive {:request, "/skill-protocol/v1/resolve", _query, _headers}
    assert_receive {:request, "/skill-protocol/v1/artifact", _query, _headers}
    refute_receive {:request, "/skill-protocol/v1/resolve", _query, _headers}
    assert {:ok, skill_document} = Resource.read(prepared, "SKILL.md")
    assert skill_document =~ "Remote body"

    offline_transport = fn _request -> flunk("offline reuse must not perform network I/O") end

    assert {:ok, offline} =
             remote(tmp_dir,
               transport: offline_transport,
               cache_root: remote.cache_root,
               binding_path: remote.binding_path
             )

    assert {:ok, reused} = RemoteSource.prepare(offline, "remote-skill", offline: true)
    assert reused.root == prepared.root
    assert reused.manifest.ref == prepared.manifest.ref
  end

  test "digest mismatch publishes neither cache nor binding", %{tmp_dir: tmp_dir} do
    fixture = bundle_fixture(tmp_dir, "rev-bad")
    wrong = Map.put(fixture.manifest, "artifact_digest", "sha256:" <> String.duplicate("0", 64))
    transport = fixture_transport(%{fixture | manifest: wrong}, self())
    assert {:ok, remote} = remote(tmp_dir, transport)

    assert {:error, %Error{code: :integrity_mismatch}} =
             RemoteSource.prepare(remote, "remote-skill")

    refute File.exists?(remote.binding_path)
    assert [] == published_entries(remote.cache_root)
  end

  test "a historical revision is exact and never falls forward", %{tmp_dir: tmp_dir} do
    fixture = bundle_fixture(tmp_dir, "latest")
    transport = fixture_transport(fixture, self())
    assert {:ok, remote} = remote(tmp_dir, transport)

    assert {:error, %Error{code: :integrity_mismatch}} =
             RemoteSource.prepare(remote, "remote-skill", revision: "historical")

    assert_receive {:request, "/skill-protocol/v1/resolve", %{"revision" => "historical"}, _}
    refute_receive {:request, "/skill-protocol/v1/artifact", _, _}
    refute File.exists?(remote.binding_path)
  end

  test "explicit offline selection fails when no exact binding is cached", %{tmp_dir: tmp_dir} do
    assert {:ok, remote} = remote(tmp_dir, fn _ -> flunk("offline must not use transport") end)

    assert {:error, %Error{code: :not_found}} =
             RemoteSource.prepare(remote, "remote-skill", offline: true)
  end

  test "concurrent prepares expose either no cache entry or one complete verified root", %{
    tmp_dir: tmp_dir
  } do
    fixture = bundle_fixture(tmp_dir, "rev-concurrent")
    owner = self()

    transport = fn request ->
      uri = URI.parse(request.url)
      send(owner, {:request, uri.path, URI.decode_query(uri.query || ""), request.headers})

      if uri.path == "/skill-protocol/v1/artifact" do
        send(owner, {:artifact_waiting, self()})
        receive do: (:release_artifact -> {:ok, %{status: 200, body: fixture.archive}})
      else
        {:ok, %{status: 200, body: Jason.encode!(fixture.manifest)}}
      end
    end

    assert {:ok, remote} = remote(tmp_dir, transport)
    first = Task.async(fn -> RemoteSource.prepare(remote, "remote-skill") end)
    second = Task.async(fn -> RemoteSource.prepare(remote, "remote-skill") end)
    assert_receive {:artifact_waiting, worker_1}
    assert_receive {:artifact_waiting, worker_2}

    assert {:error, %Error{code: :not_found}} = RemoteCache.load(remote.cache_root, fixture.ref)
    send(worker_1, :release_artifact)
    send(worker_2, :release_artifact)

    assert {:ok, prepared_1} = Task.await(first)
    assert {:ok, prepared_2} = Task.await(second)
    assert prepared_1.root == prepared_2.root
    assert {:ok, loaded} = RemoteCache.load(remote.cache_root, fixture.ref)
    assert File.regular?(Path.join(loaded.root, "SKILL.md"))
  end

  defp remote(tmp_dir, transport_or_opts) when is_function(transport_or_opts, 1) do
    remote(tmp_dir, transport: transport_or_opts)
  end

  defp remote(tmp_dir, opts) do
    defaults = [
      endpoint: "https://skills.example.test",
      source_id: "backplane:test",
      access_context_id: "tenant:test",
      credential_supplier: fn -> "test-token" end,
      max_attempts: 1,
      cache_root: Path.join(tmp_dir, "cache"),
      binding_path: Path.join(tmp_dir, "bindings.json")
    ]

    RemoteSource.new(Keyword.merge(defaults, opts))
  end

  defp bundle_fixture(tmp_dir, revision) do
    root = Path.join(tmp_dir, "remote-skill-#{revision}")
    archive_path = Path.join(tmp_dir, "artifact-#{revision}.tar.gz")
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "SKILL.md"),
      "---\nname: remote-skill-#{revision}\ndescription: Remote\n---\nRemote body"
    )

    ref = %SkillRef{source_id: "backplane:test", skill_id: "remote-skill", revision: revision}
    assert {:ok, bundle} = Bundle.pack(root, archive_path, ref: ref)
    exact_ref = bundle.manifest.ref

    %{
      archive: File.read!(archive_path),
      manifest: Wire.manifest_map(bundle.manifest),
      ref: exact_ref
    }
  end

  defp fixture_transport(fixture, owner) do
    fn request ->
      uri = URI.parse(request.url)
      query = URI.decode_query(uri.query || "")
      send(owner, {:request, uri.path, query, request.headers})

      case uri.path do
        "/skill-protocol/v1/resolve" ->
          {:ok, %{status: 200, body: Jason.encode!(fixture.manifest)}}

        "/skill-protocol/v1/artifact" ->
          {:ok, %{status: 200, body: fixture.archive}}
      end
    end
  end

  defp published_entries(cache_root) do
    cache_root
    |> Path.join("**/metadata.json")
    |> Path.wildcard()
  end
end
