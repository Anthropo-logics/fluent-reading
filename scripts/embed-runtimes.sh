#!/usr/bin/env bash
# Copies the local inference engines into the app bundle and re-signs them.
#
# The App Sandbox lets the app read an external models folder but never lets it execute binaries
# stored there, so a helper living outside the bundle is reported as non-executable and narration
# or translation can never start. Helpers must ship inside Contents/Helpers.
set -euo pipefail

app="${1:?usage: embed-runtimes.sh <path to LecturaFluida.app> [models root]}"
models_root="${2:-${LECTURA_MODEL_ROOT:-/Volumes/Extreme SSD/LecturaFluida-Models}}"
helpers="$app/Contents/Helpers"
mkdir -p "$helpers"

embed() {
  local source="$1" name="$2"
  if [[ ! -x "$source" ]]; then
    echo "embed-runtimes: skipping $name (not built at $source)" >&2
    return 0
  fi
  cp -f "$source" "$helpers/$name"
  chmod +x "$helpers/$name"
  # MLX resolves its Metal shader library (default.metallib) from resource bundles sitting next to
  # the executable. Copying the binary alone makes every run die with "Failed to load the default
  # metallib", so the sibling .bundle directories travel with it.
  local build_dir
  build_dir="$(dirname "$source")"
  shopt -s nullglob
  for resource in "$build_dir"/*.bundle; do
    rm -rf "$helpers/$(basename "$resource")"
    cp -R "$resource" "$helpers/"
    # Every nested bundle needs its own signature, otherwise sealing the app fails with
    # "code object is not signed at all" and macOS refuses to launch it.
    codesign --force --sign - --timestamp=none "$helpers/$(basename "$resource")" >/dev/null
    echo "embed-runtimes: embedded resource $(basename "$resource")"
  done
  shopt -u nullglob
  codesign --force --sign - --timestamp=none "$helpers/$name" >/dev/null
  echo "embed-runtimes: embedded $name"
}

embed \
  "$models_root/runtime/xcode-derived-mlx-audio-swift-v0.1.3/Build/Products/Release/mlx-audio-swift-tts" \
  "mlx-audio-swift-tts"
embed \
  "$models_root/runtime/xcode-derived-mlx-swift-lm-gemma3/Build/Products/Release/lectura-translate-runtime" \
  "lectura-translate-runtime"

embed_espeak() {
  local binary
  binary="$(command -v espeak-ng || true)"
  if [[ -z "$binary" ]]; then
    echo "embed-runtimes: skipping espeak-ng (not installed)" >&2
    return 0
  fi
  binary="$(python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$binary")"
  local prefix
  prefix="$(dirname "$(dirname "$binary")")"

  # Kokoro's built-in grapheme-to-phoneme conversion drops Spanish numerals and acronyms outright,
  # so narration must phonemise through eSpeak NG exactly like the validated harness does. The
  # engine therefore travels with the app, together with its dylibs and its 25 MB dictionary set.
  cp -f "$binary" "$helpers/espeak-ng"
  chmod +x "$helpers/espeak-ng"
  cp -f "$prefix/lib/libespeak-ng.1.dylib" "$helpers/"
  local pcaudio
  pcaudio="$(python3 -c "import os;print(os.path.realpath('/opt/homebrew/opt/pcaudiolib/lib/libpcaudio.0.dylib'))" 2>/dev/null || true)"
  [[ -f "$pcaudio" ]] && cp -f "$pcaudio" "$helpers/libpcaudio.0.dylib"

  # Homebrew paths do not exist on a user's machine; rewrite every install name to the bundle.
  install_name_tool -change "$prefix/lib/libespeak-ng.1.dylib" \
    "@executable_path/libespeak-ng.1.dylib" "$helpers/espeak-ng" 2>/dev/null || true
  install_name_tool -change "/opt/homebrew/opt/espeak-ng/lib/libespeak-ng.1.dylib" \
    "@executable_path/libespeak-ng.1.dylib" "$helpers/espeak-ng" 2>/dev/null || true
  install_name_tool -change "/opt/homebrew/opt/pcaudiolib/lib/libpcaudio.0.dylib" \
    "@executable_path/libpcaudio.0.dylib" "$helpers/espeak-ng" 2>/dev/null || true
  install_name_tool -id "@executable_path/libespeak-ng.1.dylib" \
    "$helpers/libespeak-ng.1.dylib" 2>/dev/null || true
  install_name_tool -change "/opt/homebrew/opt/pcaudiolib/lib/libpcaudio.0.dylib" \
    "@executable_path/libpcaudio.0.dylib" "$helpers/libespeak-ng.1.dylib" 2>/dev/null || true
  if [[ -f "$helpers/libpcaudio.0.dylib" ]]; then
    install_name_tool -id "@executable_path/libpcaudio.0.dylib" \
      "$helpers/libpcaudio.0.dylib" 2>/dev/null || true
    codesign --force --sign - --timestamp=none "$helpers/libpcaudio.0.dylib" >/dev/null
  fi

  # The dictionaries are data, so they belong in Resources. Inside Helpers macOS treats them as
  # unsigned code objects and refuses to seal the bundle.
  local resources="$app/Contents/Resources"
  mkdir -p "$resources"
  rm -rf "$resources/espeak-ng-data"
  cp -R "$prefix/share/espeak-ng-data" "$resources/espeak-ng-data"

  codesign --force --sign - --timestamp=none "$helpers/libespeak-ng.1.dylib" >/dev/null
  codesign --force --sign - --timestamp=none "$helpers/espeak-ng" >/dev/null
  echo "embed-runtimes: embedded espeak-ng $("$helpers/espeak-ng" --version 2>/dev/null | head -1 | awk '{print $4}')"
}

embed_espeak

# The bundle seal must be refreshed after adding helpers, or macOS rejects the modified app.
#
# This used to be `codesign --entitlements /dev/null ... || codesign --force --sign - "$app"`: the
# first form always fails (codesign rejects /dev/null as entitlement data, verified empirically —
# it is not a machine-specific fluke), so the `||` fallback ran on every single invocation and
# re-signed the bundle with no entitlements at all. Every app assembled by this script therefore ran
# without the App Sandbox, silently — `re-signed $app` printed as if it had worked. Sign with the
# real entitlements instead, and let a failure stop the script rather than hide it.
#
# `--options runtime` (Hardened Runtime) was tried here too, for future notarization, and reverted:
# a Debug build's own LecturaFluida.debug.dylib sits loose in Contents/MacOS, signed once by Xcode at
# build time with its own ad-hoc identity. Nothing short of re-signing every nested Mach-O with the
# exact same pass keeps Hardened Runtime's library validation happy about that dylib's identity not
# matching the app that loads it, and `--deep` does not reach a loose sibling file the way it reaches
# a real Frameworks/PlugIns bundle — verified: the app failed to launch outright ("different Team
# IDs") with --options runtime, deep or not, and launched fine without it. Ad-hoc signing has no real
# Team ID to match in the first place; Hardened Runtime here needs actual Developer ID signing, which
# this project does not yet have. The vulnerability this fixes is the sandbox being stripped, not the
# absence of Hardened Runtime — add --options runtime back once Developer ID signing exists.
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
codesign --force --sign - \
  --entitlements "$project_root/apps/macos/Config/LecturaFluida.entitlements" "$app" >/dev/null
echo "embed-runtimes: re-signed $app"
