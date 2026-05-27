defmodule PiCoding.Hooks.Trust do
  @moduledoc """
  Trust gate for hook specs.

  A hook spec is trusted when its normalized definition hash (command, timeout,
  matcher, event, handler type) combined with its source path has been
  explicitly approved and recorded in the trust store.

  Changing any of those fields invalidates trust until re-approved (FR-D6).

  Trust is stored in `~/.pi/agent/hook_trust.json` as a map of
  `hash → %{approved_at, source_path}`.
  """

  alias PiCoding.Hooks.Spec
  alias PiCoding.Hooks.Spec.{Command, Http}

  @trust_file "hook_trust.json"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns true if the spec has been explicitly trusted.
  User-layer specs are always trusted. Project-layer specs require an entry
  in the trust store.
  """
  @spec trusted?(Spec.t()) :: boolean()
  def trusted?(%Spec{trusted?: true}), do: true

  def trusted?(%Spec{trusted?: false} = spec) do
    h = hash(spec)
    store = load_store()
    Map.has_key?(store, h)
  end

  def trusted?(_), do: false

  @doc """
  Record trust approval for a spec.
  """
  @spec approve!(Spec.t()) :: :ok
  def approve!(%Spec{} = spec) do
    h = hash(spec)
    {_origin_type, source_path} = spec.origin || {:user, ""}

    entry = %{
      "approved_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source_path" => to_string(source_path)
    }

    store = load_store()
    save_store(Map.put(store, h, entry))
    :ok
  end

  @doc """
  Revoke trust for a spec (e.g. after the command changed).
  """
  @spec revoke!(Spec.t()) :: :ok
  def revoke!(%Spec{} = spec) do
    h = hash(spec)
    store = load_store()
    save_store(Map.delete(store, h))
    :ok
  end

  @doc """
  Compute the normalized hash for a spec.

  The hash covers: event, matcher (as string), handler type, command/url,
  timeout_ms, and source path. Any of these changing invalidates trust.
  """
  @spec hash(Spec.t()) :: String.t()
  def hash(%Spec{} = spec) do
    {_origin_type, source_path} = spec.origin || {:user, ""}

    canonical = %{
      event: spec.event,
      matcher: matcher_to_string(spec.matcher),
      handler_type: handler_type_key(spec.handler),
      handler_cmd: handler_cmd(spec.handler),
      handler_timeout: handler_timeout(spec.handler),
      source_path: to_string(source_path)
    }

    canonical
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp matcher_to_string(:any), do: "*"
  defp matcher_to_string(s) when is_binary(s), do: s
  defp matcher_to_string(%Regex{source: src}), do: src
  defp matcher_to_string(nil), do: "*"

  defp handler_type_key(%Command{}), do: "command"
  defp handler_type_key(%Http{}), do: "http"
  defp handler_type_key({:unsupported, type}), do: "unsupported:#{type}"
  defp handler_type_key(nil), do: "none"

  defp handler_cmd(%Command{cmd: cmd}), do: cmd
  defp handler_cmd(%Http{url: url}), do: url
  defp handler_cmd(_), do: ""

  defp handler_timeout(%Command{timeout_ms: t}), do: t
  defp handler_timeout(%Http{timeout_ms: t}), do: t
  defp handler_timeout(_), do: 0

  defp trust_store_path do
    Path.join(agent_dir(), @trust_file)
  end

  defp agent_dir do
    Application.get_env(:ex_pi_session, :agent_dir) ||
      Path.join([System.user_home!(), ".pi", "agent"])
  end

  defp load_store do
    path = trust_store_path()

    with {:ok, bytes} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(bytes) do
      map
    else
      _ -> %{}
    end
  end

  defp save_store(store) do
    path = trust_store_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(store, pretty: true))
  end
end
