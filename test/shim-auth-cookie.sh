#!/usr/bin/env bash
set -euo pipefail

# Cookie-based authenticate against the shim endpoint.
# Requires a prior SOAP JSON login (to obtain ZM_AUTH_TOKEN and optional csrfToken).

COOKIE_FILE=${COOKIE_FILE:-c.txt}
SOAP_JSON=${SOAP_JSON:-soap.json}
BASE_URL=${BASE_URL:-http://localhost:8080}

CSRF_HEADER=()
if [ -f "$SOAP_JSON" ]; then
  if command -v jq >/dev/null 2>&1; then
    CSRF=$(jq -r '.Body.context.csrfToken // .Body.AuthResponse.csrfToken // empty' "$SOAP_JSON" || true)
    if [ -n "${CSRF:-}" ]; then
      CSRF_HEADER=(-H "X-Zimbra-Csrf-Token: $CSRF")
    fi
  fi
fi

curl -sS -b "$COOKIE_FILE" -X POST \
  "${CSRF_HEADER[@]}" \
  -d "action=authenticate" \
  "${BASE_URL%/}/service/extension/zpush-shim"

