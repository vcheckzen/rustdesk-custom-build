#!/usr/bin/env bash
# GIT_ASKPASS helper: answers git's credential prompts from ght.txt.
# Usage: GIT_ASKPASS=tools/askpass.sh git push
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prompt="${1:-}"
token="$(tr -d '\r\n' < "$here/../ght.txt")"
case "$prompt" in
  *[Uu]sername*) printf '%s\n' "x-access-token" ;;
  *)             printf '%s\n' "$token" ;;
esac
