defmodule Sigma.Agent.Backplane.McpResources do
  @moduledoc """
  Native MCP resource operations over the Agent's existing connected clients.

  The trusted descriptor supplies a live client getter; this module does not
  create connections or retain a second connection registry. All-server lists
  collect bounded pages and return the pinned Codex server-tagged flat payload.

  Resource calls use the public DynamicRuntime scope in the actual effect caller.
  Sequential pages and servers share its deadline and exact retirement inventory;
  each starter preserves the reserved MCP Client options. Cancellation retires
  only those requests, while the shared connections remain borrowed. Confirmed
  local cleanup does not claim remote rollback or cancellation delivery.

  Events returns one raw server page through the public event-request lifecycle.
  The Client owns MRTR continuation and its wire identities; the caller retains
  the public retirement evidence without automatically following page cursors.
  """

  require Logger

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Codex.DynamicRuntime
  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.MCP.Error, as: McpError
  alias Backplane.McpProtocol.MCP.Response

  @max_pages 100
  @max_items 2_048
  @max_cursor_bytes 64 * 1_024

  def list_resources(arguments, operation),
    do: list(arguments, operation, :list_resources, "resources")

  def list_resource_templates(arguments, operation),
    do: list(arguments, operation, :list_resource_templates, "resourceTemplates")

  @doc "Reads one raw Events page; the cursor belongs to the configured server."
  def list_events(arguments, operation) do
    with {:ok, clients} <- clients(operation),
         {:ok, server} <- required(arguments["server"], "server"),
         {:ok, client} <- client(clients, server) do
      result =
        DynamicRuntime.event_request(operation, fn reserved ->
          Client.start_list_events(client, Keyword.merge([cursor: arguments["cursor"]], reserved))
        end)

      case result do
        {:ok, %Response{} = response} ->
          cond do
            Response.error?(response) ->
              {:error,
               Error.new(:execution_failure, "MCP Events failed for '#{server}'",
                 details: %{"server" => server, "mcp_result" => response.result},
                 cause: response.result
               )}

            is_map(response.result) ->
              {:ok, response.result}

            true ->
              malformed("MCP Events server '#{server}' returned an invalid page")
          end

        {:error, %Error{}} = error ->
          error

        {:error, %McpError{} = cause} ->
          {:error,
           Error.new(:execution_failure, "MCP Events failed for '#{server}': #{cause.message}",
             details: %{
               "server" => server,
               "mcp_error" => %{
                 "code" => cause.code,
                 "message" => cause.message,
                 "data" => cause.data
               }
             },
             cause: cause
           )}

        {:error, cause} ->
          {:error,
           Error.new(:execution_failure, "MCP Events failed for '#{server}'", cause: cause)}
      end
    end
  catch
    :exit, cause ->
      {:error, Error.new(:execution_failure, "MCP Events request failed", cause: cause)}
  end

  def read_resource(arguments, operation) do
    with {:ok, clients} <- clients(operation),
         {:ok, server} <- required(arguments["server"], "server"),
         {:ok, uri} <- required(arguments["uri"], "uri"),
         {:ok, client} <- client(clients, server) do
      DynamicRuntime.resource_request_scope(operation, fn scope ->
        with {:ok, result} <- request(scope, client, :read_resource, [uri], server),
             true <-
               is_list(result["contents"]) or malformed("MCP resource contents must be a list") do
          {:ok, result |> Map.put("server", server) |> Map.put("uri", uri)}
        end
      end)
    end
  end

  defp list(arguments, operation, method, key) do
    server = optional(arguments["server"])
    cursor = optional(arguments["cursor"])

    with {:ok, clients} <- clients(operation) do
      cond do
        is_nil(server) and not is_nil(cursor) ->
          {:error, Error.new(:validation, "cursor can only be used when a server is specified")}

        server ->
          with {:ok, client} <- client(clients, server),
               :ok <- cursor(cursor, MapSet.new()) do
            DynamicRuntime.resource_request_scope(operation, fn scope ->
              with {:ok, result} <- request(scope, client, method, [cursor], server),
                   {:ok, entries} <- entries(result, key, server),
                   :ok <- cursor(result["nextCursor"], MapSet.new()) do
                payload = %{key => entries, "server" => server}

                payload =
                  if result["nextCursor"],
                    do: Map.put(payload, "nextCursor", result["nextCursor"]),
                    else: payload

                {:ok, payload}
              end
            end)
          end

        true ->
          DynamicRuntime.resource_request_scope(operation, &all_servers(&1, clients, method, key))
      end
    end
  end

  defp all_servers(scope, clients, method, key) do
    result =
      clients
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({:ok, []}, fn {server, client}, {:ok, items} ->
        case collect(scope, client, server, method, key, nil, [], MapSet.new(), 0) do
          {:ok, entries} when length(items) + length(entries) <= @max_items ->
            {:cont, {:ok, items ++ entries}}

          {:ok, _entries} ->
            {:halt,
             {:error, Error.new(:budget_exceeded, "MCP resource listing exceeded 2048 items")}}

          {:error, %Error{class: class}} = error
          when class in [:cancelled, :unknown_outcome, :budget_exceeded] ->
            {:halt, error}

          {:error, error} ->
            Logger.warning("MCP resource listing failed for #{server}: #{error.message}")
            {:cont, {:ok, items}}
        end
      end)

    with {:ok, items} <- result, do: {:ok, %{key => items}}
  end

  defp collect(_scope, _client, _server, _method, _key, _cursor, _items, _seen, @max_pages),
    do: {:error, Error.new(:budget_exceeded, "MCP resource listing exceeded 100 pages")}

  defp collect(scope, client, server, method, key, cursor, items, seen, pages) do
    with {:ok, result} <- request(scope, client, method, [cursor], server),
         {:ok, page} <- entries(result, key, server),
         true <-
           length(items) + length(page) <= @max_items or
             {:error, Error.new(:budget_exceeded, "MCP resource listing exceeded 2048 items")},
         :ok <- cursor(result["nextCursor"], seen) do
      items = items ++ page

      case result["nextCursor"] do
        nil ->
          {:ok, items}

        next ->
          collect(
            scope,
            client,
            server,
            method,
            key,
            next,
            items,
            MapSet.put(seen, next),
            pages + 1
          )
      end
    end
  end

  defp cursor(nil, _seen), do: :ok

  defp cursor(value, seen) when is_binary(value) do
    cond do
      byte_size(value) > @max_cursor_bytes ->
        malformed("MCP resource cursor exceeds 65536 bytes")

      MapSet.member?(seen, value) ->
        malformed("MCP resource listing returned a repeated pagination cursor")

      true ->
        :ok
    end
  end

  defp cursor(_value, _seen), do: malformed("MCP resource cursor must be a string")

  defp entries(result, key, server) do
    case result[key] do
      values when is_list(values) ->
        if Enum.all?(values, &is_map/1),
          do: {:ok, Enum.map(values, &Map.put(&1, "server", server))},
          else: malformed("MCP resource entries must be objects")

      _ ->
        malformed("MCP resource listing must contain #{key}")
    end
  end

  defp clients(%{backend_context: %{mcp_clients: getter}}) when is_function(getter, 0) do
    case getter.() do
      {:ok, clients} when is_map(clients) -> {:ok, clients}
      {:error, %Error{}} = error -> error
      _ -> {:error, Error.new(:validation, "MCP resource client getter returned invalid data")}
    end
  catch
    :exit, _ -> {:error, Error.new(:cancelled, "MCP resource session is no longer available")}
  end

  defp clients(_),
    do: {:error, Error.new(:validation, "MCP resources require a trusted client getter")}

  defp client(clients, server) do
    case Map.fetch(clients, server) do
      {:ok, client} -> {:ok, client}
      :error -> {:error, Error.new(:not_found, "unknown MCP server '#{server}'")}
    end
  end

  defp request(scope, client, method, arguments, server) do
    result =
      DynamicRuntime.resource_request(scope, fn opts ->
        case method do
          :read_resource ->
            Client.start_read_resource(client, hd(arguments), opts)

          :list_resources ->
            Client.start_list_resources(client, Keyword.put(opts, :cursor, hd(arguments)))

          :list_resource_templates ->
            Client.start_list_resource_templates(
              client,
              Keyword.put(opts, :cursor, hd(arguments))
            )
        end
      end)

    case result do
      {:ok, %Response{} = response} ->
        result = Response.get_result(response)

        if not Response.error?(response) and is_map(result),
          do: {:ok, result},
          else: malformed("MCP resource server '#{server}' returned an invalid result")

      {:error, %Error{}} = error ->
        error

      {:error, error} ->
        {:error,
         Error.new(:execution_failure, "MCP #{method} failed for '#{server}': #{error.message}")}
    end
  catch
    :exit, _ -> {:error, Error.new(:execution_failure, "MCP #{method} failed for '#{server}'")}
  end

  defp optional(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp optional(_value), do: nil

  defp required(value, field) do
    case optional(value) do
      nil -> {:error, Error.new(:validation, "#{field} must be provided")}
      value -> {:ok, value}
    end
  end

  defp malformed(message), do: {:error, Error.new(:malformed_result, message)}
end
