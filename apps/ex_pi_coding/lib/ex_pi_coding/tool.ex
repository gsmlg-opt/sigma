defmodule PiCoding.Tool do
  @moduledoc """
  Defines the behaviour for tools in the Pi system.

  Tools are used by the agent to perform actions like executing commands,
  reading files, or searching the codebase.
  """

  @typedoc """
  The result of a tool execution.
  """
  @type result :: %{
          required(:content) => [PiAi.Message.text_content() | PiAi.Message.image_content()],
          required(:details) => any(),
          optional(:terminate) => boolean()
        }

  @typedoc """
  Options for tool execution.
  """
  @type opts :: [
          on_update: (result() -> :ok),
          signal: any(),
          cwd: String.t()
        ]

  @doc """
  Returns the machine-readable name of the tool.
  """
  @callback name() :: String.t()

  @doc """
  Returns a human-readable description of the tool's purpose.
  """
  @callback description() :: String.t()

  @doc """
  Returns a JSON schema (as a map) defining the tool's parameters.
  """
  @callback schema() :: map()

  @doc """
  Executes the tool with the given parameters and options.

  ## Parameters
  - `tool_call_id`: A unique identifier for the tool call.
  - `params`: A map of parameters matching the tool's schema.
  - `opts`: A keyword list of execution options.

  ## Returns
  - `{:ok, result}`: The tool executed successfully.
  - `{:error, reason}`: The tool execution failed.
  """
  @callback execute(tool_call_id :: String.t(), params :: map(), opts :: opts()) ::
              {:ok, result()} | {:error, any()}

  def name(tool) when is_atom(tool), do: tool.name()
  def name(%{name: name}), do: name

  def description(tool) when is_atom(tool), do: tool.description()
  def description(%{description: description}), do: description

  def schema(tool) when is_atom(tool), do: tool.schema()
  def schema(%{schema: schema}), do: schema

  def ai_definition(tool) do
    %{
      name: name(tool),
      description: description(tool),
      parameters: schema(tool)
    }
  end

  def execute(tool, tool_call_id, params, opts) when is_atom(tool) do
    tool.execute(tool_call_id, params, opts)
  end

  def execute(%PiCoding.MCP.Tool{} = tool, tool_call_id, params, opts) do
    PiCoding.MCP.call_tool(tool, tool_call_id, params, opts)
  end
end
