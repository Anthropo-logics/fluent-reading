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
xcode_test_products_args=()
if [[ -n "${LECTURA_TEST_PRODUCTS_DIR:-}" ]]; then
  xcode_test_products_args=(CONFIGURATION_BUILD_DIR="$LECTURA_TEST_PRODUCTS_DIR")
fi

if [[ -x "$project_root/.cache/rust/cargo/bin/cargo" ]]; then
  export CARGO_HOME="$project_root/.cache/rust/cargo"
  export RUSTUP_HOME="$project_root/.cache/rust/rustup"
  export PATH="$CARGO_HOME/bin:$PATH"
fi

usage() {
  printf 'usage: verify.sh <lint|typecheck|test|build|all|gate-a|real-runtime|real-first-page>\n' >&2
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

xcode_test() {
  xcodebuild test \
    -project apps/macos/LecturaFluida.xcodeproj \
    -scheme LecturaFluida \
    -testPlan CI-Fast \
    "${xcode_derived_data_args[@]+"${xcode_derived_data_args[@]}"}" \
    -destination 'platform=macOS,arch=arm64' \
    -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=- \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    "${xcode_test_products_args[@]+"${xcode_test_products_args[@]}"}" \
    "$@"
}

require_artifact() {
  local path="$1"
  local label="$2"
  [[ -e "$path" ]] || {
    printf 'verify: falta %s: %s\n' "$label" "$path" >&2
    return 1
  }
}

require_executable() {
  local path="$1"
  local label="$2"
  [[ -x "$path" ]] || {
    printf 'verify: falta el ejecutable %s: %s\n' "$label" "$path" >&2
    return 1
  }
}

run_lint() {
  cargo fmt --all -- --check
  find contracts/lf-v1 apps/macos -type f \( -name '*.json' -o -name '*.xcstrings' -o -name '*.xctestplan' \) \
    -exec jq -e . {} + >/dev/null
  bash -n scripts/bootstrap.sh scripts/build-rust-macos.sh scripts/embed-layout-model.sh \
    scripts/embed-runtimes.sh scripts/sign-release-app.sh scripts/verify-notarized-app.sh \
    scripts/verify-runtime-manifest.sh scripts/verify.sh tests/integration/ToolingProbe.sh
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
  xcode_test -only-testing:LecturaMacTests
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

run_real_runtime() {
  local model_root="${LECTURA_MODEL_ROOT:?verify: set LECTURA_MODEL_ROOT}"
  local pdf="${LECTURA_REAL_PDF:?verify: set LECTURA_REAL_PDF}"
  require_artifact "$model_root/verified-packages/kokoro-82m-4bit/data" "Kokoro model data"
  require_executable \
    "$model_root/runtime/xcode-derived-mlx-audio-swift-v0.1.3/Build/Products/Release/mlx-audio-swift-tts" \
    "Kokoro release runtime"
  require_artifact "$pdf" "real PDF"
  require_executable /opt/homebrew/bin/espeak-ng "eSpeak NG"
  cargo build --workspace --release --locked
  ./scripts/build-macos-worker.sh target/lectura-macos-worker
  require_executable target/release/lectura "release lectura CLI"
  require_executable target/lectura-macos-worker "macOS worker"
  require_xcode
  xcode_test \
    LECTURA_REAL_RUNTIME_TEST=1 \
    "LECTURA_MODEL_ROOT=$model_root" \
    "LECTURA_REAL_PDF=$pdf" \
    -only-testing:LecturaMacTests/ModelServicesTests/testGateAHarnessUsesSessionHostPdfKitRustPlanAndRealKokoroRuntime \
    -only-testing:LecturaMacTests/ModelServicesTests/testGateAHarnessUsesVisionOCRAndRealKokoroRuntime \
    -only-testing:LecturaMacTests/ModelServicesTests/testNarratesTextExtractedFromRealBibliographyPDF
}

run_real_first_page() {
  local corpus="${LECTURA_REAL_PDF_CORPUS:?verify: set LECTURA_REAL_PDF_CORPUS}"
  [[ -d "$corpus" ]] || {
    printf 'verify: LECTURA_REAL_PDF_CORPUS no es un directorio: %s\n' "$corpus" >&2
    return 1
  }
  require_xcode
  xcode_test \
    LECTURA_FIRST_PAGE_PERFORMANCE_TEST=1 \
    "LECTURA_REAL_PDF_CORPUS=$corpus" \
    -only-testing:LecturaMacUITests/ReaderWindowUITests/testFirstPageColdAndHotBudgetOnReferenceMac
}

[[ $# -eq 1 ]] || usage
gate="$1"
case "$gate" in
  lint | typecheck | test | build | all | gate-a | real-runtime | real-first-page) ;;
  *) usage ;;
esac

record_environment "$gate"

case "$gate" in
  lint) run_lint ;;
  typecheck) run_typecheck ;;
  test) run_test ;;
  build) run_build ;;
  gate-a) run_gate_a ;;
  real-runtime) run_real_runtime ;;
  real-first-page) run_real_first_page ;;
  all)
    run_lint
    run_typecheck
    run_test
    run_build
    ;;
esac
