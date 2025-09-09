#!/usr/bin/env bash
# Quick verification of Zimbra credential behavior with 2FA/app passwords.
# Tries both SOAP AuthRequest and AutoDiscover Basic to classify credentials.
#
# Usage (env only):
#   SHIM_TEST_BASE_URL=https://mail.example.com \
#   SHIM_TEST_USER=user@example.com \
#   SHIM_TEST_PASSWORD='password-or-app-pass' \
#   ./test/verify_credentials.sh [--insecure]
#
# Exit codes:
#   0 = some method succeeded (SOAP or AutoDiscover)
#   1 = both methods failed

set -euo pipefail

# Inputs via env
BASE_URL="${SHIM_TEST_BASE_URL:-}"
USER="${SHIM_TEST_USER:-}"
PASS="${SHIM_TEST_PASSWORD:-}"
# Optional arg or env to allow self-signed
INSECURE_ARG="${1:-}"
if [[ -z "${INSECURE_ARG}" && -n "${INSECURE:-}" ]]; then
  INSECURE_ARG="--insecure"
fi

if [[ -z "$BASE_URL" || -z "$USER" || -z "$PASS" ]]; then
  echo "Usage: Set SHIM_TEST_BASE_URL, SHIM_TEST_USER, SHIM_TEST_PASSWORD then run: $0 [--insecure]" >&2
  exit 2
fi

curl_common=("-sS" "-m" "12" "--connect-timeout" "5")
if [[ "$INSECURE_ARG" == "--insecure" ]]; then
  curl_common+=("-k")
fi

trim_slash() { local s="$1"; s="${s%/}"; printf "%s" "$s"; }
json_escape() {
  # Escapes quotes and backslashes for JSON string values
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

root_url="$(trim_slash "$BASE_URL")"

echo "== SOAP AuthRequest check (primary password expected) =="
soap_url="$root_url/service/soap"
json_body=$(printf '{"Header":{},"Body":{"AuthRequest":{"_jsns":"urn:zimbraAccount","account":{"by":"name","_content":"%s"},"password":"%s"}}}' \
  "$USER" "$(printf '%s' "$PASS" | json_escape)")
soap_code=$(curl "${curl_common[@]}" -H 'Content-Type: application/json' -o /dev/null -w '%{http_code}' \
  -X POST --data "$json_body" "$soap_url" || true)

if [[ "$soap_code" == "200" ]]; then
  echo "SOAP auth: SUCCESS (HTTP 200). Likely primary password or 2FA off."
  soap_ok=1
else
  echo "SOAP auth: FAIL (HTTP $soap_code). Expected for app passwords or 2FA without second factor."
  soap_ok=0
fi

echo
echo "== AutoDiscover Basic check (app password path via zsync) =="
ad_url="$root_url/Autodiscover/Autodiscover.xml"
basic_b64=$(printf '%s:%s' "$USER" "$PASS" | base64)
ad_code=$(curl "${curl_common[@]}" \
  -H "Authorization: Basic $basic_b64" \
  -H 'Content-Type: text/xml; charset=UTF-8' \
  -o /dev/null -w '%{http_code}' \
  -X POST --data-binary @- "$ad_url" <<EOF || true
<?xml version="1.0" encoding="utf-8"?>
<Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/mobilesync/requestschema/2006">
  <Request>
    <EMailAddress>$USER</EMailAddress>
    <AcceptableResponseSchema>http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a</AcceptableResponseSchema>
  </Request>
  </Autodiscover>
EOF
)

if [[ "$ad_code" == "401" ]]; then
  echo "AutoDiscover: FAIL (HTTP 401). Credentials rejected under zsync path."
  ad_ok=0
else
  echo "AutoDiscover: SUCCESS (HTTP $ad_code). Credentials accepted under zsync path."
  ad_ok=1
fi

echo
echo "== Classification =="
if [[ "$soap_ok" -eq 1 && "$ad_ok" -eq 1 ]]; then
  echo "Both methods succeeded. Password is valid; app password support also OK."
  exit 0
elif [[ "$soap_ok" -eq 1 && "$ad_ok" -eq 0 ]]; then
  echo "SOAP succeeded; AutoDiscover failed. Likely a primary password with 2FA off."
  exit 0
elif [[ "$soap_ok" -eq 0 && "$ad_ok" -eq 1 ]]; then
  echo "SOAP failed; AutoDiscover succeeded. Likely an app password or primary password with 2FA enabled."
  exit 0
else
  echo "Both methods failed. Invalid credentials or server not accepting these paths."
  exit 1
fi
