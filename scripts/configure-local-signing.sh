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
LOGIN_KEYCHAIN=$(/usr/bin/security default-keychain -d user | /usr/bin/tr -d '"')

read_state() {
  /usr/bin/plutil -extract "$1" raw "$STATE_FILE" 2>/dev/null || true
}

identity_is_available() {
  local sha1=$1
  [[ -n "$sha1" ]] || return 1
  /usr/bin/security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" \
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

  print -u2 "The recorded Local Dictation signing identity is missing or no longer trusted."
  print -u2 "Run ./setup --rotate-signing-identity to create a replacement intentionally."
  exit 1
fi

if [[ ! -t 0 ]]; then
  print -u2 "Signing configuration changes your login keychain trust settings and requires an interactive terminal."
  exit 1
fi

print "Local Dictation needs one stable, per-machine signing identity so macOS permissions"
print "survive rebuilds. This operation will:"
print "  • create a 10-year self-signed certificate and private key"
print "  • import the non-extractable private key into your login keychain"
print "  • trust the certificate for code signing only in your user trust domain"
print "  • store only its label, fingerprints, and expected requirement outside the repo"
print ""
print "macOS may request your login password or keychain approval. The private key is"
print "never exported automatically. Rotation changes the app identity and requires one"
print "final permission reset."
print ""
read -r "confirmation?Type CREATE to continue: "
if [[ "$confirmation" != "CREATE" ]]; then
  print "Signing configuration cancelled."
  exit 1
fi

temporary_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/local-dictation-signing.XXXXXX")
cleanup() {
  /bin/chmod -R u+w "$temporary_root" 2>/dev/null || true
  /bin/rm -rf "$temporary_root"
}
trap cleanup EXIT HUP INT TERM
/bin/chmod 700 "$temporary_root"

host_name=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || /bin/hostname -s)
safe_host=$(print -r -- "$host_name" | /usr/bin/tr -cd 'A-Za-z0-9._-')
[[ -n "$safe_host" ]] || safe_host="Mac"
identity_label="Local Dictation Local Signing — $safe_host"
if (( ROTATE )); then
  identity_label="$identity_label — $(/bin/date -u +%Y%m%dT%H%M%SZ)"
fi

openssl_config="$temporary_root/openssl.cnf"
private_key="$temporary_root/local-dictation.key.pem"
certificate="$temporary_root/local-dictation.cert.pem"

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

print "Importing the non-extractable private key into: $LOGIN_KEYCHAIN"
/usr/bin/security import "$private_key" \
  -k "$LOGIN_KEYCHAIN" \
  -t priv \
  -f openssl \
  -x \
  -T /usr/bin/codesign

print "Adding user-domain trust constrained to code signing…"
/usr/bin/security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$LOGIN_KEYCHAIN" \
  "$certificate"

identity_sha1=$(
  /usr/bin/security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" \
    | /usr/bin/grep -F "\"$identity_label\"" \
    | /usr/bin/awk 'NR == 1 { print $2 }'
)
if [[ ! "$identity_sha1" =~ '^[A-Fa-f0-9]{40}$' ]]; then
  print -u2 "The certificate was imported, but macOS does not recognize it as a valid code-signing identity."
  print -u2 "No signing metadata was saved. Review the certificate trust in Keychain Access, then retry with --rotate-signing-identity."
  exit 1
fi
identity_sha1=${identity_sha1:u}

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
/bin/mv "$state_staging" "$STATE_FILE"
/bin/chmod 600 "$STATE_FILE"

print "Stable signing identity configured:"
print "  $identity_label"
print "  SHA-1   $identity_sha1"
print "  SHA-256 $certificate_sha256"
print ""
print "For an encrypted backup, use Keychain Access to export this identity manually"
print "and store the encrypted export separately. Local Dictation never exports the"
print "private key itself."
