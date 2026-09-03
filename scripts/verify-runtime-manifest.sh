#!/bin/bash
set -euo pipefail

manifest="${1:?usage: verify-runtime-manifest.sh <manifest.json> <models-root> <espeak-root> <pcaudio-root> <stage-root>}"
models_root="${2:?usage: verify-runtime-manifest.sh <manifest.json> <models-root> <espeak-root> <pcaudio-root> <stage-root>}"
espeak_root="${3:?usage: verify-runtime-manifest.sh <manifest.json> <models-root> <espeak-root> <pcaudio-root> <stage-root>}"
pcaudio_root="${4:?usage: verify-runtime-manifest.sh <manifest.json> <models-root> <espeak-root> <pcaudio-root> <stage-root>}"
stage_root="${5:?usage: verify-runtime-manifest.sh <manifest.json> <models-root> <espeak-root> <pcaudio-root> <stage-root>}"

fail() {
  printf 'verify-runtime-manifest: %s\n' "$*" >&2
  exit 1
}

safe_relative_path() {
  local candidate="$1"
  [[ "$candidate" =~ ^[A-Za-z0-9._/-]+$ && "$candidate" != /* && "$candidate" != *//* ]] \
    || return 1
  local segment
  IFS='/' read -ra segments <<< "$candidate"
  for segment in "${segments[@]}"; do
    [[ -n "$segment" && "$segment" != "." && "$segment" != ".." ]] || return 1
  done
}

safe_tree_path() {
  local candidate="$1"
  [[ -n "$candidate" && "$candidate" != /* && "$candidate" != *//* \
    && "$candidate" != *$'\n'* && "$candidate" != *$'\t'* ]] || return 1
  local segment
  IFS='/' read -ra segments <<< "$candidate"
  for segment in "${segments[@]}"; do
    [[ -n "$segment" && "$segment" != "." && "$segment" != ".." ]] || return 1
  done
}

component_value() {
  local index="$1" key="$2"
  /usr/bin/plutil -extract "components.$index.$key" raw "$manifest" 2>/dev/null \
    || fail "missing components.$index.$key"
}

root_for() {
  case "$1" in
    models) printf '%s\n' "$models_root" ;;
    espeak) printf '%s\n' "$espeak_root" ;;
    pcaudio) printf '%s\n' "$pcaudio_root" ;;
    *) fail "invalid source_root: $1" ;;
  esac
}

tree_lines() {
  local root="$1" candidate relative size digest
  /usr/bin/find "$root" -type f -print | LC_ALL=C /usr/bin/sort | while IFS= read -r candidate; do
    relative="${candidate#"$root"/}"
    size="$(/usr/bin/stat -f '%z' "$candidate")"
    digest="$(/usr/bin/shasum -a 256 "$candidate" | /usr/bin/awk '{print $1}')"
    printf '%s\t%s\t%s\n' "$relative" "$size" "$digest"
  done
}

verify_component() {
  local candidate="$1" kind="$2" expected_count="$3" expected_size="$4" expected_hash="$5"
  local actual_count actual_size actual_hash relative
  if [[ "$kind" == "file" ]]; then
    [[ -f "$candidate" && ! -L "$candidate" ]] || fail "not a regular file: $candidate"
    actual_count=1
    actual_size="$(/usr/bin/stat -f '%z' "$candidate")"
    actual_hash="$(/usr/bin/shasum -a 256 "$candidate" | /usr/bin/awk '{print $1}')"
  else
    [[ -d "$candidate" && ! -L "$candidate" ]] || fail "not a regular tree: $candidate"
    [[ -z "$(/usr/bin/find "$candidate" -type l -print -quit)" ]] \
      || fail "symlinks are forbidden in $candidate"
    [[ -z "$(/usr/bin/find "$candidate" ! -type d ! -type f -print -quit)" ]] \
      || fail "non-regular entries are forbidden in $candidate"
    while IFS= read -r -d '' relative; do
      relative="${relative#"$candidate"/}"
      safe_tree_path "$relative" || fail "unsafe tree path: $relative"
    done < <(/usr/bin/find "$candidate" -type f -print0)
    actual_count="$(/usr/bin/find "$candidate" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    actual_size="$(tree_lines "$candidate" | /usr/bin/awk -F '\t' '{sum += $2} END {print sum + 0}')"
    actual_hash="$(tree_lines "$candidate" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  fi
  [[ "$actual_count" == "$expected_count" ]] || fail "file count mismatch: $candidate"
  [[ "$actual_size" == "$expected_size" ]] || fail "size mismatch: $candidate"
  [[ "$actual_hash" == "$expected_hash" ]] || fail "hash mismatch: $candidate"
}

[[ -f "$manifest" && ! -L "$manifest" ]] || fail "invalid manifest"
[[ -x /usr/bin/jq && -x /usr/bin/plutil && -x /usr/bin/shasum && -x /usr/bin/stat ]] \
  || fail "required system verification tools are absent"
component_total="$(/usr/bin/jq -er '
  if .schema_version == 1 and .id == "lectura-embedded-runtimes-v1"
    and (.components | type == "array") and (.components | length > 0)
  then .components | length else error("invalid manifest schema") end
' "$manifest" 2>/dev/null)" || fail "invalid manifest schema"
printf 'verify-runtime-manifest: tools=/usr/bin/jq,%s,%s,%s jq_version=%s\n' \
  '/usr/bin/plutil' '/usr/bin/stat' '/usr/bin/shasum' "$(/usr/bin/jq --version)"
for source_root in "$models_root" "$espeak_root" "$pcaudio_root"; do
  [[ -d "$source_root" ]] || fail "missing source root: $source_root"
done
[[ ! -e "$stage_root" ]] || fail "stage root already exists"

count=0
seen_ids='|'
seen_destinations='|'
while [[ "$count" -lt "$component_total" ]]; do
  id="$(component_value "$count" id)"
  kind="$(component_value "$count" kind)"
  source_name="$(component_value "$count" source_root)"
  relative_path="$(component_value "$count" relative_path)"
  bundled_path="$(component_value "$count" bundled_path)"
  origin_url="$(component_value "$count" origin_url)"
  revision="$(component_value "$count" revision)"
  expected_count="$(component_value "$count" file_count)"
  expected_size="$(component_value "$count" size_bytes)"
  expected_hash="$(component_value "$count" sha256_hex)"
  [[ "$id" =~ ^[a-z0-9][a-z0-9._-]+$ && "$seen_ids" != *"|$id|"* ]] \
    || fail "invalid or duplicate component id: $id"
  [[ "$kind" == "file" || "$kind" == "tree" ]] || fail "invalid kind for $id"
  safe_relative_path "$relative_path" || fail "unsafe relative_path for $id"
  safe_relative_path "$bundled_path" || fail "unsafe bundled_path for $id"
  [[ "$bundled_path" == Helpers/* || "$bundled_path" == Resources/* ]] \
    || fail "bundled_path outside Contents for $id"
  [[ "$seen_destinations" != *"|$bundled_path|"* ]] || fail "duplicate bundled_path: $bundled_path"
  [[ "$origin_url" == https://* && -n "$revision" ]] || fail "missing origin/revision for $id"
  [[ "$expected_count" =~ ^[1-9][0-9]*$ && "$expected_size" =~ ^[0-9]+$ ]] \
    || fail "invalid size metadata for $id"
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || fail "invalid SHA-256 for $id"
  source_root="$(root_for "$source_name")"
  source_candidate="$source_root/$relative_path"
  verify_component "$source_candidate" "$kind" "$expected_count" "$expected_size" "$expected_hash"
  printf 'verify-runtime-manifest: verified %s source=%s/%s origin=%s revision=%s bytes=%s sha256=%s\n' \
    "$id" "$source_name" "$relative_path" "$origin_url" "$revision" "$expected_size" "$expected_hash"
  seen_ids+="$id|"
  seen_destinations+="$bundled_path|"
  count=$((count + 1))
done
[[ "$count" == "$component_total" ]] || fail "component count mismatch"

working_stage="$(/usr/bin/mktemp -d "${stage_root}.tmp.XXXXXX")"
cleanup() { /bin/rm -rf -- "$working_stage"; }
trap cleanup EXIT
for ((index = 0; index < count; index++)); do
  kind="$(component_value "$index" kind)"
  source_name="$(component_value "$index" source_root)"
  relative_path="$(component_value "$index" relative_path)"
  bundled_path="$(component_value "$index" bundled_path)"
  expected_count="$(component_value "$index" file_count)"
  expected_size="$(component_value "$index" size_bytes)"
  expected_hash="$(component_value "$index" sha256_hex)"
  source_candidate="$(root_for "$source_name")/$relative_path"
  staged_candidate="$working_stage/$bundled_path"
  /bin/mkdir -p "$(/usr/bin/dirname "$staged_candidate")"
  if [[ "$kind" == "file" ]]; then
    /bin/cp -p "$source_candidate" "$staged_candidate"
  else
    /bin/mkdir -p "$staged_candidate"
    /bin/cp -R "$source_candidate/." "$staged_candidate/"
  fi
  verify_component "$staged_candidate" "$kind" "$expected_count" "$expected_size" "$expected_hash"
done
/bin/mv "$working_stage" "$stage_root"
trap - EXIT
printf 'verify-runtime-manifest: staged %s components\n' "$count"
