#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Volumes/Extreme SSD/Xcode-26.2.0.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Volumes/Extreme SSD/Xcode-26.2.0.app/Contents/Developer"
fi

if [[ -x "$project_root/.cache/rust/cargo/bin/cargo" ]]; then
  export CARGO_HOME="$project_root/.cache/rust/cargo"
  export RUSTUP_HOME="$project_root/.cache/rust/rustup"
  export PATH="$CARGO_HOME/bin:$PATH"
fi

fail() {
  printf 'bootstrap: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "falta '$1': $2"
}

[[ "$(uname -s)" == "Darwin" ]] || fail "se requiere macOS 15 o posterior"
[[ "$(uname -m)" == "arm64" ]] || fail "se requiere Apple Silicon arm64"

for required_file in \
  Cargo.toml \
  Cargo.lock \
  rust-toolchain.toml \
  package.json \
  package-lock.json \
  contracts/lf-v1/fixtures/canary-request.json \
  contracts/lf-v1/fixtures/canary-completed.json \
  contracts/lf-v1/fixtures/canary-error.json; do
  [[ -f "$required_file" ]] || fail "falta el archivo requerido '$required_file'"
done

macos_version="$(sw_vers -productVersion)"
(( ${macos_version%%.*} >= 15 )) || fail "se requiere macOS 15 o posterior; observado ${macos_version}"

require_command rustc "instale Rust 1.97.1 mediante rustup"
require_command cargo "instale Rust 1.97.1 mediante rustup"
require_command node "instale Node 24.14.1"
require_command npm "instale npm 11.16.0"
require_command xcodebuild "instale Xcode 26.2 completo"
require_command xcrun "instale Xcode 26.2 completo"
require_command swift "instale Xcode 26.2 completo"

rust_version="$(rustc --version)"
cargo_version="$(cargo --version)"
node_version="$(node --version)"
npm_version="$(npm --version)"
xcode_version="$(xcodebuild -version 2>&1)" || fail "seleccione Xcode 26.2 completo con DEVELOPER_DIR o xcode-select"
sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>&1)" || fail "no se pudo consultar el SDK de macOS"
swift_version="$(swift --version 2>&1 | head -n 1)"

[[ "${rust_version}" == rustc\ 1.97.1* ]] || fail "se requiere rustc 1.97.1; observado ${rust_version}"
[[ "${cargo_version}" == cargo\ 1.97.1* ]] || fail "se requiere cargo 1.97.1; observado ${cargo_version}"
[[ "${node_version}" == "v24.14.1" ]] || fail "se requiere Node v24.14.1; observado ${node_version}"
[[ "${npm_version}" == "11.16.0" ]] || fail "se requiere npm 11.16.0; observado ${npm_version}"
[[ "${xcode_version}" == Xcode\ 26.2$'\n'* ]] || fail "se requiere Xcode 26.2; observado ${xcode_version//$'\n'/, }"
[[ "${sdk_version}" == "26.2" ]] || fail "se requiere SDK 26.2; observado ${sdk_version}"
[[ "${swift_version}" == *"Apple Swift version 6.2.3"* ]] || fail "se requiere Swift 6.2.3; observado ${swift_version}"

printf '%s\n' \
  "Lectura Fluida bootstrap OK" \
  "macOS=${macos_version}" \
  "architecture=arm64" \
  "${xcode_version//$'\n'/; }" \
  "SDK=${sdk_version}" \
  "${swift_version}" \
  "${rust_version}" \
  "${cargo_version}" \
  "Node=${node_version}" \
  "npm=${npm_version}"
