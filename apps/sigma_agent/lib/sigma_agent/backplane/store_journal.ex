defmodule Sigma.Agent.Backplane.StoreJournal do
  @moduledoc false

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.RecoveryJournal

  # Only this descriptor is embedded in the ordinary snapshot. Immutable blocks
  # are published first; the snapshot rename selects the authoritative head.
  def legacy(bytes, journal, snapshot) do
    %{version: :legacy, bytes: bytes, summary: RecoveryJournal.summary(journal, snapshot)}
  end

  def validate(%{version: 2} = descriptor, snapshot) do
    if valid_descriptor?(descriptor) and descriptor.revision == snapshot.revision and
         descriptor.incarnation == snapshot.incarnation,
       do: :ok,
       else: malformed()
  end

  def validate(_journal, _snapshot), do: :ok

  def append(nil, current, _next, _command, _path, _fs) when not is_nil(current),
    do: {:ok, nil}

  def append(nil, nil, _next, nil, _path, _fs), do: {:ok, nil}

  def append(journal, current, next, command, path, fs) do
    with {:ok, previous} <- previous(journal, current, path, fs),
         {:ok, entry} <- RecoveryJournal.entry(current, next, command),
         block = %{version: 1, run_id: next.run.run_id, previous: previous, entry: entry},
         {:ok, hash} <- publish(block, path, fs) do
      {:ok,
       %{
         version: 2,
         head: hash,
         revision: next.revision,
         incarnation: next.incarnation,
         genesis_incarnation:
           if(previous, do: previous.genesis_incarnation, else: next.incarnation)
       }}
    end
  end

  defp previous(nil, nil, _path, _fs), do: {:ok, nil}

  defp previous(%{version: :legacy, bytes: bytes, summary: summary}, current, path, fs) do
    with {:ok, metadata} <- summary,
         block = %{version: 1, run_id: current.run.run_id, legacy: bytes, metadata: metadata},
         {:ok, hash} <- publish(block, path, fs) do
      {:ok, Map.merge(metadata, %{version: 2, head: hash})}
    end
  end

  defp previous(%{version: 2} = descriptor, current, _path, _fs) do
    with :ok <- validate(descriptor, current), do: {:ok, descriptor}
  end

  defp previous(_journal, _current, _path, _fs), do: malformed()

  def read(nil, snapshot, _path, _fs), do: RecoveryJournal.read(nil, snapshot)

  def read(%{version: :legacy, bytes: bytes}, snapshot, _path, _fs) do
    with {:ok, raw} <- decode(bytes),
         do: RecoveryJournal.read(raw[:recovery_journal], snapshot)
  end

  def read(%{version: 2} = descriptor, snapshot, path, fs) do
    with :ok <- validate(descriptor, snapshot),
         {:ok, entries} <- collect(descriptor, snapshot.run.run_id, path, fs, []),
         do: RecoveryJournal.read(%{version: 1, entries: entries}, snapshot)
  end

  def read(_journal, _snapshot, _path, _fs), do: malformed()

  defp collect(descriptor, run_id, path, fs, suffix) do
    with true <- valid_descriptor?(descriptor),
         {:ok, bytes} <- read_block(path, descriptor.head, fs),
         true <- hash(bytes) == descriptor.head,
         {:ok, block} <- decode(bytes) do
      collect_block(block, descriptor, run_id, path, fs, suffix)
    else
      false -> malformed()
      error -> error
    end
  end

  defp collect_block(
         %{version: 1, run_id: run_id, legacy: bytes, metadata: metadata},
         descriptor,
         run_id,
         _path,
         _fs,
         suffix
       ) do
    with true <- Map.drop(descriptor, [:version, :head]) == metadata,
         {:ok, raw} <- decode(bytes),
         %{run: %{run_id: ^run_id}} <- raw,
         {:ok, ^metadata} <- RecoveryJournal.summary(raw[:recovery_journal], raw),
         %{version: 1, entries: entries} <- raw[:recovery_journal] do
      {:ok, entries ++ suffix}
    else
      _ -> malformed()
    end
  end

  defp collect_block(
         %{version: 1, run_id: run_id, previous: previous, entry: entry},
         descriptor,
         run_id,
         path,
         fs,
         suffix
       ) do
    if valid_entry?(entry, descriptor, previous) do
      if previous,
        do: collect(previous, run_id, path, fs, [entry | suffix]),
        else: {:ok, [entry | suffix]}
    else
      malformed()
    end
  end

  defp collect_block(_block, _descriptor, _run_id, _path, _fs, _suffix), do: malformed()

  defp valid_entry?(entry, descriptor, previous) when is_map(entry) do
    entry["revision"] == descriptor.revision and
      entry["incarnation"] == descriptor.incarnation and
      is_binary(entry["kind"]) and is_map(entry["input"]) and
      if previous do
        valid_descriptor?(previous) and
          entry["prior_revision"] == previous.revision and
          descriptor.revision == previous.revision + 1 and
          entry["prior_incarnation"] == previous.incarnation and
          descriptor.incarnation >= previous.incarnation and
          descriptor.genesis_incarnation == previous.genesis_incarnation
      else
        descriptor.revision == 1 and entry["prior_revision"] == 0 and
          entry["prior_incarnation"] == descriptor.incarnation and
          descriptor.genesis_incarnation == descriptor.incarnation
      end
  end

  defp valid_entry?(_entry, _descriptor, _previous), do: false

  defp valid_descriptor?(%{
         version: 2,
         head: head,
         revision: revision,
         incarnation: incarnation,
         genesis_incarnation: genesis
       }) do
    is_binary(head) and byte_size(head) == 64 and
      String.match?(head, ~r/\A[0-9a-f]{64}\z/) and is_integer(revision) and revision > 0 and
      is_integer(incarnation) and incarnation >= 0 and is_integer(genesis) and genesis >= 0
  end

  defp valid_descriptor?(_descriptor), do: false

  defp publish(block, path, fs) do
    bytes = encode(block)
    hash = hash(bytes)
    target = Path.join(path, hash)

    with :ok <- fs.(:ensure_dir, [path]) do
      case fs.(:read, [target]) do
        {:ok, ^bytes} ->
          {:ok, hash}

        {:ok, _other} ->
          malformed()

        {:error, :enoent} ->
          case fs.(:write_atomic, [target, bytes]) do
            :ok -> {:ok, hash}
            {:error, reason} -> storage_error("runtime journal commit failed", reason)
          end

        {:error, reason} ->
          storage_error("runtime journal read failed", reason)
      end
    else
      {:error, reason} -> storage_error("runtime journal directory failed", reason)
    end
  end

  defp read_block(path, hash, fs) do
    case fs.(:read, [Path.join(path, hash)]) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> storage_error("runtime journal read failed", reason)
    end
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  def encode(term) do
    if :erlang.external_size(term) >= 1024 * 1024 do
      term
      |> :erlang.term_to_iovec()
      |> :zstd.compress(%{compressionLevel: 1, windowLog: 24, checksumFlag: true})
      |> IO.iodata_to_binary()
    else
      :erlang.term_to_binary(term, compressed: 6)
    end
  end

  def decode(<<0x28, 0xB5, 0x2F, 0xFD, _::binary>> = frame) do
    frame |> :zstd.decompress() |> IO.iodata_to_binary() |> decode()
  rescue
    _error in [ErlangError, ArgumentError] -> malformed()
  end

  def decode(bytes) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      term when is_map(term) -> {:ok, term}
      _ -> malformed()
    end
  rescue
    ArgumentError -> malformed()
  end

  defp malformed,
    do: {:error, Error.new(:validation, "Runtime recovery journal is incomplete or invalid")}

  defp storage_error(message, reason),
    do: {:error, Error.new(:execution_failure, message, cause: reason)}
end
