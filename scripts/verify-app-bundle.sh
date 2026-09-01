#!/bin/zsh
set -euo pipefail

if (( $# < 1 )); then
  print -u2 "Usage: $0 <Local Dictation.app> [--expected-requirement <requirement>] [--allow-adhoc]"
  exit 64
fi

APP_PATH=$1
shift
EXPECTED_REQUIREMENT=""
ALLOW_ADHOC=0
while (( $# )); do
  case "$1" in
    --expected-requirement)
      (( $# >= 2 )) || { print -u2 -- "--expected-requirement needs a value"; exit 64; }
      EXPECTED_REQUIREMENT=$2
      shift 2
      ;;
    --allow-adhoc)
      ALLOW_ADHOC=1
      shift
      ;;
    *) print -u2 "Unknown verification option: $1"; exit 64 ;;
  esac
done

fail() {
  print -u2 "App verification failed: $*"
  exit 1
}

[[ -d "$APP_PATH" ]] || fail "missing app bundle at $APP_PATH"
PLIST="$APP_PATH/Contents/Info.plist"
BINARY="$APP_PATH/Contents/MacOS/LocalDictation"
RESOURCES="$APP_PATH/Contents/Resources"
[[ -f "$PLIST" ]] || fail "missing Contents/Info.plist"
[[ -x "$BINARY" ]] || fail "missing executable LocalDictation"
[[ -d "$RESOURCES" ]] || fail "missing Contents/Resources"

bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw "$PLIST" 2>/dev/null || true)
[[ "$bundle_id" == "com.natemunk.LocalDictation" ]] || fail "unexpected bundle identifier: ${bundle_id:-missing}"
minimum_os=$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$PLIST" 2>/dev/null || true)
[[ "$minimum_os" == "15.0" ]] || fail "unexpected minimum macOS version: ${minimum_os:-missing}"
executable_name=$(/usr/bin/plutil -extract CFBundleExecutable raw "$PLIST" 2>/dev/null || true)
[[ "$executable_name" == "LocalDictation" ]] || fail "unexpected executable name: ${executable_name:-missing}"

architectures=$(/usr/bin/lipo -archs "$BINARY" 2>/dev/null || true)
[[ "$architectures" == "arm64" ]] || fail "expected arm64-only executable, found: ${architectures:-unknown}"

required_bundles=(
  "LocalDictation_LocalDictation.bundle"
  "GRDB_GRDB.bundle"
  "swift-transformers_Hub.bundle"
)
for bundle_name in "${required_bundles[@]}"; do
  [[ -d "$RESOURCES/$bundle_name" ]] || fail "missing required SwiftPM resource bundle: $bundle_name"
done

hub_bundle="$RESOURCES/swift-transformers_Hub.bundle"
[[ -f "$hub_bundle/t5_tokenizer_config.json" ]] || fail "Hub bundle is missing t5_tokenizer_config.json"
[[ -f "$hub_bundle/gpt2_tokenizer_config.json" ]] || fail "Hub bundle is missing gpt2_tokenizer_config.json"

while IFS= read -r -d '' candidate; do
  [[ "$candidate" == "$BINARY" ]] && continue
  if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/codesign --verify --strict --verbose=2 "$candidate" \
      || fail "invalid nested code: $candidate"
  fi
done < <(/usr/bin/find "$APP_PATH/Contents" -type f -print0)

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
  || fail "signature or sealed resources are invalid"

signature_details=$(/usr/bin/codesign -dvvv "$APP_PATH" 2>&1 || true)
if (( ! ALLOW_ADHOC )) && print -r -- "$signature_details" | /usr/bin/grep -Fq 'Signature=adhoc'; then
  fail "ad-hoc signature is forbidden for a normal source install"
fi

actual_requirement=$(
  /usr/bin/codesign -d -r- "$APP_PATH" 2>&1 \
    | /usr/bin/sed -n 's/^designated =>/designated =>/p' \
    | /usr/bin/head -n 1
)
[[ -n "$actual_requirement" ]] || fail "no designated requirement was emitted"
# `codesign` renders hexadecimal certificate slots in lowercase even when the
# equivalent requirement was supplied with an uppercase fingerprint. Bundle ID,
# architecture, and entitlements are checked independently above, so compare the
# requirement language with only ASCII case normalized.
if [[ -n "$EXPECTED_REQUIREMENT" \
   && "${actual_requirement:l}" != "${EXPECTED_REQUIREMENT:l}" ]]; then
  fail "designated requirement drifted (expected: $EXPECTED_REQUIREMENT; actual: $actual_requirement)"
fi

entitlements_file=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/local-dictation-entitlements.XXXXXX")
cleanup() { /bin/rm -f "$entitlements_file"; }
trap cleanup EXIT HUP INT TERM
/usr/bin/codesign -d --entitlements :- "$APP_PATH" > "$entitlements_file" 2>/dev/null \
  || fail "could not read signed entitlements"
audio_entitlement=$(
  /usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$entitlements_file" 2>/dev/null \
    || true
)
[[ "$audio_entitlement" == "true" ]] || fail "signed app lacks the microphone entitlement"

print "Verified Local Dictation app bundle:"
print "  identifier: $bundle_id"
print "  architecture: $architectures"
print "  minimum macOS: $minimum_os"
print "  designated requirement: $actual_requirement"
