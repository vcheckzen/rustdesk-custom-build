#!/usr/bin/env bash
# gh wrapper: loads the token from ght.txt into GH_TOKEN.
# The token is never echoed, never passed as an argument, never logged.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
token_file="$here/../ght.txt"
[[ -f "$token_file" ]] || { echo "ght.txt not found next to tools/" >&2; exit 1; }
GH_TOKEN="$(tr -d '\r\n' < "$token_file")"
[[ -n "$GH_TOKEN" ]] || { echo "ght.txt is empty" >&2; exit 1; }
export GH_TOKEN
exec gh "$@"
