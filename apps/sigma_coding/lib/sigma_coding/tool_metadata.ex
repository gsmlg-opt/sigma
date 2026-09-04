defmodule Sigma.Coding.ToolMetadata do
  @moduledoc """
  Scheduling, effect, approval, and rendering metadata for one tool call.
  """

  alias Sigma.Coding.MCP.Tool, as: MCPTool
  alias Sigma.Coding.Utils.PathUtils

  @type effect :: :read | :write | :process | :network | :destructive
  @type concurrency :: :shared | :sequential | :exclusive

  @enforce_keys [:effect, :concurrency]
  defstruct [
    :effect,
    :concurrency,
    :render_hint,
    interruptible: false,
    default_deadline_ms: 30_000,
    approval_tier: :standard,
    discoverable: true,
    resource_keys: []
  ]

  @type t :: %__MODULE__{
          effect: effect(),
          concurrency: concurrency(),
          interruptible: boolean(),
          default_deadline_ms: pos_integer() | :infinity,
          approval_tier: atom(),
          discoverable: boolean(),
          render_hint: atom() | nil,
          resource_keys: [String.t()]
        }

  def resolve(tool, tool_call, opts) do
    explicit = explicit_metadata(tool)
    defaults = defaults(tool, Sigma.Coding.Tool.name(tool))
    metadata = Map.merge(defaults, explicit)
    resource_keys = resource_keys(metadata, tool_call.arguments, opts)

    struct!(__MODULE__, Map.put(metadata, :resource_keys, resource_keys))
  end

  defp explicit_metadata(tool) when is_atom(tool) do
    if function_exported?(tool, :metadata, 0), do: Map.new(tool.metadata()), else: %{}
  end

  defp explicit_metadata(_tool), do: %{}

  defp defaults(%MCPTool{}, _name) do
    %{
      effect: :network,
      concurrency: :sequential,
      interruptible: true,
      default_deadline_ms: 60_000,
      approval_tier: :guarded,
      discoverable: true,
      render_hint: :structured
    }
  end

  defp defaults(_tool, name) when name in ["read", "search", "find", "grep", "glob", "ls"] do
    %{
      effect: :read,
      concurrency: :shared,
      interruptible: true,
      default_deadline_ms: 30_000,
      approval_tier: :standard,
      discoverable: true,
      render_hint: :text
    }
  end

  defp defaults(_tool, name) when name in ["write", "edit"] do
    %{
      effect: :write,
      concurrency: :sequential,
      interruptible: false,
      default_deadline_ms: 30_000,
      approval_tier: :guarded,
      discoverable: true,
      render_hint: :diff
    }
  end

  defp defaults(_tool, "bash") do
    %{
      effect: :process,
      concurrency: :exclusive,
      interruptible: true,
      default_deadline_ms: 120_000,
      approval_tier: :guarded,
      discoverable: true,
      render_hint: :terminal
    }
  end

  defp defaults(_tool, name) when name in ["ask", "AskUserQuestion"] do
    %{
      effect: :process,
      concurrency: :sequential,
      interruptible: true,
      default_deadline_ms: 300_000,
      approval_tier: :standard,
      discoverable: true,
      render_hint: :question
    }
  end

  defp defaults(_tool, "todo") do
    %{
      effect: :write,
      concurrency: :sequential,
      interruptible: true,
      default_deadline_ms: 5_000,
      approval_tier: :standard,
      discoverable: true,
      render_hint: :structured
    }
  end

  defp defaults(_tool, "url_fetch") do
    %{
      effect: :network,
      concurrency: :shared,
      interruptible: true,
      default_deadline_ms: 30_000,
      approval_tier: :guarded,
      discoverable: true,
      render_hint: :text
    }
  end

  defp defaults(_tool, _name) do
    %{
      effect: :process,
      concurrency: :sequential,
      interruptible: true,
      default_deadline_ms: 30_000,
      approval_tier: :guarded,
      discoverable: true,
      render_hint: :structured
    }
  end

  defp resource_keys(%{resource_keys: keys}, _arguments, _opts) when is_list(keys) and keys != [],
    do: Enum.map(keys, &to_string/1)

  defp resource_keys(metadata, arguments, opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    keys =
      arguments
      |> candidate_paths()
      |> Enum.map(&PathUtils.canonical_resource_key(&1, cwd))
      |> Enum.flat_map(fn
        {:ok, path} -> ["path:" <> path]
        {:error, _reason} -> []
      end)
      |> Enum.uniq()

    if keys == [] and metadata.effect in [:write, :destructive] do
      ["effect:#{metadata.effect}"]
    else
      keys
    end
  end

  defp candidate_paths(arguments) when is_map(arguments) do
    direct =
      [arguments["path"], arguments["file_path"]]
      |> Enum.filter(&is_binary/1)

    edit_paths =
      case arguments["input"] || arguments["_input"] do
        input when is_binary(input) ->
          Regex.scan(~r/^\[([^\]#]+)#[^\]]+\]/m, input, capture: :all_but_first)
          |> List.flatten()

        _input ->
          []
      end

    direct ++ edit_paths
  end

  defp candidate_paths(_arguments), do: []
end
