defmodule Sigma.Agent.ProtocolHostedResults do
  @moduledoc """
  Reads complete durable hosted-result sources from one selected journal capture.

  Runtime registry ownership selects the live Writer. A stopped-session caller
  supplies the trusted storage path; journal header IDs do not identify Runtime
  sessions. Source discovery follows raw ancestry, independently of display tails,
  compaction and provider context windows. Reading never replays tool effects.
  """

  alias Sigma.Agent.Runtime

  @hosted_key "openai_responses_hosted"

  def load(repo_path, runtime_session_id, storage_path) do
    repo_path = Path.expand(repo_path)
    writer = Runtime.lookup(repo_path, runtime_session_id, :writer)

    with :ok <- require_writer_for_live_agent(repo_path, runtime_session_id, writer),
         {:ok, entries, selector, diagnostics} <- capture(writer, storage_path),
         {:ok, result} <- selected(entries, selector, diagnostics, repo_path, runtime_session_id),
         true <- Runtime.lookup(repo_path, runtime_session_id, :writer) == writer,
         :ok <- require_writer_for_live_agent(repo_path, runtime_session_id, writer) do
      {:ok, result}
    else
      false -> {:error, :session_unavailable}
      {:error, _reason} = error -> error
    end
  catch
    :exit, _reason -> {:error, :session_unavailable}
  end

  defp require_writer_for_live_agent(repo_path, session_id, nil) do
    if is_pid(Runtime.lookup(repo_path, session_id, :agent)),
      do: {:error, :session_unavailable},
      else: :ok
  end

  defp require_writer_for_live_agent(_repo_path, _session_id, _writer), do: :ok

  defp capture(nil, storage_path) do
    with {:ok, entries, diagnostics} <-
           apply(Sigma.Session.Storage.JsonlFile, :read_with_diagnostics, [storage_path]) do
      {:ok, entries, :latest, diagnostics}
    end
  end

  defp capture(writer, _storage_path) do
    with {:ok, %{entries: entries, leaf_id: leaf_id}} <-
           apply(Sigma.Session.Writer, :selected_journal, [writer]) do
      {:ok, entries, leaf_id, []}
    end
  end

  defp selected(entries, selector, diagnostics, repo_path, session_id) do
    index = apply(Sigma.Session.Journal.Index, :build, [entries])

    with {:ok, {leaf_id, nodes}} <-
           apply(Sigma.Session.Journal.Index, :path, [index, selector]),
         {:ok, snapshot} <-
           apply(Sigma.Session.Journal, :replay, [
             entries,
             [
               leaf_id: leaf_id,
               hook_session_id: session_id,
               finalize_metrics: false,
               diagnostics: diagnostics
             ]
           ]),
         :ok <- validate_diagnostics(snapshot.diagnostics),
         {:ok, results} <- sources(nodes) do
      {:ok,
       %{
         snapshot: snapshot,
         view: %{
           repo_path: repo_path,
           session_id: session_id,
           leaf_id: snapshot.active_leaf_id,
           results: results
         }
       }}
    end
  end

  defp validate_diagnostics(diagnostics) do
    # Match Writer's read admission while retaining every diagnostic in snapshot.
    blocking =
      Enum.reject(diagnostics, fn
        %{kind: :invalid_payload} -> true
        %{kind: :invalid_header, reason: :missing_header} -> true
        %{kind: :message_repair} -> true
        _diagnostic -> false
      end)

    if blocking == [], do: :ok, else: {:error, {:invalid_journal, blocking}}
  end

  defp sources(nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn %{entry: entry}, {:ok, results} ->
      if hosted_entry?(entry) do
        case apply(Sigma.Session.EntryDecoder, :message, [entry]) do
          {:ok, message} ->
            {:cont, {:ok, [%{entry_id: entry["id"], message: message} | results]}}

          {:error, _reason} ->
            {:halt, {:error, :provider_hosted_payload_rejected}}
        end
      else
        {:cont, {:ok, results}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _reason} = error -> error
    end
  end

  defp hosted_entry?(%{"type" => "message", "message" => %{"metadata" => metadata}})
       when is_map(metadata),
       do: Map.has_key?(metadata, @hosted_key)

  defp hosted_entry?(_entry), do: false
end
