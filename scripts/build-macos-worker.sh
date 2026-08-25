#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:-$project_root/target/lectura-macos-worker}"
mkdir -p "$(dirname "$output")" /tmp/lectura-swift-module-cache

xcrun swiftc \
  -O \
  -parse-as-library \
  -module-cache-path /tmp/lectura-swift-module-cache \
  -framework AVFoundation \
  -framework PDFKit \
  -o "$output" \
  "$project_root/apps/macos/MacPlatform/Document/DocumentLayoutServices.swift" \
  "$project_root/apps/macos/MacPlatform/Document/DocumentServices.swift" \
  "$project_root/apps/macos/MacPlatform/Document/PDFGlyphReplay.swift" \
  "$project_root/apps/macos/MacPlatform/Files/FileServices.swift" \
  "$project_root/apps/macos/MacPlatform/Models/ModelServices.swift" \
  "$project_root/apps/macos/MacPlatform/Translation/TranslationServices.swift" \
  "$project_root/apps/macos/LecturaMacWorker/main.swift"
