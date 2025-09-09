#!/usr/bin/env bash
# Obtain a Zimbra auth token via domain Preauth (no user password required).
# Useful after validating credentials via AutoDiscover (zsync path).
#
# Usage (env):
#   SHIM_TEST_BASE_URL=https://mail.example.com \
#   SHIM_TEST_USER=user@example.com \
#   SHIM_TEST_PREAUTH_KEY=hex_preAuthKey_from_zmprov_gdpak \
#   ./test/get_token_preauth.sh [--insecure]
#
# Outputs HTTP status and response body (JSON). On success, JSON contains
# Body.AuthResponse.authToken._content and sets ZM_AUTH_TOKEN cookie.

set -euo pipefail

BASE_URL="${SHIM_TEST_BASE_URL:-${BASE_URL:-}}"
ACCOUNT="${SHIM_TEST_USER:-${USER:-}}"
PREAUTH_KEY="${SHIM_TEST_PREAUTH_KEY:-}"
INSECURE_ARG="${1:-}"

if [[ -z "$BASE_URL" || -z "$ACCOUNT" || -z "$PREAUTH_KEY" ]]; then
  echo "Usage: SHIM_TEST_BASE_URL=... SHIM_TEST_USER=... SHIM_TEST_PREAUTH_KEY=... $0 [--insecure]" >&2
  exit 2
fi

trim_slash() { local s="$1"; s="${s%/}"; printf "%s" "$s"; }
root_url="$(trim_slash "$BASE_URL")"

BY="name"
EXPIRES="0"
TS_MS="$(($(date +%s)*1000))"
DATA="$ACCOUNT|$BY|$EXPIRES|$TS_MS"

# Compute HMAC-SHA1(DATA) in hex using the (hex) PREAUTH_KEY string.
# Zimbra's docs/examples compute HMAC with the ASCII form of the hex key.
PREAUTH_HEX=$(printf '%s' "$DATA" | openssl dgst -sha1 -hmac "$PREAUTH_KEY" 2>/dev/null | sed -e 's/^.*= //')

JSON=$(cat <<EOF
{
  "Header": {},
  "Body": {
    "AuthRequest": {
      "_jsns": "urn:zimbraAccount",
      "account": {"by": "$BY", "_content": "$ACCOUNT"},
      "preauth": {"timestamp": "$TS_MS", "expires": "$EXPIRES", "_content": "$PREAUTH_HEX"}
    }
  }
}
EOF
)

SOAP_URL="$root_url/service/soap"
curl_common=("-sS" "-m" "12" "--connect-timeout" "5" "-H" "Content-Type: application/json")
if [[ "$INSECURE_ARG" == "--insecure" || "${INSECURE:-}" != "" ]]; then
  curl_common+=("-k")
fi

echo "POST $SOAP_URL (JSON-SOAP AuthRequest with <preauth>)"
HTTP=$(curl "${curl_common[@]}" -o /tmp/resp.$$ -w '%{http_code}' -X POST --data "$JSON" "$SOAP_URL" || true)
echo "HTTP $HTTP"
echo "--- Response ---"
cat /tmp/resp.$$
echo
rm -f /tmp/resp.$$

if [[ "$HTTP" != "200" ]]; then
  exit 1
fi
exit 0

