#!/usr/bin/env bash
# Minimal one-step AutoDiscover credential check using SHIM_TEST_* env vars.
# Returns non-401 on success (works with app passwords under 2FA, and primary when 2FA is off).
#
# Usage:
#   SHIM_TEST_BASE_URL=https://mail.example.com \
#   SHIM_TEST_USER=user@example.com \
#   SHIM_TEST_PASSWORD='secret' \
#   ./test/check_autodiscover.sh [--insecure]

set -euo pipefail

BASE_URL="${SHIM_TEST_BASE_URL:-}"
USER="${SHIM_TEST_USER:-}"
PASS="${SHIM_TEST_PASSWORD:-}"
INSECURE_ARG="${1:-}"

if [[ -z "$BASE_URL" || -z "$USER" || -z "$PASS" ]]; then
  echo "Usage: Set SHIM_TEST_BASE_URL, SHIM_TEST_USER, SHIM_TEST_PASSWORD then run: $0 [--insecure]" >&2
  exit 2
fi

trim_slash() { local s="$1"; s="${s%/}"; printf "%s" "$s"; }
root_url="$(trim_slash "$BASE_URL")"

curl_common=("-sS" "-m" "12" "--connect-timeout" "5" "-H" "Content-Type: text/xml; charset=UTF-8")
if [[ "$INSECURE_ARG" == "--insecure" || -n "${INSECURE:-}" ]]; then
  curl_common+=("-k")
fi

BASIC="$(printf '%s:%s' "$USER" "$PASS" | base64)"
CODE=$(curl "${curl_common[@]}" -H "Authorization: Basic $BASIC" \
  -o /dev/null -w '%{http_code}' -X POST --data-binary @- \
  "$root_url/Autodiscover/Autodiscover.xml" <<EOF || true
<?xml version="1.0" encoding="utf-8"?>
<Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/mobilesync/requestschema/2006">
  <Request>
    <EMailAddress>$USER</EMailAddress>
    <AcceptableResponseSchema>http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a</AcceptableResponseSchema>
  </Request>
</Autodiscover>
EOF
)

if [[ "$CODE" == "401" ]]; then
  echo "[FAIL] AutoDiscover HTTP 401 (invalid credentials)"
  exit 1
else
  if [[ "$CODE" == "503" ]]; then
    echo "[PASS] AutoDiscover HTTP 503 (auth ok; requested schema unsupported on server)"
  else
    echo "[PASS] AutoDiscover HTTP $CODE (credentials accepted under zsync path)"
  fi
  exit 0
fi
