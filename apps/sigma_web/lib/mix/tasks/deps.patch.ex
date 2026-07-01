defmodule Mix.Tasks.Deps.Patch do
  @moduledoc """
  Mix task to apply custom patches to dependencies.
  Ensures that edits to hex_solver and npm in deps/ are persistent
  across package updates or clean deps.
  """

  use Mix.Task

  @shortdoc "Applies persistent patches to hex_solver and npm dependencies"

  @impl Mix.Task
  def run(_args) do
    {hex_solver_dep, patched_hex_solver} = patch_hex_solver()
    {npm_dep, patched_npm} = patch_npm()

    if patched_hex_solver do
      Mix.shell().info("Recompiling #{hex_solver_dep}...")
      recompile_dep(hex_solver_dep)
    end

    if patched_npm do
      Mix.shell().info("Recompiling #{npm_dep}...")
      recompile_dep(npm_dep)
    end

    Mix.shell().info("Dependencies patch check completed.")
  end

  defp patch_hex_solver do
    {dep_name, dep_path} =
      dep_path([
        {"duskmoon_hex_solver", "deps/duskmoon_hex_solver"},
        {"hex_solver", "deps/hex_solver"}
      ])

    file_path = Path.join(dep_path, "lib/hex_solver/requirement.ex")

    patched =
      if File.exists?(file_path) do
        content = File.read!(file_path)

        # Check if already patched
        if String.contains?(content, "defp delex([op | rest], acc) when op in [:&&, :and] do") do
          false
        else
          target = "  defp delex([op, version | rest], acc) do"

          patch = """
            defp delex([op | rest], acc) when op in [:&&, :and] do
              delex(rest, acc)
            end

            defp delex([op, version | rest], acc) do\
          """

          new_content = String.replace(content, target, patch)
          File.write!(file_path, new_content)
          Mix.shell().info("Patched #{file_path}")
          true
        end
      else
        Mix.shell().error("hex_solver requirement.ex not found at #{file_path}")
        false
      end

    {dep_name, patched}
  end

  defp patch_npm do
    {dep_name, dep_path} = dep_path([{"duskmoon_npm", "deps/duskmoon_npm"}, {"npm", "deps/npm"}])
    npm_lib_path = Path.join(dep_path, "lib")
    resolver_path = Path.join(npm_lib_path, "npm/resolver.ex")
    npm_path = Path.join(npm_lib_path, "npm.ex")
    linker_path = Path.join(npm_lib_path, "npm/install/linker.ex")
    registry_path = Path.join(npm_lib_path, "npm/registry.ex")
    tarball_path = Path.join(npm_lib_path, "npm/tarball.ex")
    proxy_path = Path.join(npm_lib_path, "npm/proxy.ex")

    patched_resolver =
      if File.exists?(resolver_path) do
        content = File.read!(resolver_path)

        # 1. Patch is_atom(key)
        content1 =
          if String.contains?(content, "when is_atom(key) -> acc") do
            new =
              String.replace(
                content,
                "when is_atom(key) -> acc",
                "when not is_binary(key) -> acc"
              )

            Mix.shell().info("Patched #{resolver_path} (is_atom/is_binary)")
            new
          else
            content
          end

        # 2. Patch resolve_with_nesting/4 to pass root_deps
        content2 =
          if String.contains?(content, "conflict_pkg = extract_conflict_package(message)") do
            new =
              String.replace(
                content1,
                "conflict_pkg = extract_conflict_package(message)",
                "conflict_pkg = extract_conflict_package(message, root_deps)"
              )

            Mix.shell().info("Patched #{resolver_path} (resolve_with_nesting)")
            new
          else
            content1
          end

        # 3. Patch resolver prefetches so slow registry fetches do not exit callers
        content3 =
          content2
          |> String.replace(
            "      max_concurrency: @prefetch_concurrency,\n      timeout: @fetch_timeout\n    )",
            "      max_concurrency: @prefetch_concurrency,\n      timeout: @fetch_timeout,\n      on_timeout: :kill_task\n    )"
          )
          |> String.replace(
            "        max_concurrency: @prefetch_concurrency,\n        timeout: @fetch_timeout\n      )",
            "        max_concurrency: @prefetch_concurrency,\n        timeout: @fetch_timeout,\n        on_timeout: :kill_task\n      )"
          )

        if content3 != content2 do
          Mix.shell().info("Patched #{resolver_path} (prefetch timeout handling)")
        end

        # 4. Patch extract_conflict_package/1 to extract_conflict_package/2
        if String.contains?(content3, "defp extract_conflict_package(message) do") do
          target = """
            defp extract_conflict_package(message) do
              # Look for patterns like: "ms 2.0.0" and "ms 2.1.3" in the error
              case Regex.scan(~r/"(\\S+) (\\d+\\.\\d+\\.\\d+)"/, message) do
                [_, _ | _] = matches ->
                  names = Enum.map(matches, fn [_, name, _] -> name end)

                  names
                  |> Enum.frequencies()
                  |> Enum.filter(fn {_, count} -> count >= 2 end)
                  |> Enum.map(&elem(&1, 0))
                  |> List.first()

                _ ->
                  nil
              end
            end\
          """

          replacement = """
            defp extract_conflict_package(message, root_deps) do
              root_keys = Map.keys(root_deps)

              # First, try to match the root conflict pattern
              root_conflict =
                case Regex.run(~r/not ([@a-zA-Z0-9_\\-\\/\\.]+) .* is satisfied by \\1 (?!not\\b)/, message) do
                  [_, name] -> name
                  _ -> nil
                end

              if root_conflict && root_conflict not in root_keys do
                root_conflict
              else
                # Fallback to general quoted package names with version ranges
                case Regex.scan(~r/"([@a-zA-Z0-9_\\-\\/\\.]+) ([^"]+)"/, message) do
                  [_ | _] = matches ->
                    names = Enum.map(matches, fn [_, name, _] -> name end)

                    names
                    |> Enum.frequencies()
                    |> Enum.filter(fn {name, count} -> count >= 2 and name not in root_keys end)
                    |> Enum.sort_by(fn {_, count} -> count end, :desc)
                    |> Enum.map(&elem(&1, 0))
                    |> List.first()

                  _ ->
                    # Original fallback for exact versions
                    case Regex.scan(~r/"(\\S+) (\\d+\\.\\d+\\.\\d+)"/, message) do
                      [_, _ | _] = matches ->
                        names = Enum.map(matches, fn [_, name, _] -> name end)

                        names
                        |> Enum.frequencies()
                        |> Enum.filter(fn {name, count} -> count >= 2 and name not in root_keys end)
                        |> Enum.map(&elem(&1, 0))
                        |> List.first()

                      _ ->
                        nil
                    end
                end
              end
            end\
          """

          # Normalize newlines for match safety
          normalized_content = String.replace(content3, "\r\n", "\n")
          normalized_target = String.replace(target, "\r\n", "\n")
          normalized_replacement = String.replace(replacement, "\r\n", "\n")

          new_content =
            String.replace(normalized_content, normalized_target, normalized_replacement)

          File.write!(resolver_path, new_content)
          Mix.shell().info("Patched #{resolver_path} (extract_conflict_package)")
          true
        else
          if content3 != content do
            File.write!(resolver_path, content3)
            true
          else
            false
          end
        end
      else
        Mix.shell().error("npm resolver.ex not found at #{resolver_path}")
        false
      end

    patched_npm_core =
      if File.exists?(npm_path) do
        content = File.read!(npm_path)

        # 1. Patch Linker.link_nested call to use lockfile instead of flat
        # 2. Rename unused flat parameter to _flat
        if String.contains?(content, "Linker.link_nested(nested_info, flat, @node_modules)") do
          target = """
            defp link_and_nest(lockfile, nested_info, flat, local_links) do
              with :ok <- link_from_lockfile(lockfile, local_links) do
                if nested_info != %{}, do: Linker.link_nested(nested_info, flat, @node_modules)
                :ok
              end
            end\
          """

          replacement = """
            defp link_and_nest(lockfile, nested_info, _flat, local_links) do
              with :ok <- link_from_lockfile(lockfile, local_links) do
                if nested_info != %{}, do: Linker.link_nested(nested_info, lockfile, @node_modules)
                :ok
              end
            end\
          """

          normalized_content = String.replace(content, "\r\n", "\n")
          normalized_target = String.replace(target, "\r\n", "\n")
          normalized_replacement = String.replace(replacement, "\r\n", "\n")

          new_content =
            String.replace(normalized_content, normalized_target, normalized_replacement)

          File.write!(npm_path, new_content)
          Mix.shell().info("Patched #{npm_path} (link_and_nest)")
          true
        else
          false
        end
      else
        Mix.shell().error("npm.ex not found at #{npm_path}")
        false
      end

    patched_registry = patch_npm_registry(registry_path)
    patched_tarball = patch_npm_tarball(tarball_path)
    patched_proxy = patch_npm_proxy(proxy_path)
    patched_linker = patch_npm_linker(linker_path)

    patched =
      patched_resolver or patched_npm_core or patched_registry or patched_tarball or patched_proxy or
        patched_linker

    {dep_name, patched}
  end

  defp patch_npm_linker(file_path) do
    if File.exists?(file_path) do
      content = File.read!(file_path)

      if String.contains?(
           content,
           "defp install_nested_dependencies(info, package_dir, strategy, seen)"
         ) do
        false
      else
        target = """
          defp install_single_nested(_pkg, nil, _parent, _nm_dir, _strategy), do: :ok

          defp install_single_nested(pkg, version, parent, nm_dir, strategy) do
            with {:ok, packument} <- NPM.Registry.get_packument(pkg),
                 %{} = info <- Map.get(packument.versions, version),
                 {:ok, cache_result} <-
                   NPM.Cache.ensure(pkg, version, info.dist.tarball, info.dist.integrity) do
              if cache_result != :missing_optional do
                cache_path = NPM.Cache.package_dir(pkg, version)
                target = Path.join([nm_dir, parent, "node_modules", pkg])
                link_package(cache_path, target, strategy)
              else
                :ok
              end
            else
              _ -> :ok
            end

            :ok
          end\
        """

        replacement = """
          defp install_single_nested(_pkg, nil, _parent, _nm_dir, _strategy), do: :ok

          defp install_single_nested(pkg, version, parent, nm_dir, strategy) do
            with {:ok, packument} <- NPM.Registry.get_packument(pkg),
                 %{} = info <- Map.get(packument.versions, version),
                 {:ok, cache_result} <-
                   NPM.Cache.ensure(pkg, version, info.dist.tarball, info.dist.integrity) do
              if cache_result != :missing_optional do
                cache_path = NPM.Cache.package_dir(pkg, version)
                target = Path.join([nm_dir, parent, "node_modules", pkg])
                link_package(cache_path, target, strategy)
                install_nested_dependencies(info, target, strategy, MapSet.new([{pkg, version}]))
              else
                :ok
              end
            else
              _ -> :ok
            end

            :ok
          end

          defp install_nested_dependencies(info, package_dir, strategy, seen) do
            deps =
              info.dependencies
              |> Map.merge(NPM.PlatformOptional.select(info.optional_dependencies))

            Enum.each(deps, fn {dep, range} ->
              version = resolve_nested_version(dep, range)
              install_nested_dependency(dep, version, package_dir, strategy, seen)
            end)
          end

          defp install_nested_dependency(_dep, nil, _package_dir, _strategy, _seen), do: :ok

          defp install_nested_dependency(dep, version, package_dir, strategy, seen) do
            key = {dep, version}

            unless MapSet.member?(seen, key) do
              with {:ok, packument} <- NPM.Registry.get_packument(dep),
                   %{} = info <- Map.get(packument.versions, version),
                   {:ok, cache_result} <-
                     NPM.Cache.ensure(dep, version, info.dist.tarball, info.dist.integrity) do
                if cache_result != :missing_optional do
                  cache_path = NPM.Cache.package_dir(dep, version)
                  target = Path.join([package_dir, "node_modules", dep])
                  link_package(cache_path, target, strategy)
                  install_nested_dependencies(info, target, strategy, MapSet.put(seen, key))
                else
                  :ok
                end
              else
                _ -> :ok
              end
            end

            :ok
          end\
        """

        normalized_content = String.replace(content, "\r\n", "\n")
        normalized_target = String.replace(target, "\r\n", "\n")
        normalized_replacement = String.replace(replacement, "\r\n", "\n")

        new_content =
          String.replace(normalized_content, normalized_target, normalized_replacement)

        if new_content != normalized_content do
          File.write!(file_path, new_content)
          Mix.shell().info("Patched #{file_path} (nested dependency linking)")
          true
        else
          false
        end
      end
    else
      Mix.shell().error("npm linker.ex not found at #{file_path}")
      false
    end
  end

  defp patch_npm_registry(file_path) do
    if File.exists?(file_path) do
      content = File.read!(file_path)

      if String.contains?(content, "connect_options: NPM.Proxy.connect_options(url)") do
        false
      else
        target = """
              Req.get(url,
                headers: headers,
                decode_body: false,
                redirect: NPM.Config.allow_registry_redirects?()
              )\
        """

        replacement = """
              Req.get(url,
                headers: headers,
                decode_body: false,
                redirect: NPM.Config.allow_registry_redirects?(),
                connect_options: NPM.Proxy.connect_options(url)
              )\
        """

        new_content =
          content
          |> String.replace("\r\n", "\n")
          |> String.replace(
            String.replace(target, "\r\n", "\n"),
            String.replace(replacement, "\r\n", "\n")
          )

        if new_content != content do
          File.write!(file_path, new_content)
          Mix.shell().info("Patched #{file_path} (proxy connect options)")
          true
        else
          false
        end
      end
    else
      Mix.shell().error("npm registry.ex not found at #{file_path}")
      false
    end
  end

  defp patch_npm_tarball(file_path) do
    if File.exists?(file_path) do
      content = File.read!(file_path)

      if String.contains?(content, "connect_options: NPM.Proxy.connect_options(tarball_url)") do
        false
      else
        new_content =
          String.replace(
            content,
            "case Req.get(tarball_url, decode_body: false) do",
            """
            case Req.get(tarball_url,
                   decode_body: false,
                   connect_options: NPM.Proxy.connect_options(tarball_url)
                 ) do\
            """
          )

        if new_content != content do
          File.write!(file_path, new_content)
          Mix.shell().info("Patched #{file_path} (proxy connect options)")
          true
        else
          false
        end
      end
    else
      Mix.shell().error("npm tarball.ex not found at #{file_path}")
      false
    end
  end

  defp patch_npm_proxy(file_path) do
    content = """
    defmodule NPM.Proxy do
      @moduledoc false

      def connect_options(url) do
        uri = URI.parse(url)
        proxy = proxy_env(uri.scheme)

        if proxy && not no_proxy?(uri.host) do
          proxy_connect_options(proxy)
        else
          []
        end
      end

      defp proxy_connect_options(proxy) do
        uri = URI.parse(proxy)

        with scheme when scheme in [:http, :https] <- proxy_scheme(uri.scheme),
             host when is_binary(host) <- uri.host do
          [proxy: {scheme, host, uri.port || default_proxy_port(scheme), []}]
        else
          _ -> []
        end
      end

      defp proxy_env("https") do
        System.get_env("https_proxy") ||
          System.get_env("HTTPS_PROXY") ||
          System.get_env("all_proxy") ||
          System.get_env("ALL_PROXY")
      end

      defp proxy_env("http") do
        System.get_env("http_proxy") ||
          System.get_env("HTTP_PROXY") ||
          System.get_env("all_proxy") ||
          System.get_env("ALL_PROXY")
      end

      defp proxy_env(_), do: nil

      defp no_proxy?(host) when host in [nil, ""], do: false

      defp no_proxy?(host) do
        host = String.downcase(host)

        (System.get_env("no_proxy") || System.get_env("NO_PROXY") || "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.any?(fn
          "*" -> true
          "." <> suffix -> String.ends_with?(host, String.downcase(suffix))
          entry -> host == String.downcase(entry)
        end)
      end

      defp proxy_scheme("http"), do: :http
      defp proxy_scheme("https"), do: :https
      defp proxy_scheme(_), do: nil

      defp default_proxy_port(:https), do: 443
      defp default_proxy_port(_), do: 80
    end
    """

    if File.exists?(file_path) and File.read!(file_path) == content do
      false
    else
      File.write!(file_path, content)
      Mix.shell().info("Patched #{file_path} (environment proxy support)")
      true
    end
  end

  defp dep_path(candidates) do
    candidates
    |> Enum.find(fn {_dep_name, path} -> File.dir?(Path.expand(path)) end)
    |> case do
      nil -> List.last(candidates)
      candidate -> candidate
    end
    |> then(fn {dep_name, path} -> {dep_name, Path.expand(path)} end)
  end

  defp recompile_dep(dep_name) do
    # Force recompilation by invoking Mix cmd
    System.cmd("mix", ["deps.compile", dep_name], into: IO.stream(:stdio, :line))
  end
end
