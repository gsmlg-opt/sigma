#!/usr/bin/env bash

set -euo pipefail

service_dir="${1:-rel/service}"
required_files=(
  "com.gsmlg.sigma.plist"
  "sigma.service"
  "sigma-user-service"
  "README.md"
)

for file in "${required_files[@]}"; do
  if [[ ! -f "${service_dir}/${file}" ]]; then
    echo "missing release service file: ${service_dir}/${file}" >&2
    exit 1
  fi
done

if [[ ! -x "${service_dir}/sigma-user-service" ]]; then
  echo "release service launcher is not executable: ${service_dir}/sigma-user-service" >&2
  exit 1
fi

sh -n "${service_dir}/sigma-user-service"

grep -Fq '<string>com.gsmlg.sigma</string>' "${service_dir}/com.gsmlg.sigma.plist"
grep -Fq '@HOME@/.local/share/sigma/service/sigma-user-service' \
  "${service_dir}/com.gsmlg.sigma.plist"
grep -Fq 'ExecStart=%h/.local/share/sigma/service/sigma-user-service' \
  "${service_dir}/sigma.service"
grep -Fq 'WantedBy=default.target' "${service_dir}/sigma.service"
grep -Fq 'systemctl --user enable --now sigma.service' "${service_dir}/README.md"
grep -Fq 'launchctl bootstrap' "${service_dir}/README.md"

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "${service_dir}/com.gsmlg.sigma.plist"
fi

if command -v systemd-analyze >/dev/null 2>&1; then
  verify_home="$(mktemp -d)"
  trap 'rm -rf "$verify_home"' EXIT
  install -d "${verify_home}/.local/share/sigma/service"
  install -m 0755 \
    "${service_dir}/sigma-user-service" \
    "${verify_home}/.local/share/sigma/service/sigma-user-service"
  HOME="$verify_home" systemd-analyze --user verify "${service_dir}/sigma.service"
  rm -rf "$verify_home"
  trap - EXIT
fi
