#!/bin/zsh
set -euo pipefail

ROTATE=0
for argument in "$@"; do
  case "$argument" in
    --rotate) ROTATE=1 ;;
    *) print -u2 "Unknown signing option: $argument"; exit 64 ;;
  esac
done

STATE_ROOT=${LOCAL_DICTATION_SIGNING_STATE_DIR:-"$HOME/Library/Application Support/Local Dictation/Signing"}
STATE_FILE="$STATE_ROOT/identity.plist"
BUNDLE_ID="com.natemunk.LocalDictation"
LOGIN_KEYCHAIN=$(
  /usr/bin/security default-keychain -d user \
    | /usr/bin/sed -E 's/^[[:space:]]*"([^"]+)"[[:space:]]*$/\1/'
)
if [[ -z "$LOGIN_KEYCHAIN" || ! -f "$LOGIN_KEYCHAIN" ]]; then
  print -u2 "Unable to resolve the default login keychain."
  exit 1
fi

read_state() {
  /usr/bin/plutil -extract "$1" raw "$STATE_FILE" 2>/dev/null || true
}

identity_is_available() {
  local sha1=$1
  [[ -n "$sha1" ]] || return 1
  /usr/bin/security find-identity -p codesigning "$LOGIN_KEYCHAIN" \
    | /usr/bin/grep -Fq "$sha1"
}

if [[ -f "$STATE_FILE" && $ROTATE -eq 0 ]]; then
  configured_sha1=$(read_state IdentitySHA1)
  configured_label=$(read_state IdentityLabel)
  if identity_is_available "$configured_sha1"; then
    print "Stable Local Dictation signing identity is already configured:"
    print "  $configured_label"
    print "  SHA-1 $configured_sha1"
    exit 0
  fi

  print -u2 "The recorded Local Dictation signing identity is missing or unusable."
  print -u2 "Run ./setup --rotate-signing-identity to create a replacement intentionally."
  exit 1
fi

if [[ ! -t 0 ]]; then
  print -u2 "Signing configuration changes your login keychain and requires an interactive terminal."
  exit 1
fi

print "Local Dictation needs one stable, per-machine signing identity so macOS permissions"
print "survive rebuilds. This operation will:"
print "  • create a 10-year self-signed certificate and private key"
print "  • import the non-extractable private key into your login keychain"
print "  • authorize Apple code-signing tools to use only that signing key"
print "  • store only its label, fingerprints, and expected requirement outside the repo"
print ""
print "macOS will request your login keychain password once. The private key is"
print "never exported automatically. Rotation changes the app identity and requires one"
print "final permission reset."
print ""
read -r "confirmation?Type CREATE to continue: "
if [[ "$confirmation" != "CREATE" ]]; then
  print "Signing configuration cancelled."
  exit 1
fi

temporary_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/local-dictation-signing.XXXXXX")
identity_sha1=""
identity_imported=0
identity_persisted=0
cleanup() {
  if (( identity_imported && ! identity_persisted )) \
      && [[ "$identity_sha1" =~ '^[A-Fa-f0-9]{40}$' ]]; then
    /usr/bin/security delete-identity \
      -Z "$identity_sha1" \
      "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || true
  fi
  /bin/chmod -R u+w "$temporary_root" 2>/dev/null || true
  /bin/rm -rf "$temporary_root"
}
trap cleanup EXIT HUP INT TERM
/bin/chmod 700 "$temporary_root"

host_name=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || /bin/hostname -s)
safe_host=$(print -r -- "$host_name" | /usr/bin/tr -cd 'A-Za-z0-9._-')
[[ -n "$safe_host" ]] || safe_host="Mac"
identity_label="Local Dictation Local Signing - $safe_host"
if (( ROTATE )); then
  identity_label="$identity_label - $(/bin/date -u +%Y%m%dT%H%M%SZ)"
fi

openssl_config="$temporary_root/openssl.cnf"
private_key="$temporary_root/local-dictation.key.pem"
certificate="$temporary_root/local-dictation.cert.pem"
identity_archive="$temporary_root/local-dictation.identity.p12"

/bin/cat > "$openssl_config" <<EOF
[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions

[subject]
CN = $identity_label
O = Local Dictation

[extensions]
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

/usr/bin/openssl req \
  -new \
  -newkey rsa:3072 \
  -x509 \
  -nodes \
  -sha256 \
  -days 3650 \
  -config "$openssl_config" \
  -keyout "$private_key" \
  -out "$certificate"
/bin/chmod 600 "$private_key" "$certificate"

identity_sha1=$(
  /usr/bin/openssl x509 -in "$certificate" -outform der \
    | /usr/bin/shasum -a 1 \
    | /usr/bin/awk '{ print toupper($1) }'
)
if [[ ! "$identity_sha1" =~ '^[A-Fa-f0-9]{40}$' ]]; then
  print -u2 "Unable to fingerprint the generated signing certificate."
  exit 1
fi

# `openssl req` emits an unencrypted PKCS#8 PEM key on current macOS releases,
# but `security import -f openssl` rejects that otherwise-valid representation
# as an unknown format. Package the certificate and key into the native
# Keychain interchange format instead. The archive password is random,
# short-lived, and protects only this temporary file, which the EXIT trap
# always removes.
archive_password=$(/usr/bin/openssl rand -hex 32)
if [[ ! "$archive_password" =~ '^[A-Fa-f0-9]{64}$' ]]; then
  print -u2 "Unable to create a temporary password for the signing identity archive."
  exit 1
fi
/usr/bin/openssl pkcs12 \
  -export \
  -inkey "$private_key" \
  -in "$certificate" \
  -name "$identity_label" \
  -passout "pass:$archive_password" \
  -out "$identity_archive"
/bin/chmod 600 "$identity_archive"

print "Importing the non-extractable code-signing identity into: $LOGIN_KEYCHAIN"
# Let Keychain infer PKCS#12 from the `.p12` extension. On current macOS,
# explicitly combining `-t agg -f pkcs12` can report success against the login
# keychain without actually importing an identity.
if ! /usr/bin/security import "$identity_archive" \
    -k "$LOGIN_KEYCHAIN" \
    -P "$archive_password" \
    -x \
    -T /usr/bin/codesign; then
  print -u2 "macOS could not import the Local Dictation signing identity."
  exit 1
fi
archive_password=""
identity_imported=1

if ! /usr/bin/security find-identity -p codesigning "$LOGIN_KEYCHAIN" \
    | /usr/bin/grep -Fq "$identity_sha1"; then
  print -u2 "macOS reported a successful import, but the identity is absent from the login keychain."
  exit 1
fi

if ! /usr/bin/security find-key \
    -t private \
    -s \
    -l "$identity_label" \
    "$LOGIN_KEYCHAIN" >/dev/null; then
  print -u2 "The certificate was imported without its matching private key."
  exit 1
fi

print "Authorizing Apple code-signing tools for the new private key…"
print "Enter your login keychain password at the secure prompt below."
if ! /usr/bin/security set-key-partition-list \
    -S apple-tool:,apple: \
    -s \
    -l "$identity_label" \
    "$LOGIN_KEYCHAIN" >/dev/null; then
  print -u2 "Private-key authorization failed; the newly imported identity was removed."
  exit 1
fi

signing_probe="$temporary_root/codesign-probe"
/bin/cp /usr/bin/true "$signing_probe"
print "Verifying the new identity with codesign…"
if ! /usr/bin/codesign \
    --force \
    --sign "$identity_sha1" \
    --keychain "$LOGIN_KEYCHAIN" \
    --timestamp=none \
    "$signing_probe"; then
  print -u2 "codesign was not authorized; the newly imported identity was removed."
  exit 1
fi
if ! /usr/bin/codesign --verify --strict "$signing_probe"; then
  print -u2 "The new identity could not produce a valid signature and was removed."
  exit 1
fi

certificate_sha256=$(
  /usr/bin/openssl x509 -in "$certificate" -outform der \
    | /usr/bin/shasum -a 256 \
    | /usr/bin/awk '{ print toupper($1) }'
)
expected_requirement="designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$identity_sha1\""

/bin/mkdir -p "$STATE_ROOT"
/bin/chmod 700 "$STATE_ROOT"
state_staging="$temporary_root/identity.plist"
/usr/bin/plutil -create xml1 "$state_staging"
/usr/bin/plutil -insert IdentityLabel -string "$identity_label" "$state_staging"
/usr/bin/plutil -insert IdentitySHA1 -string "$identity_sha1" "$state_staging"
/usr/bin/plutil -insert CertificateSHA256 -string "$certificate_sha256" "$state_staging"
/usr/bin/plutil -insert ExpectedDesignatedRequirement -string "$expected_requirement" "$state_staging"
/usr/bin/plutil -insert StableInstallCompleted -bool false "$state_staging"
/usr/bin/plutil -insert ConfiguredAtUTC -string "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$state_staging"
/bin/chmod 600 "$state_staging"
/bin/mv "$state_staging" "$STATE_FILE"
identity_persisted=1

print "Stable signing identity configured:"
print "  $identity_label"
print "  SHA-1   $identity_sha1"
print "  SHA-256 $certificate_sha256"
print ""
print "For an encrypted backup, use Keychain Access to export this identity manually"
print "and store the encrypted export separately. Local Dictation never exports the"
print "private key itself."
