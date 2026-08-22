#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$project_root"
mkdir -p artifacts/story-1.4
temporary="$(mktemp /tmp/lectura-digital-metrics.XXXXXX)"
trap 'rm -f "$temporary"' EXIT

while IFS=$'\t' read -r document_id language relative_pdf; do
  result="$(
    LECTURA_MACOS_WORKER="$project_root/target/lectura-macos-worker" \
      "$project_root/target/debug/lectura" pdf process \
      --input "$project_root/tests/corpus/$relative_pdf" \
      --language "$language" --unit paragraph --json
  )"
  jq -c --arg document_id "$document_id" \
    '{document_id: $document_id, numerator: .result.nfr6.numerator, denominator: .result.nfr6.denominator, ratio: .result.nfr6.ratio, threshold: .result.nfr6.threshold, passed: .result.nfr6.passed}' \
    <<<"$result" >>"$temporary"
done < <(
  jq -r '.entries[] | select(.classification.content == "digital") | [.id, .language, .file] | @tsv' \
    tests/corpus/manifest.json
)

jq -e -s 'length > 0 and all(.passed == true)' "$temporary" >/dev/null
mv "$temporary" artifacts/story-1.4/digital-metrics.jsonl
trap - EXIT
echo "STORY_1_4_DIGITAL_CORPUS PASS"
