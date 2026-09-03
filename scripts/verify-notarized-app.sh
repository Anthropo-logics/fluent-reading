#!/bin/bash
set -euo pipefail

app="${1:?usage: verify-notarized-app.sh <LecturaFluida.app>}"
channel="${LECTURA_RELEASE_CHANNEL:?verify-notarized-app: set LECTURA_RELEASE_CHANNEL=developer-id}"
identity="${LECTURA_CODESIGN_IDENTITY:?verify-notarized-app: set LECTURA_CODESIGN_IDENTITY}"

fail() {
  printf 'verify-notarized-app: %s\n' "$*" >&2
  exit 1
}

[[ "$channel" == "developer-id" ]] || fail "notarization is unavailable for channel $channel"
[[ "$identity" == 'Developer ID Application: '* ]] || fail "identity is not Developer ID Application"
[[ -d "$app" && ! -L "$app" && ! -e "$app/Contents/.lectura-release-invalid" ]] \
  || fail "invalid release candidate"
[[ -x /usr/bin/codesign && -x /usr/bin/xcrun && -x /usr/sbin/spctl ]] \
  || fail "required system verification tools are absent"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$app" >/dev/null
signature_info="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)"
[[ "$signature_info" == *"Authority=$identity"* \
  && "$signature_info" == *'flags='*'runtime'* ]] \
  || fail "Developer ID or Hardened Runtime missing"
[[ "$(/usr/bin/codesign --display --entitlements :- "$app" 2>/dev/null \
  | /usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - - 2>/dev/null)" == "true" ]] \
  || fail "App Sandbox entitlement is absent"
if get_task_allow="$(/usr/bin/codesign --display --entitlements :- "$app" 2>/dev/null \
  | /usr/bin/plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - - 2>/dev/null)"; then
  [[ "$get_task_allow" == "false" ]] || fail "get-task-allow must be disabled"
fi
/usr/bin/xcrun stapler validate "$app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app"
printf 'verify-notarized-app: channel=developer-id hardened_runtime=true notarized=true\n'
