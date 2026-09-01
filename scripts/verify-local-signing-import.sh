#!/bin/zsh
set -euo pipefail

# Exercise the same PKCS#12 import contract used by configure-local-signing.sh
# without touching the login keychain. This catches macOS/OpenSSL format drift
# before a developer reaches the interactive setup flow.
probe_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/local-dictation-signing-probe.XXXXXX")
probe_keychain="$probe_root/probe.keychain-db"
probe_password=$(/usr/bin/openssl rand -hex 32)
private_key="$probe_root/key.pem"
certificate="$probe_root/cert.pem"
identity_archive="$probe_root/identity.p12"
probe_binary="$probe_root/probe"
identity_label="Local Dictation Local Signing - Probe"
original_keychains=("${(@f)$(/usr/bin/security list-keychains -d user | /usr/bin/sed -E 's/^[[:space:]]*"(.*)"$/\1/')}" )
default_keychain=$(
  /usr/bin/security default-keychain -d user \
    | /usr/bin/sed -E 's/^[[:space:]]*"([^"]+)"[[:space:]]*$/\1/'
)

cleanup() {
  if (( ${#original_keychains[@]} > 0 )); then
    /usr/bin/security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
  fi
  /usr/bin/security delete-keychain "$probe_keychain" >/dev/null 2>&1 || true
  /bin/chmod -R u+w "$probe_root" >/dev/null 2>&1 || true
  /bin/rm -rf "$probe_root"
}
trap cleanup EXIT HUP INT TERM

[[ "$probe_password" =~ '^[A-Fa-f0-9]{64}$' ]]
[[ -n "$default_keychain" && -f "$default_keychain" ]]
/usr/bin/security create-keychain -p "$probe_password" "$probe_keychain"
/usr/bin/security unlock-keychain -p "$probe_password" "$probe_keychain"
/usr/bin/security set-keychain-settings -lut 3600 "$probe_keychain"
/usr/bin/security list-keychains -d user -s "$probe_keychain" "${original_keychains[@]}"

/usr/bin/openssl req \
  -new \
  -newkey rsa:3072 \
  -x509 \
  -nodes \
  -sha256 \
  -days 1 \
  -subj "/CN=$identity_label/O=Local Dictation" \
  -addext "basicConstraints=critical,CA:true" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "subjectKeyIdentifier=hash" \
  -addext "authorityKeyIdentifier=keyid:always,issuer" \
  -keyout "$private_key" \
  -out "$certificate" >/dev/null 2>&1

/usr/bin/openssl pkcs12 \
  -export \
  -inkey "$private_key" \
  -in "$certificate" \
  -name "$identity_label" \
  -passout "pass:$probe_password" \
  -out "$identity_archive"
/bin/chmod 600 "$private_key" "$certificate" "$identity_archive"

/usr/bin/security import "$identity_archive" \
  -k "$probe_keychain" \
  -P "$probe_password" \
  -x \
  -T /usr/bin/codesign >/dev/null

identity_sha1=$(
  /usr/bin/openssl x509 -in "$certificate" -outform der \
    | /usr/bin/shasum -a 1 \
    | /usr/bin/awk '{ print toupper($1) }'
)
[[ "$identity_sha1" =~ '^[A-Fa-f0-9]{40}$' ]]
/usr/bin/security find-identity -p codesigning "$probe_keychain" \
  | /usr/bin/grep -Fq "$identity_sha1"

# A real login-keychain setup asks for its password once. The disposable
# keychain has a known password, so establish the same narrow access policy
# noninteractively for the regression probe.
/usr/bin/security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -l "$identity_label" \
  -k "$probe_password" \
  "$probe_keychain" >/dev/null

/bin/cp /usr/bin/true "$probe_binary"
/usr/bin/codesign \
  --force \
  --sign "$identity_sha1" \
  --keychain "$probe_keychain" \
  --timestamp=none \
  "$probe_binary"
/usr/bin/codesign --verify --strict "$probe_binary"

print "Disposable PKCS#12 signing import verified."
