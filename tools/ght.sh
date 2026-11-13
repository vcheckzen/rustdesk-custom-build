#!/usr/bin/env bash
# gh wrapper: takes GH_TOKEN from the central secret store.
# The token is never echoed, never passed as an argument, never logged.
#
#   ./tools/ght.sh pr list
#   ./tools/ght.sh secret set RD_ID_SERVER < value.txt
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v gh >/dev/null 2>&1; then
  cat >&2 <<'MSG'
gh is not installed, so this wrapper has nothing to run.

Either install it (https://cli.github.com), or use the REST API directly:
  ./tools/bootstrap.sh          creates the repo and pushes, no gh needed
  ./tools/secrets.sh push       uploads the CI secrets, but also needs gh
MSG
  exit 127
fi

GH_TOKEN="$("$here/secrets.sh" get GH_TOKEN)"
export GH_TOKEN
exec gh "$@"
