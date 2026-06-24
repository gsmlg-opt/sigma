# Adds the local build target (x86_64-macos) to QuickBEAM's ZiglerPrecompiled
# target list so the NIF can be built from source on Intel macOS, where no
# precompiled artifact is published. Idempotent; safe to run repeatedly.
path = Path.expand("../deps/quickbeam/lib/quickbeam/native.ex", __DIR__)

unless File.exists?(path) do
  raise "QuickBEAM source not found at #{path}; run mix deps.get first"
end

source = File.read!(path)
target = "x86_64-macos-none"

cond do
  String.contains?(source, target) ->
    IO.puts("QuickBEAM already includes #{target}")

  true ->
    patched =
      String.replace(
        source,
        "targets: ~w(x86_64-linux-gnu aarch64-linux-gnu aarch64-macos-none)",
        "targets: ~w(x86_64-linux-gnu aarch64-linux-gnu aarch64-macos-none #{target})"
      )

    if patched == source do
      raise "Could not patch QuickBEAM target list in #{path}"
    end

    File.write!(path, patched)
    IO.puts("Patched QuickBEAM target list with #{target}")
end
