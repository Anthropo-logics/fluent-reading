#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cli="$root/target/debug/lectura"
worker="$root/target/lectura-macos-worker"

for language in es en pt; do
  for kind in single-scanned mixed; do
    pdf="$root/tests/corpus/documents/$language-$kind.pdf"
    result="$(LECTURA_MACOS_WORKER="$worker" "$cli" pdf process --input "$pdf" --language "$language" --unit paragraph --json)"
    if ! jq -e '
      .kind == "completed"
      and .result.pages[0].record.route == "ocr"
      and .result.nfr6.threshold == 0.95
      and .result.nfr6.passed == true
      and .result.cer.passed == true
    ' <<<"$result" >/dev/null; then
      jq -c --arg document "$language-$kind" '
        {document: $document, kind, routes: [.result.pages[].record.route], statuses: [.result.pages[].record.status], nfr6: .result.nfr6, cer: .result.cer}
      ' <<<"$result" >&2
      exit 1
    fi
  done
done

echo "STORY_1_5_OCR_CORPUS PASS documents=6"
