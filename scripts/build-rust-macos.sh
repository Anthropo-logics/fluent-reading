#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_file_dir="${DERIVED_FILE_DIR:?build-rust-macos: DERIVED_FILE_DIR es obligatorio}"

if [[ -x "$project_root/.cache/rust/cargo/bin/cargo" ]]; then
  export CARGO_HOME="$project_root/.cache/rust/cargo"
  export RUSTUP_HOME="$project_root/.cache/rust/rustup"
  export PATH="$CARGO_HOME/bin:$PATH"
fi

case "${CONFIGURATION:-Debug}" in
  Debug)
    cargo_profile="debug"
    ;;
  Release)
    cargo_profile="release"
    ;;
  *)
    printf 'build-rust-macos: configuración no admitida: %s\n' "$CONFIGURATION" >&2
    exit 64
    ;;
esac

target_dir="$derived_file_dir/rust"
(
  cd "$project_root"
  if [[ "$cargo_profile" == "release" ]]; then
    CARGO_TARGET_DIR="$target_dir" cargo build --locked -p lectura-ffi --release
  else
    CARGO_TARGET_DIR="$target_dir" cargo build --locked -p lectura-ffi
  fi
)

library="$target_dir/$cargo_profile/liblectura_ffi.a"
[[ -f "$library" ]] || {
  printf 'build-rust-macos: Cargo no produjo %s\n' "$library" >&2
  exit 1
}

printf '%s\n' "$library"
