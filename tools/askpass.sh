#!/usr/bin/env bash
# GIT_ASKPASS helper: answers git's credential prompts from the central store.
#
#   GIT_ASKPASS=tools/askpass.sh git push
#
# git calls this twice per connection: once for the username, once for the
# password. GitHub accepts any username when the password is a token, so the
# username answer is a constant. The token goes to stdout only - that is the
# whole protocol - and is never written to a file.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

prompt="${1:-}"
case "$prompt" in
  *[Uu]sername*)
    printf '%s\n' "x-access-token"
    ;;
  *)
    if [ -n "${GH_TOKEN:-}" ]; then
      printf '%s\n' "$GH_TOKEN"
    else
      printf '%s\n' "$("$here/secrets.sh" get GH_TOKEN)"
    fi
    ;;
esac
