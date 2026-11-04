defmodule Sigma.Agent.Backplane.MessageBoardStore do
  @moduledoc """
  Application-owned durable writer for one root transcript's message board.

  The trusted host supplies the absolute root transcript and its immutable JSONL
  header ID. Root and child callers share one writer in this BEAM. Each operation
  reads `<root_transcript>.subagents/message_board.json` afresh; opening and reads
  of an absent board create no files. No board contents are cached in the process.

  Changed states use Store.FileSystem's synced temporary file and atomic rename.
  There is no distributed exclusion or parent-directory fsync guarantee. A failed
  write acknowledgement preserves its original cause as `unknown_outcome`, even
  when the rename actually committed. The host never retries a write or sends a
  notification. Returned notification intents follow a confirmed commit only;
  accepted-call retries recover the durable result without returning intents.

  Repository file operations retire the writer before moving or removing its
  subtree. Retirement drains accepted calls and confirms normal process exit;
  the durable board can be reopened after a failed file operation. A normally
  retired writer is not restarted at its previous transcript path.

  MessageBoardResources registers this storage with the actual collaboration tree
  and dispatches its transient intents through public active-turn notifications.
  """

  use GenServer, restart: :transient

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.MessageBoardState, as: Board
  alias Sigma.Agent.Backplane.Store.FileSystem

  def start_link(opts) do
    with {:ok, root} <- root_transcript(opts),
         {:ok, root_id} <- root_id(opts),
         {:ok, filesystem} <- filesystem(opts) do
      GenServer.start_link(__MODULE__, {root, root_id, filesystem}, name: via(root))
    end
  end

  @doc "Obtains the shared writer without creating storage."
  def open(opts) do
    case DynamicSupervisor.start_child(Sigma.Agent.DynamicSupervisor, {__MODULE__, opts}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        with {:ok, root_id} <- root_id(opts),
             :ok <- GenServer.call(pid, {:root_id, root_id}) do
          {:ok, pid}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc "Applies a board operation using trusted host metadata, returning committed intents."
  def execute(pid, operation, host), do: GenServer.call(pid, {:execute, operation, host})

  @doc "Drains and retires the writer for a trusted transcript before a file operation."
  def retire(path) do
    with {:ok, root} <- root_transcript(root_transcript: path) do
      case Registry.lookup(Sigma.Agent.RepositoryRegistry, {:message_board_store, root}) do
        [] -> :ok
        [{pid, _}] -> retire_writer(pid)
      end
    end
  end

  defp retire_writer(pid) do
    monitor = Process.monitor(pid)

    result =
      try do
        GenServer.call(pid, :retire, :infinity)
      catch
        :exit, reason -> {:exit, reason}
      end

    receive do
      {:DOWN, ^monitor, :process, ^pid, reason} ->
        case {result, reason} do
          {:ok, :normal} -> :ok
          {{:exit, {:normal, _call}}, :normal} -> :ok
          {{:exit, {:noproc, _call}}, :noproc} -> :ok
          {{:exit, cause}, _reason} -> retirement_error(cause)
          {_reply, cause} -> retirement_error(cause)
        end
    end
  end

  defp retirement_error(cause),
    do: error(:unknown_outcome, "message-board writer retirement is unconfirmed", cause)

  @impl true
  def init({root, root_id, filesystem}) do
    {:ok,
     %{
       path: Path.join(root <> ".subagents", "message_board.json"),
       root_id: root_id,
       filesystem: filesystem
     }}
  end

  @impl true
  def handle_call(:retire, _from, state), do: {:stop, :normal, :ok, state}

  def handle_call({:root_id, root_id}, _from, state) do
    result =
      if root_id == state.root_id,
        do: :ok,
        else: error(:resource_conflict, "message-board writer has a different root ID")

    {:reply, result, state}
  end

  def handle_call({:execute, operation, host}, _from, state) do
    result =
      with {:ok, current} <- load(state),
           {:ok, result, next, intents} <- Board.apply(current, operation, host),
           :ok <- persist_changed(state, current, next) do
        {:ok, result, intents}
      end

    {:reply, result, state}
  end

  defp load(state) do
    case fs(state.filesystem, :read, [state.path]) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, board} ->
            if stored_board?(board, state.root_id),
              do: {:ok, board},
              else: error(:malformed_result, "message-board store has an invalid shape")

          {:error, reason} ->
            error(:malformed_result, "message-board store is malformed", reason)
        end

      {:error, :enoent} ->
        {:ok, Board.new(state.root_id)}

      {:error, reason} ->
        error(:execution_failure, "message-board store read failed", reason)
    end
  end

  defp persist_changed(_state, current, current), do: :ok

  defp persist_changed(state, _current, next) do
    with {:ok, bytes} <- Jason.encode(next),
         :ok <- fs(state.filesystem, :ensure_dir, [Path.dirname(state.path)]) do
      case fs(state.filesystem, :write_atomic, [state.path, bytes]) do
        :ok -> :ok
        {:error, reason} -> error(:unknown_outcome, "message-board write is unconfirmed", reason)
      end
    else
      {:error, reason} ->
        error(:execution_failure, "message-board store preparation failed", reason)
    end
  end

  defp stored_board?(
         %{
           "version" => 1,
           "root_id" => root_id,
           "deleted" => deleted,
           "channels" => channels,
           "posts" => posts,
           "subscriptions" => subscriptions,
           "accepted_calls" => receipts,
           "next_sequence" => sequence
         },
         root_id
       )
       when is_boolean(deleted) and is_map(channels) and is_map(posts) and
              is_map(subscriptions) and is_map(receipts) and is_integer(sequence) and sequence > 0 do
    Enum.all?(channels, &stored_channel?/1) and Enum.all?(posts, &stored_post?/1) and
      Enum.all?(subscriptions, fn {_target, agents} ->
        is_map(agents) and Enum.all?(agents, fn {_id, enabled} -> is_boolean(enabled) end)
      end) and
      Enum.all?(receipts, fn {_key, receipt} ->
        match?(
          %{"input" => %{"name" => name, "arguments" => args}, "result" => result}
          when is_binary(name) and is_map(args) and is_map(result),
          receipt
        )
      end)
  end

  defp stored_board?(_board, _root_id), do: false

  defp stored_channel?(
         {name,
          %{
            "channel_name" => name,
            "created_at" => created,
            "created_by" => author,
            "timestamp" => timestamp
          }}
       ),
       do: is_binary(created) and is_binary(author) and is_integer(timestamp)

  defp stored_channel?(_entry), do: false

  defp stored_post?(
         {id,
          %{
            "metadata" => %{
              "message_id" => id,
              "channel_name" => channel,
              "author" => author,
              "thread_id" => thread,
              "created_at" => created
            },
            "text" => text,
            "timestamp" => timestamp,
            "sequence" => sequence
          }}
       ),
       do:
         is_binary(channel) and is_binary(author) and is_binary(thread) and
           is_binary(created) and is_binary(text) and is_integer(timestamp) and
           is_integer(sequence) and sequence > 0

  defp stored_post?(_entry), do: false

  defp root_transcript(opts) do
    case Keyword.get(opts, :root_transcript) do
      path when is_binary(path) and path != "" ->
        if Path.type(path) == :absolute,
          do: {:ok, Path.expand(path)},
          else: error(:validation, "message board requires an absolute root transcript")

      _ ->
        error(:validation, "message board requires an absolute root transcript")
    end
  end

  defp root_id(opts) do
    case Keyword.get(opts, :root_id) do
      id when is_binary(id) and byte_size(id) > 0 -> {:ok, id}
      _ -> error(:validation, "message board requires the root JSONL header ID")
    end
  end

  defp filesystem(opts) do
    case Keyword.get(opts, :filesystem, {FileSystem, nil}) do
      {module, context} when is_atom(module) -> {:ok, {module, context}}
      _ -> error(:validation, "invalid message-board filesystem")
    end
  end

  defp fs({module, context}, function, args), do: apply(module, function, [context | args])

  defp via(root),
    do: {:via, Registry, {Sigma.Agent.RepositoryRegistry, {:message_board_store, root}}}

  defp error(class, message, cause \\ nil), do: {:error, Error.new(class, message, cause: cause)}
end
