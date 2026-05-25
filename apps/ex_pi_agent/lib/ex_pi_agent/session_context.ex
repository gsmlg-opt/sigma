defmodule PiAgent.SessionContext do
  @moduledoc """
  Builds and injects per-session context into the LLM-facing message list.

  This module is a pure transformation boundary. It does not persist context
  and it does not own context discovery. Callers provide context from sources
  such as global AGENTS.md, repo AGENTS.md, skills, and hooks.
  """

  alias PiAgent.Message, as: AgentMessage

  @type injection_type :: :hooks | :skills | :agents_context | atom()

  @type injection :: %{
          required(:type) => injection_type(),
          required(:title) => String.t(),
          required(:content) => String.t(),
          optional(:source) => String.t()
        }

  @type t :: %__MODULE__{injections: [injection()]}

  defstruct injections: []

  @ordered_sources [:hooks, :skills, :agents_context]

  @titles %{
    skills: "Skills",
    hooks: "Hooks",
    agents_context: "agentsContext"
  }

  @agents_context_intro "Codebase and user instructions are shown below. Be sure to adhere to these instructions. IMPORTANT: These instructions OVERRIDE any default behavior and you MUST follow them exactly as written."

  @doc """
  Creates a session context from known context source buckets.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = normalize_agents_context(opts)

    context =
      Enum.reduce(@ordered_sources, %__MODULE__{}, fn source, acc ->
        append(acc, source, Keyword.get(opts, source))
      end)

    Enum.reduce(Keyword.get(opts, :injections, []), context, fn injection, acc ->
      append(acc, :custom, injection)
    end)
  end

  @doc """
  Appends one injection or a list of injections.
  """
  @spec append(t(), injection_type(), any(), keyword()) :: t()
  def append(context, type, content, opts \\ [])

  def append(%__MODULE__{} = context, _type, nil, _opts), do: context
  def append(%__MODULE__{} = context, _type, "", _opts), do: context

  def append(%__MODULE__{} = context, :skills, skills, opts) when is_list(skills) do
    append_injection(context, :skills, skills_context(skills), Map.new(opts))
  end

  def append(%__MODULE__{} = context, type, contents, opts) when is_list(contents) do
    Enum.reduce(contents, context, fn content, acc -> append(acc, type, content, opts) end)
  end

  def append(%__MODULE__{} = context, type, {title, content}, opts) when is_binary(title) do
    append(context, type, %{title: title, content: content}, opts)
  end

  def append(%__MODULE__{} = context, type, %{content: content} = injection, opts) do
    append_injection(context, type, content, Map.merge(Map.new(opts), injection))
  end

  def append(%__MODULE__{} = context, type, %{"content" => content} = injection, opts) do
    metadata =
      opts
      |> Map.new()
      |> maybe_put(:title, Map.get(injection, "title"))
      |> maybe_put(:source, Map.get(injection, "source"))

    append_injection(context, type, content, metadata)
  end

  def append(%__MODULE__{} = context, type, content, opts) when is_binary(content) do
    append_injection(context, type, content, Map.new(opts))
  end

  @doc """
  Renders skill metadata as the markdown list expected by the skills reminder.
  """
  @spec skills_context([map()]) :: String.t()
  def skills_context(skills) when is_list(skills) do
    skills
    |> Enum.reject(&Map.get(&1, :disable_model_invocation?, false))
    |> Enum.map(&skill_line/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @doc """
  Renders AGENTS.md-derived sources into one context block with current date.
  """
  @spec agents_context([any()], keyword()) :: String.t()
  def agents_context(sources, opts \\ []) when is_list(sources) do
    content =
      sources
      |> List.flatten()
      |> Enum.map(&agents_source_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    date_context = current_date_context(Keyword.get(opts, :current_date))

    [agents_context_body(content), date_context]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Returns true when no injectable context is present.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{injections: []}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Renders the context payload that will be wrapped in a system reminder.
  """
  @spec to_text(t()) :: String.t()
  def to_text(%__MODULE__{injections: injections}) do
    injections
    |> Enum.map(&format_injection/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Renders each injection as a separate LLM text block.
  """
  @spec to_blocks(t()) :: [map()]
  def to_blocks(%__MODULE__{injections: injections}) do
    injections
    |> Enum.map(&format_block/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Injects session context into the first user message as a system reminder.
  """
  @spec inject_messages([AgentMessage.t()], t()) :: [AgentMessage.t()]
  def inject_messages(messages, %__MODULE__{} = context) do
    case to_blocks(context) do
      [] -> messages
      blocks -> inject_blocks(messages, blocks)
    end
  end

  defp append_injection(%__MODULE__{} = context, _type, nil, _metadata), do: context
  defp append_injection(%__MODULE__{} = context, _type, "", _metadata), do: context

  defp append_injection(%__MODULE__{} = context, type, content, metadata)
       when is_binary(content) do
    injection =
      %{
        type: Map.get(metadata, :type, type),
        title: Map.get(metadata, :title, title_for(type)),
        content: content
      }
      |> maybe_put(:source, Map.get(metadata, :source))

    %{context | injections: context.injections ++ [injection]}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_agents_context(opts) do
    current_date = Keyword.get(opts, :current_date, Date.utc_today())

    agents_context =
      case Keyword.fetch(opts, :agents_context) do
        :error ->
          legacy_sources = legacy_agents_sources(opts)

          if agents_sources?(legacy_sources) do
            agents_context(legacy_sources, current_date: current_date)
          else
            ""
          end

        {:ok, sources} when is_list(sources) ->
          agents_context(sources, current_date: current_date)

        {:ok, context} ->
          context
      end

    if agents_context == "" do
      opts
    else
      Keyword.put(opts, :agents_context, agents_context)
    end
  end

  defp agents_sources?(sources) do
    sources
    |> List.flatten()
    |> Enum.any?(fn source -> agents_source_text(source) != "" end)
  end

  defp legacy_agents_sources(opts) do
    [
      Keyword.get(opts, :global_agents),
      Keyword.get(opts, :worktree),
      Keyword.get(opts, :repo_agents)
    ]
  end

  defp agents_context_body(""), do: ""

  defp agents_context_body(content) do
    "#{@agents_context_intro}\n\n#{content}"
  end

  defp agents_source_text(nil), do: ""
  defp agents_source_text(""), do: ""
  defp agents_source_text(content) when is_binary(content), do: content

  defp agents_source_text({title, content}) when is_binary(title) do
    case agents_source_text(content) do
      "" -> ""
      text -> "# #{title}\n\n#{text}"
    end
  end

  defp agents_source_text(%{content: content} = source) do
    format_agents_source(Map.get(source, :title), Map.get(source, :source), content)
  end

  defp agents_source_text(%{"content" => content} = source) do
    format_agents_source(Map.get(source, "title"), Map.get(source, "source"), content)
  end

  defp agents_source_text(_source), do: ""

  defp format_agents_source(title, source, content) do
    case agents_source_text(content) do
      "" -> ""
      text -> agents_source_header(title, source) <> text
    end
  end

  defp agents_source_header(nil, nil), do: ""
  defp agents_source_header("", nil), do: ""
  defp agents_source_header(nil, source), do: "Contents of #{source}:\n\n"
  defp agents_source_header("", source), do: "Contents of #{source}:\n\n"
  defp agents_source_header(title, nil), do: "# #{title}\n\n"
  defp agents_source_header(title, ""), do: "# #{title}\n\n"
  defp agents_source_header(title, source), do: "# #{title}: #{source}\n\n"

  defp current_date_context(nil), do: ""

  defp current_date_context(%Date{} = date) do
    current_date_context(Date.to_iso8601(date))
  end

  defp current_date_context(date) when is_binary(date) do
    """
    # currentDate
    Today's date is #{date}.
    """
    |> String.trim()
  end

  defp title_for(type),
    do: Map.get(@titles, type, type |> to_string() |> String.replace("_", " "))

  defp skill_line(%{name: name, description: description}) do
    "- #{name}: #{description}"
  end

  defp skill_line(%{"name" => name, "description" => description}) do
    "- #{name}: #{description}"
  end

  defp skill_line(_skill), do: ""

  defp format_block(%{type: :skills, content: content}) do
    %{type: :text, text: skills_reminder_text(content)}
  end

  defp format_block(injection) do
    case format_injection(injection) do
      "" -> nil
      text -> %{type: :text, text: reminder_text(text)}
    end
  end

  defp format_injection(%{title: title, content: content} = injection) do
    source = Map.get(injection, :source)
    header = if source, do: "# #{title}: #{source}", else: "# #{title}"
    "#{header}\n\n#{content}"
  end

  defp inject_blocks(messages, blocks) do
    {before_user, rest} = Enum.split_while(messages, fn msg -> msg.role != :user end)

    case rest do
      [] ->
        messages

      [user | after_user] ->
        before_user ++
          [
            %{user | content: prepend_blocks(user.content, blocks)}
            | after_user
          ]
    end
  end

  defp prepend_blocks(content, blocks) when is_binary(content) do
    blocks ++ [%{type: :text, text: content}]
  end

  defp prepend_blocks(content, blocks) when is_list(content) do
    blocks ++ content
  end

  defp prepend_blocks(nil, blocks), do: blocks

  defp reminder_text(context) do
    """
    <system-reminder>
    As you answer the user's questions, you can use the following context:
    #{context}
    </system-reminder>
    """
  end

  defp skills_reminder_text(skills_markdown) do
    """
    <system-reminder>
    The following skills are available for use with the Skill tool:

    #{skills_markdown}
    </system-reminder>
    """
  end
end
