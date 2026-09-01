defmodule Sigma.Session.Operations do
  @moduledoc """
  Read-only session artifacts and bounded session summaries.

  Dump and export capture the accepted source length before reading. Listing
  reads only a bounded prefix and tail from every journal.
  """

  alias Sigma.Session.Journal
  alias Sigma.Session.Journal.Index

  @default_read_budget 65_536
  @known_entry_types ~w(message model_change thinking_level_change service_tier_change mcp_server_selection_change mode_change compaction branch_summary)

  def dump(source_path, output_path, opts \\ []) do
    with {:ok, accepted} <- accepted_journal(source_path, opts),
         {:ok, encoded} <- Jason.encode(dump_document(accepted), pretty: true),
         :ok <- publish(output_path, encoded <> "\n", opts) do
      {:ok, output_path}
    end
  end

  def export(source_path, output_path, opts \\ []) do
    with {:ok, accepted} <- accepted_journal(source_path, opts),
         :ok <- publish(output_path, render_markdown(accepted.snapshot), opts) do
      {:ok, output_path}
    end
  end

  def list_summaries(dir, opts \\ []) do
    if File.dir?(dir) do
      budget = Keyword.get(opts, :read_budget, @default_read_budget)

      if is_integer(budget) and budget > 0 and budget <= @default_read_budget do
        summaries =
          dir
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
          |> Enum.map(&summary(Path.join(dir, &1), Path.rootname(&1), budget, opts))
          |> Enum.sort_by(& &1.updated_at_unix, :desc)

        {:ok, summaries}
      else
        {:error, :invalid_read_budget}
      end
    else
      {:ok, []}
    end
  end

  defp accepted_journal(source_path, opts) do
    with {:ok, stat} <- File.stat(source_path),
         :ok <- run_after_capture(opts, source_path, stat.size),
         {:ok, bytes} <- read_range(opts, source_path, 0, stat.size),
         true <- byte_size(bytes) == stat.size,
         {entries, storage_diagnostics} <- decode_lines(bytes),
         {:ok, snapshot} <- Journal.replay(entries, diagnostics: storage_diagnostics) do
      index = Index.build(entries)

      {:ok,
       %{
         accepted_length: stat.size,
         entries: entries,
         index: index,
         snapshot: snapshot
       }}
    else
      false -> {:error, :short_read}
      {:error, _reason} = error -> error
    end
  end

  defp run_after_capture(opts, source_path, accepted_length) do
    case Keyword.get(opts, :after_capture) do
      nil -> :ok
      callback when is_function(callback, 2) -> callback.(source_path, accepted_length)
      _callback -> {:error, :invalid_after_capture_callback}
    end
  end

  defp dump_document(accepted) do
    valid_entries = Enum.map(accepted.index.ordered, & &1.entry)

    %{
      "format" => "sigma.session.dump",
      "version" => 1,
      "acceptedLength" => accepted.accepted_length,
      "header" => accepted.index.header,
      "entries" => valid_entries,
      "activeLeafId" => accepted.snapshot.active_leaf_id,
      "branchEntryIds" => accepted.snapshot.branch_entry_ids,
      "diagnostics" => accepted.snapshot.diagnostics,
      "unknownEntries" =>
        Enum.reject(valid_entries, &(&1["type"] in @known_entry_types))
    }
  end

  defp render_markdown(snapshot) do
    settings = [
      {"Working directory", snapshot.cwd},
      {"Provider", snapshot.provider_id},
      {"Model", snapshot.model_id},
      {"Reasoning level", snapshot.reasoning_level},
      {"Service tier", render_setting(snapshot.service_tier)},
      {"MCP servers", Enum.join(snapshot.mcp_server_ids, ", ")},
      {"Mode", snapshot.mode}
    ]

    settings_text =
      settings
      |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
      |> Enum.map_join("\n", fn {label, value} -> "- **#{label}:** #{value}" end)

    transcript =
      snapshot.messages
      |> Enum.map_join("\n\n", &render_message/1)

    """
    # Sigma session #{snapshot.session_id || "unknown"}

    #{settings_text}

    ## Transcript

    #{transcript}
    """
  end

  defp render_setting(nil), do: nil
  defp render_setting(value) when is_binary(value), do: value
  defp render_setting(value), do: Jason.encode!(value)

  defp render_message(message) do
    heading =
      case message.role do
        :user -> "User"
        :assistant -> "Assistant"
        :tool_result -> "Tool result: #{message.tool_name || "unknown"}"
        :compaction_summary -> "Compaction summary"
        role -> role |> to_string() |> String.capitalize()
      end

    "### #{heading}\n\n#{render_content(message.content)}"
  end

  defp render_content(content) when is_binary(content), do: content

  defp render_content(content) when is_list(content) do
    Enum.map_join(content, "\n\n", fn
      %{type: :text, text: text} -> text
      %{type: :thinking, thinking: thinking} -> "> Thinking: #{thinking}"
      %{type: :tool_call, name: name, arguments: arguments} ->
        "Tool call `#{name}`\n\n```json\n#{Jason.encode!(arguments, pretty: true)}\n```"

      %{type: :image, mime_type: mime_type} -> "[Image: #{mime_type}]"
      part -> "```text\n#{inspect(part, limit: 50)}\n```"
    end)
  end

  defp render_content(nil), do: ""
  defp render_content(content), do: inspect(content, limit: 50)

  defp summary(path, session_id, budget, opts) do
    {:ok, stat} = File.stat(path)
    {chunks, partial?} = bounded_chunks(path, stat.size, budget, opts)
    {entries, diagnostics} = decode_summary_chunks(chunks)
    header = entries |> Enum.reverse() |> Enum.find(&(&1["type"] == "session"))
    metadata = bounded_metadata(Path.rootname(path) <> ".meta.json", budget, opts)
    latest_model = latest_entry(entries, "model_change")
    latest_user = latest_user_entry(entries)
    cwd = metadata["cwd"] || (header && header["cwd"])

    %{
      session_id: session_id,
      title: metadata["title"] || session_id,
      cwd: cwd,
      cwd_missing?: is_binary(cwd) and not File.dir?(cwd),
      updated_at: stat.mtime |> mtime_to_iso8601(),
      updated_at_unix: mtime_to_unix(stat.mtime),
      provider_id: model_part(latest_model, 0) || metadata["provider_id"],
      model_id: model_part(latest_model, 1) || metadata["model_id"],
      latest_user_preview: latest_user_preview(latest_user),
      diagnostic_state: if(diagnostics == [] and not partial?, do: :ok, else: :warning),
      diagnostics: diagnostics,
      partial?: partial?
    }
  end

  defp bounded_chunks(path, size, budget, opts) when size <= budget * 2 do
    case read_range(opts, path, 0, size) do
      {:ok, bytes} -> {[{:whole, bytes}], false}
      {:error, reason} -> {[{:error, reason}], true}
    end
  end

  defp bounded_chunks(path, size, budget, opts) do
    prefix = read_range(opts, path, 0, budget)
    tail_offset = size - budget
    tail = read_range(opts, path, tail_offset, budget)

    chunks =
      for {kind, result} <- [prefix: prefix, tail: tail] do
        case result do
          {:ok, bytes} -> {kind, bytes}
          {:error, reason} -> {:error, reason}
        end
      end

    {chunks, true}
  end

  defp decode_summary_chunks(chunks) do
    Enum.reduce(chunks, {[], []}, fn
      {:error, reason}, {entries, diagnostics} ->
        {entries, diagnostics ++ [%{kind: :read_error, reason: reason}]}

      {kind, bytes}, {entries, diagnostics} ->
        bytes = normalize_summary_chunk(kind, bytes)
        {decoded, chunk_diagnostics} = decode_lines(bytes)
        {entries ++ decoded, diagnostics ++ chunk_diagnostics}
    end)
  end

  defp normalize_summary_chunk(:whole, bytes), do: bytes

  defp normalize_summary_chunk(:prefix, bytes) do
    if String.ends_with?(bytes, "\n") do
      bytes
    else
      bytes |> :binary.split("\n", [:global]) |> Enum.drop(-1) |> Enum.join("\n")
    end
  end

  defp normalize_summary_chunk(:tail, bytes) do
    bytes
    |> :binary.split("\n", [:global])
    |> Enum.drop(1)
    |> Enum.join("\n")
  end

  defp bounded_metadata(path, budget, opts) do
    case File.stat(path) do
      {:ok, stat} ->
        length = min(stat.size, budget)

        with {:ok, bytes} <- read_range(opts, path, 0, length),
             {:ok, metadata} when is_map(metadata) <- Jason.decode(bytes) do
          metadata
        else
          _error -> %{}
        end

      {:error, _reason} ->
        %{}
    end
  end

  defp latest_entry(entries, type) do
    entries |> Enum.reverse() |> Enum.find(&(&1["type"] == type))
  end

  defp latest_user_entry(entries) do
    Enum.find(Enum.reverse(entries), fn
      %{"type" => "message", "message" => %{"role" => role}} -> role in ["user", :user]
      _entry -> false
    end)
  end

  defp model_part(%{"model" => model}, index) when is_binary(model) do
    model |> String.split("/", parts: 2) |> Enum.at(index)
  end

  defp model_part(_entry, _index), do: nil

  defp latest_user_preview(%{"message" => %{"content" => content}}) do
    content
    |> preview_text()
    |> String.trim()
    |> String.slice(0, 160)
    |> empty_to_nil()
  end

  defp latest_user_preview(_entry), do: nil

  defp preview_text(content) when is_binary(content), do: content

  defp preview_text(content) when is_list(content) do
    Enum.map_join(content, " ", fn
      %{"type" => "text", "text" => text} -> text
      %{type: :text, text: text} -> text
      _part -> ""
    end)
  end

  defp preview_text(_content), do: ""
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp mtime_to_iso8601(mtime) do
    mtime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end

  defp mtime_to_unix(mtime) do
    mtime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
  end

  defp decode_lines(bytes) do
    lines = :binary.split(bytes, "\n", [:global])
    last_index = length(lines) - 1
    terminated? = String.ends_with?(bytes, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {line, line_number}, {entries, diagnostics} ->
      line = String.trim(line)

      cond do
        line == "" ->
          {entries, diagnostics}

        true ->
          case Jason.decode(line) do
            {:ok, entry} ->
              {entries ++ [entry], diagnostics}

            {:error, _reason} ->
              kind =
                if line_number - 1 == last_index and not terminated?,
                  do: :trailing_incomplete_json,
                  else: :invalid_json

              {entries, diagnostics ++ [%{kind: kind, line: line_number}]}
          end
      end
    end)
  end

  defp read_range(opts, path, offset, length) do
    reader = Keyword.get(opts, :range_reader, &default_read_range/3)
    reader.(path, offset, length)
  end

  defp default_read_range(_path, _offset, 0), do: {:ok, ""}

  defp default_read_range(path, offset, length) do
    case File.open(path, [:read, :binary], fn io -> :file.pread(io, offset, length) end) do
      {:ok, {:ok, bytes}} -> {:ok, bytes}
      {:ok, :eof} -> {:ok, ""}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish(output_path, content, opts) do
    replace? = Keyword.get(opts, :replace, false)
    temp_path = temp_path(output_path)

    with :ok <- ensure_output_available(output_path, replace?),
         :ok <- File.write(temp_path, content),
         :ok <- publish_temp(temp_path, output_path, replace?) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(temp_path)
        error
    end
  end

  defp ensure_output_available(_path, true), do: :ok

  defp ensure_output_available(path, false) do
    if File.exists?(path), do: {:error, :already_exists}, else: :ok
  end

  defp publish_temp(temp_path, output_path, true), do: File.rename(temp_path, output_path)

  defp publish_temp(temp_path, output_path, false) do
    case File.ln(temp_path, output_path) do
      :ok -> File.rm(temp_path)
      {:error, :eexist} -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp temp_path(output_path) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(Path.dirname(output_path), ".#{Path.basename(output_path)}.#{suffix}.tmp")
  end
end
