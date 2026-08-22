#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe="/tmp/lectura-document-extraction-probe"
mkdir -p /tmp/lectura-swift-module-cache

xcrun swiftc \
  -parse-as-library \
  -module-cache-path /tmp/lectura-swift-module-cache \
  -framework PDFKit \
  -o "$probe" \
  "$project_root/apps/macos/MacPlatform/Document/DocumentServices.swift" \
  "$project_root/apps/macos/MacPlatform/Document/PDFGlyphReplay.swift" \
  "$project_root/apps/macos/MacPlatform/Files/FileServices.swift" \
  "$project_root/tests/integration/DocumentExtractionProbe.swift"
"$probe"
