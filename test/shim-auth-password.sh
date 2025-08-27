#!/usr/bin/env bash
set -euo pipefail

# Username/password authenticate against the shim endpoint using URL-encoded form data.

USERNAME=${USERNAME:-user@example.com}
PASSWORD=${PASSWORD:-}
PROTOCOL=${PROTOCOL:-eas}
BASE_URL=${BASE_URL:-http://localhost:8080}

if [ -z "$PASSWORD" ]; then
  read -r -s -p "Password for $USERNAME: " PASSWORD
  echo
fi

curl -sS -X POST \
  --data-urlencode "action=authenticate" \
  --data-urlencode "username=${USERNAME}" \
  --data-urlencode "password=${PASSWORD}" \
  --data-urlencode "protocol=${PROTOCOL}" \
  "${BASE_URL%/}/service/extension/zpush-shim"

