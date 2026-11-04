defmodule Sigma.Web.PluginsSettingsLiveTest do
  use Sigma.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Backplane.PluginProtocol.Archive
  alias Sigma.Session.{ConfigEvents, ConfigManager}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.fetch_env(:sigma_session, :agent_dir)
    agent_dir = Path.join(dir, "agent")
    Application.put_env(:sigma_session, :agent_dir, agent_dir)
    File.mkdir_p!(agent_dir)

    log = Path.join(dir, "http.jsonl")
    File.write!(log, "")
    root = Path.join(dir, "plugins")
    python = System.find_executable("python3")
    assert is_binary(python)

    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        args: ["-u", "-c", registry(), dir, root, log]
      ])

    assert_receive {^port, {:data, address}}, 5_000
    {number, ""} = Integer.parse(String.trim(address))

    config = %{
      "registryUrl" => "http://127.0.0.1:#{number}",
      "requestsRoot" => root
    }

    files = %{
      "plugin.json" =>
        Jason.encode!(%{
          "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
          "name" => "example",
          "version" => "1.0.0"
        }),
      "skills/example/SKILL.md" =>
        "---\r\nname: example\r\ndescription: Installed example\r\n---\r\n  精确原文\r\n"
    }

    assert {:ok, artifact} = Archive.pack(files)
    File.write!(Path.join(dir, "artifact.tgz"), artifact)

    File.write!(
      Path.join(dir, "release.json"),
      Jason.encode!(%{
        "plugin_id" => "plugin-example",
        "release_id" => "release-example",
        "artifact_digest" => Archive.digest(artifact)
      })
    )

    on_exit(fn ->
      case Registry.lookup(Sigma.Agent.RepositoryRegistry, {:plugin_requests, root}) do
        [{pid, _}] -> GenServer.stop(pid, :normal)
        [] -> :ok
      end

      if Port.info(port), do: Port.close(port)

      case previous do
        {:ok, value} -> Application.put_env(:sigma_session, :agent_dir, value)
        :error -> Application.delete_env(:sigma_session, :agent_dir)
      end
    end)

    %{
      dir: dir,
      config: config,
      root: root,
      requests: Path.join(root, "requests.json"),
      log: log,
      files: files,
      settings: Path.join(agent_dir, "settings.json")
    }
  end

  test "the settings entry remains unconfigured without choosing a registry", c do
    {:ok, view, _} = live(c.conn, "/settings/plugins")
    html = render_async(view)

    assert has_element?(view, "a[href='/settings/plugins']", "Plugins")
    assert html =~ "No plugin registry is configured."
    refute File.exists?(c.requests)
    assert File.read!(c.log) == ""

    view |> element("#plugins-refresh") |> render_click()
    assert render_async(view) =~ "No plugin registry is configured."
    refute File.exists?(c.requests)
  end

  test "requests are read without effects, paged, and refreshed when their revision changes", c do
    configure!(c)
    requests!(c, 22)
    {:ok, view, _} = live(c.conn, "/settings/plugins")
    render_async(view)

    cards =
      view
      |> element("#plugin-requests")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.find("article[id^='plugin-request-']")

    assert length(cards) == 20
    assert has_element?(view, "#plugin-page-position", "of 22")
    before = File.read!(c.requests)
    view |> element("#plugins-next") |> render_click()
    render_async(view)
    assert has_element?(view, "#plugin-page-position", "of 22")
    refute has_element?(view, "#plugins-next")
    assert File.read!(c.requests) == before
    assert File.read!(c.log) == ""

    view |> element("#plugins-first") |> render_click()
    render_async(view)
    requests!(c, 23)
    changed = File.read!(c.requests)
    view |> element("#plugins-next") |> render_click()
    render_async(view)
    html = render_async(view)
    assert html =~ "Plugin requests changed. Showing the first page again."
    assert has_element?(view, "#plugin-page-position", "of 23")
    assert has_element?(view, "#plugins-next")
    assert File.read!(c.requests) == changed
    assert File.read!(c.log) == ""
  end

  test "an explicit installation downloads once and reloads its durable installed receipt", c do
    configure!(c)
    [request] = requests!(c, 1)
    original = File.read!(c.requests)
    {:ok, view, _} = live(c.conn, "/settings/plugins")
    render_async(view)
    assert File.read!(c.log) == ""

    view |> element("[phx-click='install_plugin']") |> render_click()
    render_async(view)
    html = render_async(view)
    assert html =~ "Installed plugin-example"
    assert has_element?(view, "#plugin-installation-result", "release-example")
    refute has_element?(view, "[phx-click='install_plugin']")

    [installed] = installations(c)
    assert installed["request_id"] == request["id"]
    assert installed["status"] == "installed"
    assert length(http_requests(c)) == 2

    for {relative, bytes} <- c.files do
      assert File.read!(Path.join(installed["root"], relative)) == bytes
    end

    assert File.read!(c.requests) == original
    before = File.read!(Path.join(c.root, "installations.json"))
    view |> element("#plugins-refresh") |> render_click()
    render_async(view)
    assert has_element?(view, "#plugin-installation-result", "Installed plugin-example")
    assert File.read!(Path.join(c.root, "installations.json")) == before
    assert length(http_requests(c)) == 2

    {:ok, reopened, _} = live(c.conn, "/settings/plugins")
    render_async(reopened)
    assert has_element?(reopened, "#plugin-requests", "Installed")
    refute has_element?(reopened, "[phx-click='install_plugin']")
    assert File.read!(c.requests) == original
    assert File.read!(Path.join(c.root, "installations.json")) == before
    assert length(http_requests(c)) == 2
  end

  test "a committed installation stays visible if its subsequent list refresh fails", c do
    configure!(c)
    requests!(c, 1)
    File.write!(Path.join(c.dir, "break-refresh"), "yes")
    {:ok, view, _} = live(c.conn, "/settings/plugins")
    render_async(view)

    view |> element("[phx-click='install_plugin']") |> render_click()
    render_async(view)
    render_async(view)

    assert has_element?(view, "#plugin-installation-result", "Installed plugin-example")
    assert has_element?(view, "#plugins-error")
    assert [%{"status" => "installed"}] = installations(c)
    assert length(http_requests(c)) == 2
  end

  test "configuration notifications reload the selected registry without starting installation",
       c do
    configure!(c)
    requests!(c, 1)
    {:ok, view, _} = live(c.conn, "/settings/plugins")
    render_async(view)
    assert has_element?(view, "#plugin-requests", "plugin-example")

    File.write!(c.settings, "{}")
    ConfigEvents.broadcast()
    render_async(view)
    render_async(view)
    assert has_element?(view, "#plugins-unconfigured")
    assert File.read!(c.log) == ""
    refute File.exists?(Path.join(c.root, "installations.json"))
    assert ConfigManager.get_plugin_config() == nil
  end

  defp configure!(c), do: File.write!(c.settings, Jason.encode!(%{"plugins" => c.config}))

  defp requests!(c, count) do
    requests =
      Enum.map(1..count, fn index ->
        %{
          "id" => "plugin-request-#{index}",
          "status" => "requested",
          "registry_url" => c.config["registryUrl"],
          "arguments" => %{
            "tool_type" => "plugin",
            "action_type" => "install",
            "tool_id" => "plugin-example",
            "suggest_reason" => "  请安装\r\n完整原文 #{index}"
          },
          "invocation" => %{"invocation_id" => "ui-fixture-#{index}"},
          "requested_at" => 1_700_000_000_000_000 + index
        }
      end)

    File.mkdir_p!(c.root)
    File.write!(c.requests, Jason.encode!(%{"version" => 1, "requests" => requests}))
    requests
  end

  defp installations(c) do
    c.root
    |> Path.join("installations.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("installations")
  end

  defp http_requests(c), do: c.log |> File.read!() |> String.split("\n", trim: true)

  defp registry do
    """
    import http.server,json,pathlib,sys,threading,urllib.parse
    directory,root,log_path=map(pathlib.Path,sys.argv[1:])
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def do_GET(self):
            with log_path.open('a') as log: log.write(json.dumps({'path':self.path})+'\\n')
            path=urllib.parse.urlsplit(self.path).path
            if '/artifacts/' in path:
                if (directory/'break-refresh').exists(): (root/'requests.json').write_text('{')
                body=(directory/'artifact.tgz').read_bytes()
            else:
                body=(directory/'release.json').read_bytes()
            self.send_response(200)
            self.send_header('content-type','application/octet-stream' if '/artifacts/' in path else 'application/json')
            self.send_header('content-length',str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    print(server.server_address[1],flush=True)
    def close_on_eof():
        sys.stdin.buffer.read()
        server.shutdown()
    threading.Thread(target=close_on_eof,daemon=True).start()
    server.serve_forever()
    server.server_close()
    """
  end
end
