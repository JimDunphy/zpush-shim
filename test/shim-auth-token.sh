#!/usr/bin/env bash
set -euo pipefail

# Authenticate to the shim using an explicit auth token header.
# This bypasses servlet cookie parsing quirks by sending:
#   X-Zimbra-Auth-Token: <ZM_AUTH_TOKEN>
#
# Inputs (override via env):
#   TOKEN       - If set, used directly (skips extraction)
#   COOKIE_FILE - Netscape cookie jar from SOAP login (default: c.txt)
#   SOAP_JSON   - JSON output from SOAP AuthRequest (default: soap.json)
#   BASE_URL    - Mailboxd base URL (default: http://localhost:8080)
#   ENDPOINT    - Shim path (default: /service/extension/zpush-shim)
#
# Typical flow (kept inline for one-step testing):
curl -sS -c c.txt -H 'Content-Type: application/json' \
      -d '{"Header":{},"Body":{"AuthRequest":{"_jsns":"urn:zimbraAccount","account":{"by":"name","_content":"jad@zanfellabs.com"},"password":"P?Nx9&Lp&z$HMJME"}}}' \
      http://localhost:8080/service/soap | tee soap.json
# Then call this script to complete shim auth.

COOKIE_FILE=${COOKIE_FILE:-c.txt}
SOAP_JSON=${SOAP_JSON:-soap.json}
BASE_URL=${BASE_URL:-http://localhost:8080}
ENDPOINT=${ENDPOINT:-/service/extension/zpush-shim}

extract_token_from_cookie() {
  local file="$1"
  [ -f "$file" ] || return 1
  # Try formats with/without HttpOnly prefix; pick last match just in case
  awk 'NF>=8 && $7=="ZM_AUTH_TOKEN"{print $8} NF>=7 && $6=="ZM_AUTH_TOKEN"{print $7}' "$file" | tail -n1
}

extract_token_from_json() {
  local file="$1"
  [ -f "$file" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.Body.AuthResponse.authToken[0]._content // empty' "$file"
  else
    # Fallback: naive grep (best-effort)
    grep -o '"authToken"\s*:\s*\[\{"_content":"[^"]\+' "$file" | sed -E 's/.*_content":"(.*)/\1/'
  fi
}

TOKEN=${TOKEN:-}
if [ -z "${TOKEN}" ]; then
  TOKEN=$(extract_token_from_cookie "$COOKIE_FILE" || true)
fi
if [ -z "${TOKEN}" ]; then
  TOKEN=$(extract_token_from_json "$SOAP_JSON" || true)
fi

if [ -z "${TOKEN}" ]; then
  echo "[ERROR] Could not determine ZM_AUTH_TOKEN. Set TOKEN=... or provide $COOKIE_FILE or $SOAP_JSON" >&2
  exit 2
fi

curl -sS -X POST \
  -H "X-Zimbra-Auth-Token: ${TOKEN}" \
  -d 'action=authenticate' \
  "${BASE_URL%/}${ENDPOINT}"

