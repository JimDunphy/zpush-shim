#!/usr/bin/env bash
set -euo pipefail

# Verify getuserinfo by authenticating first via header token flow.
# Requires jq for JSON parsing and uses test/shim-auth-token.sh to obtain a shim authToken.

if ! command -v jq >/dev/null 2>&1; then
  echo "[ERROR] jq is required (sudo yum/apt install jq)" >&2
  exit 2
fi

# Run the one-shot SOAP + header auth script and capture output JSON
OUT=$(bash test/shim-auth-token.sh)
echo "$OUT"

SHIM_TOKEN=$(printf '%s' "$OUT" | jq -r '.authToken // empty')
if [ -z "$SHIM_TOKEN" ]; then
  echo "[ERROR] Could not parse shim authToken from authenticate output" >&2
  exit 3
fi

BASE_URL=${BASE_URL:-http://localhost:8080}
ENDPOINT=${ENDPOINT:-/service/extension/zpush-shim}

echo "POST ${BASE_URL%/}${ENDPOINT} action=getuserinfo"
RESP=$(curl -sS -X POST \
  -d "action=getuserinfo" \
  -d "authToken=${SHIM_TOKEN}" \
  "${BASE_URL%/}${ENDPOINT}")
echo "$RESP"

echo "$RESP" | jq -e '.accountId and .displayName' >/dev/null && echo "[PASS] getuserinfo" || { echo "[FAIL] getuserinfo"; exit 1; }

