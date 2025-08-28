#!/usr/bin/env bash
set -euo pipefail

# Username/password authenticate against the shim endpoint using URL-encoded form data.
# Behavior:
# - If PROTOCOL is set, only that protocol is tested.
# - Otherwise, tries: eas, http, imap, pop3 (in that order).
# - Stops on first HTTP 200 unless TRY_ALL=1 is set.
# - Exits 0 if any protocol succeeds (HTTP 200), non-zero otherwise.

USERNAME=${USERNAME:-test@zanfellabs.com}
PASSWORD=${PASSWORD:-FAQKHUOKMZLXIIME}
BASE_URL=${BASE_URL:-http://localhost:8080}

# Optional behavior toggles
TRY_ALL=${TRY_ALL:-1}      # 0 = stop on first success, 1 = try all and summarize
VERBOSE=${VERBOSE:-1}      # 1 = print responses, 0 = quiet summary
TIMEOUT=${TIMEOUT:-20}     # curl max time (seconds)

if [ -z "${PASSWORD}" ]; then
  read -r -s -p "Password for ${USERNAME}: " PASSWORD
  echo
fi

# Decide protocol list
if [ -n "${PROTOCOL:-}" ]; then
  PROTOCOLS=("${PROTOCOL}")
else
  PROTOCOLS=(eas http imap pop3)
fi

# Ensure URL has no trailing slash duplication
ENDPOINT="${BASE_URL%/}/service/extension/zpush-shim"

# Temp space for responses
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

any_success=0
declare -A results

for proto in "${PROTOCOLS[@]}"; do
  body_file="${TMPDIR}/resp_${proto}.txt"

  [ "${VERBOSE}" -eq 1 ] && echo "---- Testing protocol: ${proto} ----"

  # Capture HTTP status code while writing body to file
  http_code="$(
    curl -sS -m "${TIMEOUT}" -o "${body_file}" -w "%{http_code}" -X POST \
      --data-urlencode "action=authenticate" \
      --data-urlencode "username=${USERNAME}" \
      --data-urlencode "password=${PASSWORD}" \
      --data-urlencode "protocol=${proto}" \
      --data-urlencode "debug=1" \
      "${ENDPOINT}"
  )"

  results["$proto"]="${http_code}"

  if [ "${VERBOSE}" -eq 1 ]; then
    echo "HTTP ${http_code}"
    # Print body (truncate to avoid huge dumps)
    if command -v head >/dev/null 2>&1; then
      echo "Response (first 200 lines):"
      head -n 200 "${body_file}" || true
    else
      cat "${body_file}" || true
    fi
    echo
  fi

  if [ "${http_code}" = "200" ]; then
    any_success=1
    if [ "${TRY_ALL}" -eq 0 ]; then
      [ "${VERBOSE}" -eq 1 ] && echo "Success with '${proto}'. Stopping early."
      break
    fi
  fi
done

# Summary
echo "==== Summary ===="
for proto in "${PROTOCOLS[@]}"; do
  code="${results[$proto]:-N/A}"
  echo "  ${proto}: HTTP ${code}"
done

if [ "${any_success}" -eq 1 ]; then
  exit 0
else
  echo "No protocol returned HTTP 200."
  exit 1
fi
