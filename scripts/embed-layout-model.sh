#!/usr/bin/env bash
set -euo pipefail

source_model="${1:?usage: embed-layout-model.sh <model.mlmodelc> <app> <manifest.json>}"
app="${2:?usage: embed-layout-model.sh <model.mlmodelc> <app> <manifest.json>}"
manifest="${3:?usage: embed-layout-model.sh <model.mlmodelc> <app> <manifest.json>}"

fail() {
  printf 'embed-layout-model: %s\n' "$*" >&2
  exit 1
}

[[ -d "$source_model" && ! -L "$source_model" ]] || fail "invalid model source: $source_model"
[[ -f "$manifest" && ! -L "$manifest" ]] || fail "invalid manifest: $manifest"
jq -e '
  .schema_version == 1 and
  .id == "pp-doclayout-v3-coreml" and
  .bundled_directory == "PPDocLayoutV3-fp32.mlmodelc" and
  .license_text_path == "../licenses/PPDocLayoutV3-Apache-2.0.txt" and
  .license_text_resource == "PPDocLayoutV3-Apache-2.0.txt" and
  (.license_text_sha256 | type == "string") and
  (.license_text_sha256 | test("^[0-9a-f]{64}$")) and
  (.source_license_evidence_url | type == "string") and
  .source_notice_present == false and
  (.files | length == 4) and
  ([.files[].relative_path] | unique | length == 4) and
  all(.files[];
    (.relative_path | type == "string") and
    (.relative_path | test("^[A-Za-z0-9._/-]+$")) and
    (.relative_path | startswith("/") | not) and
    (.relative_path | split("/") | all(. != "" and . != "." and . != "..")) and
    (.size_bytes | type == "number") and
    (.size_bytes >= 0) and
    (.size_bytes == (.size_bytes | floor)) and
    (.sha256_hex | type == "string") and
    (.sha256_hex | test("^[0-9a-f]{64}$")))
' "$manifest" >/dev/null || fail "invalid manifest schema"

manifest_directory="$(cd "$(dirname "$manifest")" && pwd)"
license_source="$manifest_directory/$(jq -r '.license_text_path' "$manifest")"
license_resource="$(jq -r '.license_text_resource' "$manifest")"
license_hash="$(jq -r '.license_text_sha256' "$manifest")"
[[ -f "$license_source" && ! -L "$license_source" ]] || fail "invalid license source"
[[ "$(shasum -a 256 "$license_source" | awk '{print $1}')" == "$license_hash" ]] \
  || fail "license hash mismatch"

verify_tree() {
  local root="$1" actual_count=0 relative_path expected_size expected_hash actual_size actual_hash
  if [[ -n "$(find "$root" -type l -print -quit)" ]]; then
    fail "symlinks are forbidden in $root"
  fi
  if [[ -n "$(find "$root" ! -type d ! -type f -print -quit)" ]]; then
    fail "non-regular entries are forbidden in $root"
  fi
  while IFS= read -r -d '' _; do
    actual_count=$((actual_count + 1))
  done < <(find "$root" -type f -print0)
  [[ "$actual_count" -eq 4 ]] || fail "expected 4 files, found $actual_count"

  while IFS=$'\t' read -r relative_path expected_size expected_hash; do
    local candidate="$root/$relative_path"
    [[ -f "$candidate" && ! -L "$candidate" ]] || fail "missing regular file: $relative_path"
    actual_size="$(stat -f '%z' "$candidate")"
    [[ "$actual_size" == "$expected_size" ]] || fail "size mismatch: $relative_path"
    actual_hash="$(shasum -a 256 "$candidate" | awk '{print $1}')"
    [[ "$actual_hash" == "$expected_hash" ]] || fail "hash mismatch: $relative_path"
  done < <(jq -r '.files[] | [.relative_path, .size_bytes, .sha256_hex] | @tsv' "$manifest")
}

verify_tree "$source_model"

resources="$app/Contents/Resources"
mkdir -p "$resources"
stage_root="$(mktemp -d "$resources/.layout-model.tmp.XXXXXX")"
trap 'rm -rf -- "$stage_root"' EXIT
stage_model="$stage_root/PPDocLayoutV3-fp32.mlmodelc"
mkdir -p "$stage_model"
cp -R "$source_model/." "$stage_model/"
cp "$manifest" "$stage_root/pp-doclayout-v3-coreml.json"
cp "$license_source" "$stage_root/$license_resource"
verify_tree "$stage_model"
[[ "$(shasum -a 256 "$stage_root/$license_resource" | awk '{print $1}')" == "$license_hash" ]] \
  || fail "staged license hash mismatch"

target_model="$resources/PPDocLayoutV3-fp32.mlmodelc"
target_manifest="$resources/pp-doclayout-v3-coreml.json"
target_license="$resources/$license_resource"
rm -rf -- "$target_model"
rm -f -- "$target_manifest"
rm -f -- "$target_license"
mv "$stage_root/pp-doclayout-v3-coreml.json" "$target_manifest"
mv "$stage_root/$license_resource" "$target_license"
mv "$stage_model" "$target_model"
printf 'embed-layout-model: embedded PPDocLayoutV3-fp32.mlmodelc\n'
