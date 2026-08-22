#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$project_root"

output="$({
  sandbox-exec -p '(version 1) (allow default) (deny network*)' \
    env LECTURA_MACOS_WORKER="$project_root/target/lectura-macos-worker" \
    "$project_root/target/debug/lectura" pdf process \
    --input "$project_root/tests/corpus/documents/en-single-digital.pdf" \
    --language en --unit paragraph --json
} 2>/dev/null)"

test "$(printf '%s\n' "$output" | jq -r '.kind')" = completed
test "$(printf '%s\n' "$output" | jq -r '.result.nfr6.passed')" = true
echo "STORY_1_4_OFFLINE_PDF PASS"
