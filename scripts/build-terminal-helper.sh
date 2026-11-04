#!/usr/bin/env bash

set -euo pipefail

profile="${1:-release}"
manifest="native/sigma_terminal_helper/Cargo.toml"

case "$profile" in
  debug)
    cargo build --locked --manifest-path "$manifest"
    source_directory="native/sigma_terminal_helper/target/debug"
    ;;
  release)
    cargo build --locked --release --manifest-path "$manifest"
    source_directory="native/sigma_terminal_helper/target/release"
    ;;
  *)
    echo "usage: $0 [debug|release]" >&2
    exit 64
    ;;
esac

destination="${SIGMA_TERMINAL_HELPER_DESTINATION:-apps/sigma_agent/priv/native}"
install -d "$destination"
for binary in sigma-terminal-helper sigma-sandbox-launcher; do
  install -m 0755 "$source_directory/$binary" "$destination/$binary"
done
