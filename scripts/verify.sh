#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Volumes/Extreme SSD/Xcode-26.2.0.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Volumes/Extreme SSD/Xcode-26.2.0.app/Contents/Developer"
fi

if [[ -z "${LECTURA_DERIVED_DATA:-}" && -d "/Volumes/Extreme SSD" ]]; then
  LECTURA_DERIVED_DATA="/Volumes/Extreme SSD/LecturaFluida-DerivedData"
fi
xcode_derived_data_args=()
if [[ -n "${LECTURA_DERIVED_DATA:-}" ]]; then
  xcode_derived_data_args=(-derivedDataPath "$LECTURA_DERIVED_DATA")
fi

if [[ -x "$project_root/.cache/rust/cargo/bin/cargo" ]]; then
  export CARGO_HOME="$project_root/.cache/rust/cargo"
  export RUSTUP_HOME="$project_root/.cache/rust/rustup"
  export PATH="$CARGO_HOME/bin:$PATH"
fi

usage() {
  printf 'usage: verify.sh <lint|typecheck|test|build|all|gate-a>\n' >&2
  exit 64
}

value_or_unavailable() {
  "$@" 2>/dev/null || printf 'unavailable\n'
}

first_line() {
  sed -n '1p'
}

record_environment() {
  local gate="$1"
  local rust cargo xcode sdk swift macos architecture
  rust="$(value_or_unavailable rustc --version | first_line)"
  cargo="$(value_or_unavailable cargo --version | first_line)"
  xcode="$(value_or_unavailable xcodebuild -version | first_line)"
  sdk="$(value_or_unavailable xcrun --sdk macosx --show-sdk-version | first_line)"
  swift="$(value_or_unavailable swift --version | first_line)"
  macos="$(value_or_unavailable sw_vers -productVersion | first_line)"
  architecture="$(value_or_unavailable uname -m | first_line)"
  mkdir -p artifacts/validation
  node - "$gate" "$rust" "$cargo" "$xcode" "$sdk" "$swift" "$macos" "$architecture" \
    >artifacts/validation/environment.json <<'NODE'
const [gate, rust, cargo, xcode, sdk, swift, macos, architecture] = process.argv.slice(2);
process.stdout.write(`${JSON.stringify({
  gate,
  rust,
  cargo,
  xcode,
  sdk,
  swift,
  macos,
  architecture,
}, null, 2)}\n`);
NODE
}

require_xcode() {
  ./scripts/bootstrap.sh >/dev/null || {
    printf 'verify: Xcode 26.2 completo es obligatorio para este gate\n' >&2
    return 1
  }
}

xcode_build() {
  local configuration="$1"
  xcodebuild \
    -project apps/macos/LecturaFluida.xcodeproj \
    -scheme LecturaFluida \
    "${xcode_derived_data_args[@]+"${xcode_derived_data_args[@]}"}" \
    -configuration "$configuration" \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    build
}

run_lint() {
  cargo fmt --all -- --check
  find contracts/lf-v1 apps/macos -type f \( -name '*.json' -o -name '*.xcstrings' -o -name '*.xctestplan' \) \
    -exec jq -e . {} + >/dev/null
  bash -n scripts/bootstrap.sh scripts/build-rust-macos.sh scripts/embed-layout-model.sh \
    scripts/embed-runtimes.sh scripts/verify.sh tests/integration/ToolingProbe.sh
  swift format lint --recursive --strict apps/macos tests/integration
}

run_typecheck() {
  cargo check --workspace --all-targets --locked
  cargo clippy --workspace --all-targets --locked -- -D warnings
  require_xcode
  xcode_build Debug
}

run_test() {
  node --test tests/tts/*.test.mjs
  ./scripts/build-macos-worker.sh target/lectura-macos-worker
  ./scripts/test-document-extraction.sh
  cargo test --workspace --locked
  tests/integration/DigitalCorpusProcess.sh
  tests/integration/OCRCorpusProcess.sh
  tests/integration/OfflinePDFProcess.sh
  require_xcode
  xcodebuild test \
    -project apps/macos/LecturaFluida.xcodeproj \
    -scheme LecturaFluida \
    -testPlan CI-Fast \
    "${xcode_derived_data_args[@]+"${xcode_derived_data_args[@]}"}" \
    -destination 'platform=macOS,arch=arm64' \
    -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=- \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
}

run_build() {
  cargo build --workspace --release --locked
  require_xcode
  xcode_build Release
}

run_gate_a() {
  local evidence="${LECTURA_GATE_A_EVIDENCE_DIR:?verify: set LECTURA_GATE_A_EVIDENCE_DIR to a completed external Gate A run}"
  node scripts/verify-gate-a-evidence.mjs --directory "$evidence"
  cargo test --locked -p lectura-core --test gate_a_contract
  cargo test --locked -p lectura-cli --test gate_a_cli
  cargo test --locked -p lectura-ffi --test ffi_canary
  node --test tests/integration/*.test.mjs
}

[[ $# -eq 1 ]] || usage
gate="$1"
case "$gate" in
  lint | typecheck | test | build | all | gate-a) ;;
  *) usage ;;
esac

record_environment "$gate"

case "$gate" in
  lint) run_lint ;;
  typecheck) run_typecheck ;;
  test) run_test ;;
  build) run_build ;;
  gate-a) run_gate_a ;;
  all)
    run_lint
    run_typecheck
    run_test
    run_build
    ;;
esac
