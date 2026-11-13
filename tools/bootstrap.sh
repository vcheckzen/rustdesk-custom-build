#!/usr/bin/env bash
# One-shot bootstrap: create the PUBLIC GitHub repo, push, and generate the Android keystore.
#
#   ./tools/bootstrap.sh [repo-name]
#
# Every credential comes from the central store (secrets/secrets.env) through
# tools/secrets.sh - this script never knows a path. The token is handed to
# curl through a 0600 temp config file, so it never appears in argv, in a URL,
# or in any output. Does not require the `gh` CLI.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

SECRETS="$here/secrets.sh"

command -v git >/dev/null || { echo "git not found" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl not found" >&2; exit 1; }

[ -f "$("$SECRETS" path)" ] || "$SECRETS" init
"$SECRETS" require GH_TOKEN

REPO_NAME="${1:-$("$SECRETS" get GH_REPO 2>/dev/null || echo rustdesk-custom-build)}"
VISIBILITY="$("$SECRETS" get GH_VISIBILITY 2>/dev/null || echo public)"
API="https://api.github.com"

TOKEN="$("$SECRETS" get GH_TOKEN)"
CFG="$(mktemp)"
chmod 600 "$CFG" 2>/dev/null || true

# `rm` can be blocked by endpoint-protection tooling, so overwrite-then-unlink explicitly.
shred_rm() {
  [ -f "$1" ] || return 0
  python3 - "$1" <<'PY' 2>/dev/null || rm -f "$1" 2>/dev/null || true
import os, sys
p = sys.argv[1]
try:
    n = os.path.getsize(p)
    with open(p, "r+b") as f:
        f.write(b"\0" * n)
        f.flush()
        os.fsync(f.fileno())
    os.remove(p)
except OSError:
    pass
PY
}
trap 'shred_rm "$CFG"; shred_rm /tmp/rd-repo.json' EXIT
{
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"
  printf 'header = "Accept: application/vnd.github+json"\n'
  printf 'header = "X-GitHub-Api-Version: 2022-11-28"\n'
} > "$CFG"
unset TOKEN

echo "==> identify account"
LOGIN="$(curl -sS --config "$CFG" "$API/user" | python3 -c 'import sys,json; print(json.load(sys.stdin)["login"])')"
[ -n "$LOGIN" ] || { echo "could not read the authenticated user; token invalid?" >&2; exit 1; }
echo "    $LOGIN"

echo "==> git init + secret guard"
[ -d .git ] || git init -b main >/dev/null
git add -A

leaked="$(git diff --cached --name-only \
  | grep -Ei '(^|/)secrets/|(^|/)ght\.txt$|\.keystore$|\.jks$|keystore\.env$|(^|/)key\.properties$' || true)"
if [ -n "$leaked" ]; then
  echo "REFUSING TO COMMIT, secret files staged:" >&2
  echo "$leaked" >&2
  exit 1
fi

if ! git diff --cached --quiet; then
  git -c commit.gpgsign=false -c user.name="builder" -c user.email="builder@localhost" \
      commit -q -m "custom rustdesk build: patcher + CI"
fi

echo "==> create repository ($VISIBILITY)"
PRIVATE_FLAG=false
[ "$VISIBILITY" = "private" ] && PRIVATE_FLAG=true
CODE="$(curl -sS -o /tmp/rd-repo.json -w '%{http_code}' --config "$CFG" \
  -X POST -H "Content-Type: application/json" \
  -d "{\"name\":\"$REPO_NAME\",\"private\":$PRIVATE_FLAG,\"has_issues\":true,\"has_wiki\":false}" \
  "$API/user/repos")"
case "$CODE" in
  201) echo "    created" ;;
  422) echo "    already exists, reusing" ;;
  *)   echo "    unexpected HTTP $CODE:" >&2; cat /tmp/rd-repo.json >&2; exit 1 ;;
esac
shred_rm /tmp/rd-repo.json

echo "==> push"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "https://github.com/$LOGIN/$REPO_NAME.git"
else
  git remote add origin "https://github.com/$LOGIN/$REPO_NAME.git"
fi
GIT_ASKPASS="$here/askpass.sh" GIT_TERMINAL_PROMPT=0 git push -u origin HEAD

echo "==> verify no secret leaked to the remote"
for f in secrets/secrets.env secrets/keystore/release.keystore \
         ght.txt release.keystore tools/.keystore.env; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --config "$CFG" \
          "$API/repos/$LOGIN/$REPO_NAME/contents/$f")"
  if [ "$code" != "404" ]; then
    echo "    EXPOSED: $f returned HTTP $code -- rotate the token NOW" >&2
    exit 1
  fi
done
echo "    ok (secrets/, the keystore and the legacy files are not published)"

echo "==> android keystore"
KS_FILE="$("$SECRETS" get ANDROID_KEYSTORE_FILE 2>/dev/null || echo secrets/keystore/release.keystore)"
case "$KS_FILE" in /*) ;; *) KS_FILE="$root/$KS_FILE" ;; esac
if [ ! -f "$KS_FILE" ]; then
  command -v keytool >/dev/null || { echo "keytool not found (need a JDK)" >&2; exit 1; }
  mkdir -p "$(dirname "$KS_FILE")"
  PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)"
  keytool -genkeypair -v \
    -keystore "$KS_FILE" -alias rustdesk \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$PASS" -keypass "$PASS" \
    -dname "CN=RustDesk Custom, OU=Self, O=Self, L=NA, ST=NA, C=CN" >/dev/null
  printf '%s' "$PASS" | "$SECRETS" set ANDROID_KEYSTORE_PASSWORD
  printf '%s' "$PASS" | "$SECRETS" set ANDROID_KEY_PASSWORD
  printf '%s' "rustdesk" | "$SECRETS" set ANDROID_KEY_ALIAS
  unset PASS
  echo "    created ${KS_FILE#$root/} (password stored in the central secret store)"
else
  echo "    reusing ${KS_FILE#$root/}"
fi
"$SECRETS" keystore-encode

cat <<EOF

done -> https://github.com/$LOGIN/$REPO_NAME

Every credential now lives in one place: $("$SECRETS" path)
Check it with:  ./tools/secrets.sh check
Overview with:  ./tools/secrets.sh status   (never prints a value)

Repository secrets to add (Settings -> Secrets and variables -> Actions), or
let the script do it:  ./tools/secrets.sh push

  ANDROID_KEYSTORE_B64        generated - copy it out of the store
  ANDROID_KEYSTORE_PASSWORD   generated
  ANDROID_KEY_PASSWORD        generated
  ANDROID_KEY_ALIAS           rustdesk

  RD_ID_SERVER                your hbbs host[:port]
  RD_RELAY_SERVER             your hbbr host[:port]     (optional)
  RD_API_SERVER               https://your-api-host    (optional)
  RD_PUB_KEY                  your hbbs public key
  RD_SITE_DOMAIN              your domain              (optional)

Where the build output goes (this repo is PUBLIC, so its artifacts are not private):
  ARTIFACTS_REPO              e.g. you/rustdesk-artifacts  <- a PRIVATE repo
  ARTIFACTS_TOKEN             fine-grained PAT with Contents: read+write on it
    ...or, instead of a second repo:
  ARTIFACTS_PASSPHRASE        a long random string; artifact is AES-256 encrypted before upload
  If neither is set, the build is uploaded in the clear and deleted after 1 day.

Then: Actions -> Build custom RustDesk -> Run workflow (leave inputs empty to use the secrets).

NOTE: secrets/ is gitignored. Keep a backup; losing the keystore means future
APKs cannot upgrade the installed app.
EOF
