#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

CFG="${1:-$HERE/shim-tests.yml}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 2
fi

exec python3 "$HERE/test_shim_endpoints.py" --config "$CFG"

