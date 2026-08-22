#!/usr/bin/env bash
set -euo pipefail

output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT

if ./scripts/verify.sh unknown >"$output_file" 2>&1; then
  printf 'verify.sh accepted an unknown gate\n' >&2
  exit 1
else
  status=$?
fi

[[ $status -eq 64 ]] || {
  printf 'expected exit 64, observed %s\n' "$status" >&2
  exit 1
}
grep -q 'usage: verify.sh' "$output_file"

bash -n scripts/bootstrap.sh scripts/build-rust-macos.sh scripts/verify.sh
