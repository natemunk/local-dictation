#!/bin/zsh
set -euo pipefail

# Cloudflare reference material for the Access posture this script verifies:
#   Self-hosted applications and path scoping:
#     https://developers.cloudflare.com/cloudflare-one/applications/configure-apps/self-hosted-public-app/
#   Access policies and the Service Auth action:
#     https://developers.cloudflare.com/cloudflare-one/policies/access/
#   Service tokens (CF-Access-Client-Id / CF-Access-Client-Secret):
#     https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/
#   Worker static assets that serve the public PWA shell at /app/:
#     https://developers.cloudflare.com/workers/static-assets/
# docs/unified-history.md section 7 is the normative token contract.

PROJECT_ROOT=${0:A:h:h}
WORKER_ROOT="$PROJECT_ROOT/cloud/iphone-gateway"
TUNNEL_NAME="local-dictation-iphone"
ORIGIN_HOST="dictate-origin.natemunk.com"
GATEWAY_HOST="dictate.natemunk.com"
ENDPOINT_ROOT="$HOME/Library/Application Support/Local Dictation/iPhone Endpoint"
TUNNEL_CONFIG="$ENDPOINT_ROOT/cloudflared.yml"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.natemunk.LocalDictation.cloudflared.plist"
LAUNCH_LABEL="com.natemunk.LocalDictation.cloudflared"

fail() {
  print -u2 -- "iPhone endpoint setup stopped: $1"
  exit 1
}

http_status() {
  local target_url=$1
  local http_code
  local target_host
  local target_ip
  http_code=$(/usr/bin/curl --silent --show-error --max-time 8 \
    --output /dev/null --write-out '%{http_code}' "$target_url" 2>/dev/null || true)
  if [[ "$http_code" == "000" && "$target_url" == https://* ]]; then
    target_host=${${target_url#*://}%%/*}
    target_ip=$(dig +short A "$target_host" | /usr/bin/head -n 1)
    if [[ "$target_ip" == <->.<->.<->.<-> ]]; then
      http_code=$(/usr/bin/curl --resolve "$target_host:443:$target_ip" \
        --silent --show-error --max-time 8 \
        --output /dev/null --write-out '%{http_code}' "$target_url" 2>/dev/null || true)
    fi
  fi
  print -r -- "$http_code"
}

response_headers() {
  # curl -sI; header names are compared case-insensitively by the caller.
  local target_url=$1
  local headers
  local target_host
  local target_ip
  headers=$(/usr/bin/curl -sI --max-time 8 "$target_url" 2>/dev/null || true)
  if [[ -z "$headers" && "$target_url" == https://* ]]; then
    target_host=${${target_url#*://}%%/*}
    target_ip=$(dig +short A "$target_host" | /usr/bin/head -n 1)
    if [[ "$target_ip" == <->.<->.<->.<-> ]]; then
      headers=$(/usr/bin/curl --resolve "$target_host:443:$target_ip" \
        -sI --max-time 8 "$target_url" 2>/dev/null || true)
    fi
  fi
  print -r -- "$headers"
}

access_http_status() {
  local target_url=$1
  local client_id=$2
  local client_secret=$3
  local http_code
  local target_host
  local target_ip
  http_code=$(print -rl -- \
    "header = \"CF-Access-Client-Id: $client_id\"" \
    "header = \"CF-Access-Client-Secret: $client_secret\"" | \
    /usr/bin/curl --config - --silent --show-error --max-time 8 \
      --output /dev/null --write-out '%{http_code}' "$target_url" 2>/dev/null || true)
  if [[ "$http_code" == "000" && "$target_url" == https://* ]]; then
    target_host=${${target_url#*://}%%/*}
    target_ip=$(dig +short A "$target_host" | /usr/bin/head -n 1)
    if [[ "$target_ip" == <->.<->.<->.<-> ]]; then
      http_code=$(print -rl -- \
        "header = \"CF-Access-Client-Id: $client_id\"" \
        "header = \"CF-Access-Client-Secret: $client_secret\"" | \
        /usr/bin/curl --config - --resolve "$target_host:443:$target_ip" \
          --silent --show-error --max-time 8 \
          --output /dev/null --write-out '%{http_code}' "$target_url" 2>/dev/null || true)
    fi
  fi
  print -r -- "$http_code"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$2"
}

require_command cloudflared "Install cloudflared first: brew install cloudflared"
require_command node "Install Node.js 20 or newer first: brew install node"
require_command npm "npm is required with Node.js."
require_command curl "curl is required."
require_command dig "dig is required."
require_command openssl "openssl is required to generate the short-lived stream signing secret."
require_command xcodebuild "A full Xcode installation is required."

[[ "$(uname -m)" == "arm64" ]] || fail "Local Dictation requires an Apple Silicon Mac."
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[[ "$MACOS_MAJOR" == <-> ]] || fail "Could not determine the macOS version."
(( MACOS_MAJOR >= 15 )) || fail "Local Dictation requires macOS 15 or newer."
xcodebuild -version >/dev/null 2>&1 || fail "Launch Xcode once and finish its component setup."

NODE_MAJOR=$(node --version | /usr/bin/sed -E 's/^v([0-9]+).*/\1/')
[[ "$NODE_MAJOR" == <-> ]] || fail "Could not determine the Node.js version."
(( NODE_MAJOR >= 20 )) || fail "Node.js 20 or newer is required."
[[ -d "$WORKER_ROOT" ]] || fail "The checked-in Worker package is missing."

LOCAL_ENDPOINT_STATUS=$(http_status "http://127.0.0.1:43129/healthz")
[[ "$LOCAL_ENDPOINT_STATUS" == "200" ]] || fail \
  "Open Local Dictation, enable Settings -> iPhone -> Enable the localhost endpoint, and keep the app running during setup."

print "Local Dictation iPhone endpoint setup"
print ""
print "This creates a named outbound-only Cloudflare Tunnel, deploys the gateway"
print "Worker, and installs a per-user launch agent. It never creates a Quick"
print "Tunnel and never writes a service token to Git."
print ""
print "The Worker serves two different kinds of traffic:"
print "  • https://$GATEWAY_HOST/app/  — the Dictation Inbox PWA shell."
print "    Public, credential-free static assets. It must load anonymously."
print "  • https://$GATEWAY_HOST/v1/*  — transcription and history APIs."
print "    Access-protected; every request carries a service token."
print "  • wss://$GATEWAY_HOST/stream  — live audio transport."
print "    Publicly reachable but accepts only a 30-second signed ticket minted"
print "    through the protected /v1 endpoint; no long-lived key enters the URL."
print ""
print "Before continuing, create these Cloudflare Access applications:"
print ""
print "  1. Local Dictation iPhone Gateway"
print "     Zero Trust → Access → Applications → Add an application → Self-hosted."
print "     Application domain: $GATEWAY_HOST with the PATH set to  /v1"
print "     Path scoping is what keeps /app/* public. An application configured"
print "     for the bare hostname will lock the PWA behind Access and this"
print "     script will refuse to finish."
print "     Give this ONE application TWO Service Auth policies, each backed by"
print "     a DIFFERENT service token:"
print "       • Policy A — Shortcut token (used by Apple Shortcuts)"
print "       • Policy B — PWA token (pasted into the Dictation Inbox settings)"
print ""
print "  2. Local Dictation Mac Origin"
print "     Application domain: $ORIGIN_HOST (no path scope)."
print "     One Service Auth policy backed by a THIRD service token, used only"
print "     by the Worker to reach this Mac."
print ""
print "Policy action: Service Auth; Include rule: Service Token."
print "Docs: https://developers.cloudflare.com/cloudflare-one/applications/configure-apps/self-hosted-public-app/"
print "      https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/"
print ""
print "Setup uses the two gateway tokens transiently to verify Access, then you"
print "add the Shortcut token to Apple Shortcuts and the PWA token to the PWA."
print "Only the origin token is persisted, as Worker secrets."
print ""
print "If your Cloudflare login cannot administer Zero Trust, stop here and ask an"
print "account administrator to create those exact apps, paths, policies, and"
print "tokens. Authentication will not be weakened as a workaround."
print -n "Type ACCESS READY after both applications and all three policies exist: "
read -r ACCESS_CONFIRMATION
[[ "$ACCESS_CONFIRMATION" == "ACCESS READY" ]] || fail "Cloudflare Access was not confirmed."

print ""
print "Enter the three service tokens. Secrets are read hidden and never printed."
print -n "Shortcut gateway service-token client ID: "
read -r SHORTCUT_ACCESS_CLIENT_ID
print -n "Shortcut gateway service-token client secret (hidden): "
read -rs SHORTCUT_ACCESS_CLIENT_SECRET
print ""
print -n "PWA gateway service-token client ID: "
read -r PWA_ACCESS_CLIENT_ID
print -n "PWA gateway service-token client secret (hidden): "
read -rs PWA_ACCESS_CLIENT_SECRET
print ""
print -n "Origin service-token client ID: "
read -r ORIGIN_ACCESS_CLIENT_ID
print -n "Origin service-token client secret (hidden): "
read -rs ORIGIN_ACCESS_CLIENT_SECRET
print ""

for token_part in \
  "$SHORTCUT_ACCESS_CLIENT_ID" \
  "$SHORTCUT_ACCESS_CLIENT_SECRET" \
  "$PWA_ACCESS_CLIENT_ID" \
  "$PWA_ACCESS_CLIENT_SECRET" \
  "$ORIGIN_ACCESS_CLIENT_ID" \
  "$ORIGIN_ACCESS_CLIENT_SECRET"; do
  [[ -n "$token_part" && "$token_part" != *[^A-Za-z0-9._-]* ]] \
    || fail "Service-token values may contain only letters, digits, dot, underscore, and hyphen."
done

SHORTCUT_TOKEN_PAIR="$SHORTCUT_ACCESS_CLIENT_ID:$SHORTCUT_ACCESS_CLIENT_SECRET"
PWA_TOKEN_PAIR="$PWA_ACCESS_CLIENT_ID:$PWA_ACCESS_CLIENT_SECRET"
ORIGIN_TOKEN_PAIR="$ORIGIN_ACCESS_CLIENT_ID:$ORIGIN_ACCESS_CLIENT_SECRET"
[[ "$SHORTCUT_TOKEN_PAIR" != "$PWA_TOKEN_PAIR" ]] \
  || fail "The Shortcut and PWA gateway tokens are identical. Section 7 of docs/unified-history.md requires three distinct service tokens so each client can be revoked alone."
[[ "$SHORTCUT_TOKEN_PAIR" != "$ORIGIN_TOKEN_PAIR" ]] \
  || fail "The Shortcut and origin tokens are identical. Section 7 of docs/unified-history.md requires three distinct service tokens so each client can be revoked alone."
[[ "$PWA_TOKEN_PAIR" != "$ORIGIN_TOKEN_PAIR" ]] \
  || fail "The PWA and origin tokens are identical. Section 7 of docs/unified-history.md requires three distinct service tokens so each client can be revoked alone."
[[ "$SHORTCUT_ACCESS_CLIENT_ID" != "$PWA_ACCESS_CLIENT_ID" && \
   "$SHORTCUT_ACCESS_CLIENT_ID" != "$ORIGIN_ACCESS_CLIENT_ID" && \
   "$PWA_ACCESS_CLIENT_ID" != "$ORIGIN_ACCESS_CLIENT_ID" ]] \
  || fail "Two of the three client IDs match. Distinct Cloudflare service tokens always have distinct client IDs; re-copy them from Zero Trust → Access → Service Auth."
unset SHORTCUT_TOKEN_PAIR PWA_TOKEN_PAIR ORIGIN_TOKEN_PAIR

print "Installing the pinned Worker toolchain…"
(cd "$WORKER_ROOT" && npm ci)

if ! (cd "$WORKER_ROOT" && npx wrangler whoami >/dev/null 2>&1); then
  print "Wrangler needs Cloudflare authorization. A browser window may open."
  (cd "$WORKER_ROOT" && npx wrangler login)
fi
(cd "$WORKER_ROOT" && npx wrangler whoami >/dev/null) \
  || fail "Wrangler is not authenticated."

if ! cloudflared tunnel list --output json >/dev/null 2>&1; then
  print "cloudflared needs Cloudflare authorization. A browser window may open."
  cloudflared tunnel login
fi

TUNNEL_JSON=$(cloudflared tunnel list --output json)
TUNNEL_ID=$(print -r -- "$TUNNEL_JSON" | node -e '
  let input = "";
  process.stdin.on("data", chunk => input += chunk);
  process.stdin.on("end", () => {
    const name = process.argv[1];
    const match = JSON.parse(input).find(item =>
      item.name === name &&
      (!item.deleted_at || item.deleted_at === "0001-01-01T00:00:00Z")
    );
    if (match) process.stdout.write(match.id);
  });
' "$TUNNEL_NAME")

if [[ -z "$TUNNEL_ID" ]]; then
  print "Creating named tunnel: $TUNNEL_NAME"
  cloudflared tunnel create "$TUNNEL_NAME"
  TUNNEL_JSON=$(cloudflared tunnel list --output json)
  TUNNEL_ID=$(print -r -- "$TUNNEL_JSON" | node -e '
    let input = "";
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      const name = process.argv[1];
      const match = JSON.parse(input).find(item =>
        item.name === name &&
        (!item.deleted_at || item.deleted_at === "0001-01-01T00:00:00Z")
      );
      if (match) process.stdout.write(match.id);
    });
  ' "$TUNNEL_NAME")
fi
[[ ${#TUNNEL_ID} -eq 36 && "$TUNNEL_ID" != *[^0-9a-fA-F-]* ]] \
  || fail "Could not resolve the named tunnel ID."

CREDENTIAL_FILE="$HOME/.cloudflared/$TUNNEL_ID.json"
[[ -f "$CREDENTIAL_FILE" ]] || fail "Tunnel credentials are missing at $CREDENTIAL_FILE."

/bin/mkdir -p "$ENDPOINT_ROOT" "$HOME/Library/LaunchAgents"
/bin/chmod 700 "$ENDPOINT_ROOT"
/usr/bin/printf '%s\n' \
  "tunnel: $TUNNEL_ID" \
  "credentials-file: $CREDENTIAL_FILE" \
  "no-autoupdate: true" \
  "metrics: 127.0.0.1:43130" \
  "ingress:" \
  "  - hostname: $ORIGIN_HOST" \
  "    service: http://127.0.0.1:43129" \
  "  - service: http_status:404" > "$TUNNEL_CONFIG"
/bin/chmod 600 "$TUNNEL_CONFIG"

print "Creating or verifying the origin DNS route…"
if ! cloudflared tunnel route dns "$TUNNEL_ID" "$ORIGIN_HOST"; then
  CURRENT_CNAME=$(dig +short CNAME "$ORIGIN_HOST" | /usr/bin/tr -d '\n')
  EXPECTED_CNAME="${TUNNEL_ID}.cfargotunnel.com."
  [[ "$CURRENT_CNAME" == "$EXPECTED_CNAME" ]] \
    || fail "$ORIGIN_HOST already has a conflicting DNS record; it was not overwritten."
fi

CLOUDFLARED_BIN=$(command -v cloudflared)
/usr/bin/plutil -create xml1 "$LAUNCH_AGENT"
/usr/bin/plutil -insert Label -string "$LAUNCH_LABEL" "$LAUNCH_AGENT"
/usr/bin/plutil -insert ProgramArguments -xml "<array><string>$CLOUDFLARED_BIN</string><string>tunnel</string><string>--config</string><string>$TUNNEL_CONFIG</string><string>run</string><string>$TUNNEL_ID</string></array>" "$LAUNCH_AGENT"
/usr/bin/plutil -insert RunAtLoad -bool true "$LAUNCH_AGENT"
/usr/bin/plutil -insert KeepAlive -bool true "$LAUNCH_AGENT"
/usr/bin/plutil -insert ProcessType -string Background "$LAUNCH_AGENT"

/bin/launchctl bootout "gui/$UID/$LAUNCH_LABEL" >/dev/null 2>&1 || true
LAUNCH_AGENT_LOADED=0
for bootstrap_attempt in 1 2 3; do
  if /bin/launchctl bootstrap "gui/$UID" "$LAUNCH_AGENT"; then
    LAUNCH_AGENT_LOADED=1
    break
  fi
  /bin/sleep 1
done
(( LAUNCH_AGENT_LOADED == 1 )) || fail "Could not load the cloudflared launch agent after three attempts."
/bin/launchctl kickstart -k "gui/$UID/$LAUNCH_LABEL"

print "Running Worker verification…"
(cd "$WORKER_ROOT" && npm test && npm run typecheck && npm run cf-typegen:check)

print "Deploying behind the Access application you confirmed above…"
(cd "$WORKER_ROOT" && npx wrangler deploy)

print "Storing the dedicated Worker-to-origin Access token."
print -rn -- "$ORIGIN_ACCESS_CLIENT_ID" | \
  (cd "$WORKER_ROOT" && npx wrangler secret put MAC_ACCESS_CLIENT_ID)
print -rn -- "$ORIGIN_ACCESS_CLIENT_SECRET" | \
  (cd "$WORKER_ROOT" && npx wrangler secret put MAC_ACCESS_CLIENT_SECRET)
STREAM_TICKET_SECRET=$(openssl rand -hex 32)
print -rn -- "$STREAM_TICKET_SECRET" | \
  (cd "$WORKER_ROOT" && npx wrangler secret put STREAM_TICKET_SECRET)
unset STREAM_TICKET_SECRET

print ""
print "Verifying the deployed Access posture (ten checks)…"

# (a) The PWA shell is public and carries a Content-Security-Policy.
APP_STATUS=$(http_status "https://$GATEWAY_HOST/app/")
[[ "$APP_STATUS" == "200" ]] || fail \
  "check (a) failed: anonymous GET https://$GATEWAY_HOST/app/ returned $APP_STATUS instead of 200. The gateway Access application must be path-scoped to $GATEWAY_HOST/v1 so the PWA shell stays public."
APP_HEADERS=$(response_headers "https://$GATEWAY_HOST/app/")
[[ "${APP_HEADERS:l}" == *content-security-policy:* ]] || fail \
  "check (a) failed: https://$GATEWAY_HOST/app/ returned 200 but no Content-Security-Policy header. The PWA must not be served without a strict CSP; redeploy the Worker before continuing."

# (b) and (c) Neither protected surface may answer an anonymous request.
GATEWAY_STATUS=$(http_status "https://$GATEWAY_HOST/v1/healthz")
ORIGIN_STATUS=$(http_status "https://$ORIGIN_HOST/healthz")
if [[ "$GATEWAY_STATUS" == "200" ]]; then
  print -u2 "check (b) failed: anonymous https://$GATEWAY_HOST/v1/healthz returned HTTP 200."
  print -u2 "The gateway Access application is missing, misconfigured, or its path scope is wrong."
  print -u2 "Correct the Access application before use; setup will not complete."
  exit 1
fi
if [[ "$ORIGIN_STATUS" == "200" ]]; then
  print -u2 "check (c) failed: anonymous https://$ORIGIN_HOST/healthz returned HTTP 200."
  print -u2 "The Mac origin is reachable without Access. Disable the route and correct the"
  print -u2 "origin Access application before use; setup will not complete."
  exit 1
fi

# (d)-(e) Each gateway token alone must reach the protected gateway health path.
SHORTCUT_TO_GATEWAY=$(access_http_status \
  "https://$GATEWAY_HOST/v1/healthz" \
  "$SHORTCUT_ACCESS_CLIENT_ID" \
  "$SHORTCUT_ACCESS_CLIENT_SECRET")
[[ "$SHORTCUT_TO_GATEWAY" == "200" ]] || fail \
  "check (d) failed: the Shortcut token returned $SHORTCUT_TO_GATEWAY from https://$GATEWAY_HOST/v1/healthz instead of 200. Confirm Service Auth policy A on the $GATEWAY_HOST/v1 application includes that token."
PWA_TO_GATEWAY=$(access_http_status \
  "https://$GATEWAY_HOST/v1/healthz" \
  "$PWA_ACCESS_CLIENT_ID" \
  "$PWA_ACCESS_CLIENT_SECRET")
[[ "$PWA_TO_GATEWAY" == "200" ]] || fail \
  "check (e) failed: the PWA token returned $PWA_TO_GATEWAY from https://$GATEWAY_HOST/v1/healthz instead of 200. Confirm Service Auth policy B on the $GATEWAY_HOST/v1 application includes that token."

# (f)-(h) Cross-use must fail in both directions.
ORIGIN_TO_GATEWAY=$(access_http_status \
  "https://$GATEWAY_HOST/v1/healthz" \
  "$ORIGIN_ACCESS_CLIENT_ID" \
  "$ORIGIN_ACCESS_CLIENT_SECRET")
[[ "$ORIGIN_TO_GATEWAY" != "200" ]] || fail \
  "check (f) failed: the ORIGIN token authenticated to https://$GATEWAY_HOST/v1/healthz. The Worker-to-Mac token must not be accepted by the gateway application; remove it from the gateway Service Auth policies."
SHORTCUT_TO_ORIGIN=$(access_http_status \
  "https://$ORIGIN_HOST/healthz" \
  "$SHORTCUT_ACCESS_CLIENT_ID" \
  "$SHORTCUT_ACCESS_CLIENT_SECRET")
[[ "$SHORTCUT_TO_ORIGIN" != "200" ]] || fail \
  "check (g) failed: the SHORTCUT token authenticated to https://$ORIGIN_HOST/healthz. A phone-held token must never reach the Mac origin directly; remove it from the origin Service Auth policy."
PWA_TO_ORIGIN=$(access_http_status \
  "https://$ORIGIN_HOST/healthz" \
  "$PWA_ACCESS_CLIENT_ID" \
  "$PWA_ACCESS_CLIENT_SECRET")
[[ "$PWA_TO_ORIGIN" != "200" ]] || fail \
  "check (h) failed: the PWA token authenticated to https://$ORIGIN_HOST/healthz. A phone-held token must never reach the Mac origin directly; remove it from the origin Service Auth policy."

# (i) The Worker's own token must reach the origin.
ORIGIN_TO_ORIGIN=$(access_http_status \
  "https://$ORIGIN_HOST/healthz" \
  "$ORIGIN_ACCESS_CLIENT_ID" \
  "$ORIGIN_ACCESS_CLIENT_SECRET")
[[ "$ORIGIN_TO_ORIGIN" == "200" ]] || fail \
  "check (i) failed: the origin token returned $ORIGIN_TO_ORIGIN from https://$ORIGIN_HOST/healthz instead of 200. Confirm the origin Service Auth policy includes that token and that Local Dictation is still running."

# (j) The public WebSocket route must reject requests without a signed ticket.
STREAM_WITHOUT_TICKET=$(http_status "https://$GATEWAY_HOST/stream")
[[ "$STREAM_WITHOUT_TICKET" != "200" && "$STREAM_WITHOUT_TICKET" != "101" ]] || fail \
  "check (j) failed: the public live-audio route accepted a request without a short-lived signed ticket. Disable the route and redeploy before use."

unset SHORTCUT_ACCESS_CLIENT_ID SHORTCUT_ACCESS_CLIENT_SECRET
unset PWA_ACCESS_CLIENT_ID PWA_ACCESS_CLIENT_SECRET
unset ORIGIN_ACCESS_CLIENT_ID ORIGIN_ACCESS_CLIENT_SECRET

print "All ten Access checks passed."
print ""
print "iPhone endpoint infrastructure is configured."
print "  Local listener:    http://127.0.0.1:43129"
print "  Protected origin:  https://$ORIGIN_HOST"
print "  Protected APIs:    https://$GATEWAY_HOST/v1"
print "  Public PWA shell:  https://$GATEWAY_HOST/app/"
print "  Ticketed live path: wss://$GATEWAY_HOST/stream"
print ""
print "Next steps:"
print "  1. Open Local Dictation → Settings → iPhone and enable the endpoint."
print "  2. Follow docs/iphone-shortcut.md using the SHORTCUT gateway token."
print "  3. Follow docs/iphone-pwa.md to install the Dictation Inbox on the"
print "     iPhone Home Screen and paste the PWA gateway token into its"
print "     Settings. The token lives only in the phone's local storage."
print "  4. If you want the iPhone and the Mac to share one history, also"
print "     enable Settings → iPhone → Unified iPhone History. It is off by"
print "     default; while it is off, no remote transcript is persisted and the"
print "     history routes answer history_disabled. Enabling it means desktop"
print "     history transits Cloudflare during PWA synchronization."
print "  5. Run the Shortcut test; a successful result must identify Mac or"
print "     Cloud fallback."
print ""
print "Rotate or revoke any of the three tokens independently in"
print "Zero Trust → Access → Service Auth → Service Tokens."
