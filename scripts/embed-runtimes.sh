#!/bin/bash
# Copies the local inference engines into the app bundle and re-signs them.
#
# The App Sandbox lets the app read an external models folder but never lets it execute binaries
# stored there, so a helper living outside the bundle is reported as non-executable and narration
# or translation can never start. Helpers must ship inside Contents/Helpers.
set -euo pipefail

app="${1:?usage: embed-runtimes.sh <path to LecturaFluida.app> [models root]}"
models_root="${2:-${LECTURA_MODEL_ROOT:-/Volumes/Extreme SSD/LecturaFluida-Models}}"
project_root="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$project_root/models/manifests/embedded-runtimes-v1.json"
espeak_root="/opt/homebrew/Cellar/espeak-ng/1.52.0"
pcaudio_root="/opt/homebrew/Cellar/pcaudiolib/1.3"
helpers="$app/Contents/Helpers"
[[ -d "$app" && ! -L "$app" && -d "$app/Contents" ]] || {
  printf 'embed-runtimes: invalid app bundle\n' >&2
  exit 1
}
if [[ "${LECTURA_EMBED_OUTER_SIGNING:-script}" != "xcode" ]]; then
  "$project_root/scripts/sign-release-app.sh" "$app" preflight
fi

invalid_marker="$app/Contents/.lectura-release-invalid"
runtime_stage_root="$(/usr/bin/mktemp -d /private/tmp/lectura-runtime-stage.XXXXXX)"
cleanup() {
  status=$?
  /bin/rm -rf -- "$runtime_stage_root"
  if [[ "$status" -ne 0 && -d "$app/Contents" ]]; then
    printf 'Runtime embedding or final signature failed. Do not publish this candidate.\n' \
      > "$invalid_marker"
  fi
}
trap cleanup EXIT
printf 'Runtime verification in progress. Do not publish this candidate.\n' > "$invalid_marker"

"$project_root/scripts/verify-runtime-manifest.sh" \
  "$manifest" "$models_root" "$espeak_root" "$pcaudio_root" "$runtime_stage_root/payload"

index=0
while bundled_path="$(/usr/bin/plutil -extract "components.$index.bundled_path" raw "$manifest" 2>/dev/null)"; do
  /bin/rm -rf -- "$app/Contents/$bundled_path"
  index=$((index + 1))
done
/bin/mkdir -p "$helpers" "$app/Contents/Resources"
/bin/cp -R "$runtime_stage_root/payload/Helpers/." "$helpers/"
/bin/cp -R "$runtime_stage_root/payload/Resources/." "$app/Contents/Resources/"
/bin/cp "$manifest" "$app/Contents/Resources/embedded-runtimes-v1.json"
/bin/chmod +x "$helpers/mlx-audio-swift-tts" "$helpers/lectura-translate-runtime" \
  "$helpers/espeak-ng"

# Homebrew paths do not exist on a user's machine; rewrite every install name before signing.
/usr/bin/install_name_tool -change "$espeak_root/lib/libespeak-ng.1.dylib" \
  "@executable_path/libespeak-ng.1.dylib" "$helpers/espeak-ng"
/usr/bin/install_name_tool -change "/opt/homebrew/opt/pcaudiolib/lib/libpcaudio.0.dylib" \
  "@executable_path/libpcaudio.0.dylib" "$helpers/espeak-ng"
/usr/bin/install_name_tool -id "@executable_path/libespeak-ng.1.dylib" \
  "$helpers/libespeak-ng.1.dylib"
/usr/bin/install_name_tool -change "/opt/homebrew/opt/pcaudiolib/lib/libpcaudio.0.dylib" \
  "@executable_path/libpcaudio.0.dylib" "$helpers/libespeak-ng.1.dylib"
/usr/bin/install_name_tool -id "@executable_path/libpcaudio.0.dylib" \
  "$helpers/libpcaudio.0.dylib"

# Sign from the innermost code out; the final app gate validates the effective policy.
for nested in \
  "$helpers/libpcaudio.0.dylib" \
  "$helpers/libespeak-ng.1.dylib" \
  "$helpers"/*.bundle \
  "$helpers/espeak-ng" \
  "$helpers/mlx-audio-swift-tts" \
  "$helpers/lectura-translate-runtime"; do
  "$project_root/scripts/sign-release-app.sh" "$nested" nested
done
printf 'embed-runtimes: embedded 11 attested runtime components\n'

layout_default="/Volumes/Extreme SSD/Lectura-Fluida/research/ocr-benchmarks/coreml/PPDocLayoutV3-fp32.mlmodelc"
if [[ -n "${LECTURA_LAYOUT_MODEL_SOURCE+x}" ]]; then
  "$project_root/scripts/embed-layout-model.sh" \
    "$LECTURA_LAYOUT_MODEL_SOURCE" "$app" \
    "$project_root/models/manifests/pp-doclayout-v3-coreml.json"
elif [[ -d "$layout_default" ]]; then
  "$project_root/scripts/embed-layout-model.sh" \
    "$layout_default" "$app" "$project_root/models/manifests/pp-doclayout-v3-coreml.json"
else
  echo "embed-runtimes: skipping PPDocLayoutV3-fp32.mlmodelc (default model absent)" >&2
fi

/bin/rm -f -- "$invalid_marker"
if [[ "${LECTURA_EMBED_OUTER_SIGNING:-script}" == "xcode" ]]; then
  echo "embed-runtimes: verified nested code; outer app signing delegated to Xcode"
else
  "$project_root/scripts/sign-release-app.sh" "$app" app
  echo "embed-runtimes: verified and re-signed $app"
fi
