#!/bin/bash
set -euo pipefail

target="${1:?usage: sign-release-app.sh <path> [app|nested|preflight]}"
scope="${2:-app}"
channel="${LECTURA_RELEASE_CHANNEL:?sign-release-app: set LECTURA_RELEASE_CHANNEL=adhoc|developer-id}"
project_root="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && pwd)"
entitlements="$project_root/apps/macos/Config/LecturaFluida.entitlements"

fail() {
  printf 'sign-release-app: %s\n' "$*" >&2
  exit 1
}

[[ "$scope" == "app" || "$scope" == "nested" || "$scope" == "preflight" ]] \
  || fail "invalid scope: $scope"
[[ -e "$target" && ! -L "$target" ]] || fail "invalid signing target"
[[ -x /usr/bin/codesign && -x /usr/bin/plutil ]] || fail "required system signing tools are absent"
printf 'sign-release-app: tool=/usr/bin/codesign\n'

case "$channel" in
  adhoc)
    identity='-'
    timestamp='--timestamp=none'
    ;;
  developer-id)
    identity="${LECTURA_CODESIGN_IDENTITY:?sign-release-app: developer-id requires LECTURA_CODESIGN_IDENTITY}"
    : "${LECTURA_NOTARY_PROFILE:?sign-release-app: developer-id requires LECTURA_NOTARY_PROFILE}"
    [[ "$identity" == 'Developer ID Application: '* ]] || fail "identity is not Developer ID Application"
    timestamp='--timestamp'
    ;;
  *) fail "invalid LECTURA_RELEASE_CHANNEL: $channel" ;;
esac

if [[ "$scope" == "preflight" ]]; then
  if [[ "$channel" == "adhoc" ]]; then
    printf 'sign-release-app: channel=adhoc hardened_runtime=false notarized=false\n'
  else
    printf 'sign-release-app: channel=developer-id hardened_runtime=true notarized=pending\n'
  fi
  exit 0
fi

sign_args=(--force --sign "$identity" "$timestamp")
[[ "$channel" == "developer-id" ]] && sign_args+=(--options runtime)
if [[ "$scope" == "app" ]]; then
  [[ -f "$entitlements" ]] || fail "missing app entitlements"
  [[ ! -e "$target/Contents/.lectura-release-invalid" ]] || fail "candidate is marked invalid"
  sign_args+=(--entitlements "$entitlements")
fi
/usr/bin/codesign "${sign_args[@]}" "$target" >/dev/null

verify_args=(--verify --strict --verbose=4)
[[ "$scope" == "app" ]] && verify_args+=(--deep)
/usr/bin/codesign "${verify_args[@]}" "$target" >/dev/null

if [[ "$scope" == "app" ]]; then
  [[ "$(/usr/bin/codesign --display --entitlements :- "$target" 2>/dev/null \
    | /usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - - 2>/dev/null)" == "true" ]] \
    || fail "App Sandbox entitlement is absent"
  if get_task_allow="$(/usr/bin/codesign --display --entitlements :- "$target" 2>/dev/null \
    | /usr/bin/plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - - 2>/dev/null)"; then
    [[ "$get_task_allow" == "false" ]] || fail "get-task-allow must be disabled"
  fi
  signature_info="$(/usr/bin/codesign --display --verbose=4 "$target" 2>&1)"
  if [[ "$channel" == "adhoc" ]]; then
    [[ "$signature_info" == *'Signature=adhoc'* && "$signature_info" != *'flags='*'runtime'* ]] \
      || fail "ad hoc signature policy mismatch"
    printf 'sign-release-app: channel=adhoc hardened_runtime=false notarized=false\n'
  else
    [[ "$signature_info" == *"Authority=$identity"* && "$signature_info" == *'flags='*'runtime'* ]] \
      || fail "Developer ID or Hardened Runtime missing"
    printf 'sign-release-app: channel=developer-id hardened_runtime=true notarized=pending\n'
  fi
fi
