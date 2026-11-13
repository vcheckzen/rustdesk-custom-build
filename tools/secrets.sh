#!/usr/bin/env bash
# -----------------------------------------------------------------------------
#  secrets.sh - the single door to every local credential.
#
#  All secrets live in one file, secrets/secrets.env, generated from
#  tools/secrets.env.template. This script is the only thing that reads it, so
#  no other tool ever has to know a path, a format, or a value.
#
#  Values are printed only by `get` (for command substitution) and by
#  `run` (into the child environment). Every other command reports state and
#  length, never content. The file is parsed as data - it is never sourced, so
#  a stray line cannot execute anything.
#
#      ./tools/secrets.sh init            create the store from the template
#      ./tools/secrets.sh edit            open it in $EDITOR
#      ./tools/secrets.sh check           validate everything
#      ./tools/secrets.sh status          redacted overview
#      ./tools/secrets.sh get KEY         print one value
#      ./tools/secrets.sh has KEY         exit 0 if set and non-empty
#      ./tools/secrets.sh require KEY..   fail unless every key is set
#      ./tools/secrets.sh set KEY         store a value read from stdin
#      ./tools/secrets.sh run -- cmd      run cmd with all values exported
#      ./tools/secrets.sh migrate         import the old scattered files
#      ./tools/secrets.sh push            upload the CI secrets via gh
#
#  Exit codes: 0 ok, 1 error, 2 usage, 3 missing/empty value.
# -----------------------------------------------------------------------------
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

TEMPLATE="$here/secrets.env.template"
SECRETS_DIR="${RD_SECRETS_DIR:-$root/secrets}"
SECRETS_FILE="$SECRETS_DIR/secrets.env"
KEYSTORE_DIR="$SECRETS_DIR/keystore"

if command -v python3 >/dev/null 2>&1; then PY=python3
elif command -v python >/dev/null 2>&1; then PY=python
else PY=""; fi

die()  { printf 'secrets: %s\n' "$*" >&2; exit 1; }
warn() { printf 'secrets: warning: %s\n' "$*" >&2; }
note() { printf 'secrets: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
#  schema: KEY<TAB>flags, read from the template's "# @..." annotations
# ---------------------------------------------------------------------------
schema() {
  [ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^# @/) {
        f = line
        sub(/^# @/, "", f)
        if (f ~ /^required-if /) sub(/^required-if /, "reqif:", f)
        flag = (flag == "" ? f : flag "," f)
        next
      }
      if (line ~ /^[A-Z][A-Z0-9_]*=/) {
        key = line
        sub(/=.*/, "", key)
        print key "\t" (flag == "" ? "optional" : flag)
        flag = ""
        next
      }
      if (line ~ /^[^#[:space:]]/) flag = ""
    }
  ' "$TEMPLATE"
}

schema_flags() {
  local want="$1" key flags
  while IFS=$'\t' read -r key flags; do
    [ "$key" = "$want" ] && { printf '%s' "$flags"; return 0; }
  done < <(schema)
  return 1
}

flag() { case ",$1," in *",$2,"*) return 0 ;; esac; return 1; }

# Cygwin/MSYS on NTFS usually ignores chmod, so a mode check there is noise.
# Probe once: create a file, try to make it 600, read it back.
FS_MODE_SUPPORT=""
fs_honors_mode() {
  if [ -z "$FS_MODE_SUPPORT" ]; then
    local t m
    t="$(mktemp 2>/dev/null)" || { FS_MODE_SUPPORT=no; return 1; }
    chmod 600 "$t" 2>/dev/null || true
    m="$(stat -c '%a' "$t" 2>/dev/null || echo '')"
    rm -f "$t" 2>/dev/null || true
    [ "$m" = "600" ] && FS_MODE_SUPPORT=yes || FS_MODE_SUPPORT=no
  fi
  [ "$FS_MODE_SUPPORT" = yes ]
}

# ---------------------------------------------------------------------------
#  parse: read the store into memory as parallel arrays
# ---------------------------------------------------------------------------
KEYS=()
VALS=()

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

read_store() {
  [ -f "$SECRETS_FILE" ] || die "no secret store at $SECRETS_FILE - run: $0 init"
  local line key val ln=0
  KEYS=()
  VALS=()
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    line="$(trim "${line%$'\r'}")"
    [ -z "$line" ] && continue
    case "$line" in '#'*) continue ;; esac
    if [[ $line =~ ^([A-Z][A-Z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
    else
      die "$SECRETS_FILE:$ln: expected KEY=value or a comment, got: ${line:0:40}"
    fi
    val="$(trim "$val")"
    if [ "${#val}" -ge 2 ]; then
      case "$val" in
        \"*\") val="${val:1:${#val}-2}" ;;
        \'*\') val="${val:1:${#val}-2}" ;;
      esac
    fi
    case "$val" in
      *$'\t'*) die "$SECRETS_FILE:$ln: $key contains a tab, which the format forbids" ;;
    esac
    KEYS+=("$key")
    VALS+=("$val")
  done < "$SECRETS_FILE"
}

lookup() {
  local want="$1" i
  for i in "${!KEYS[@]}"; do
    if [ "${KEYS[$i]}" = "$want" ]; then printf '%s' "${VALS[$i]}"; return 0; fi
  done
  return 1
}

# sha of a value, for "did the import land correctly" checks that print nothing
value_sha() { printf '%s' "$1" | sha256sum | cut -c1-12; }

# write_key KEY  (value on stdin) - rewrites one line, keeps every comment
write_key() {
  [ -n "$PY" ] || die "python is required to rewrite the store"
  local key="$1"
  "$PY" -c '
import os, re, sys
key, path = sys.argv[1], sys.argv[2]
val = sys.stdin.read()
while val.endswith("\n") or val.endswith("\r"):
    val = val[:-1]
if "\n" in val or "\r" in val:
    sys.exit("secrets: value for %s contains a newline" % key)
with open(path, encoding="utf-8", newline="") as fh:
    text = fh.read()
pattern = re.compile(r"^" + re.escape(key) + r"[ \t]*=[^\r\n]*", re.M)
if not pattern.search(text):
    text = text.rstrip("\n") + "\n" + key + "=" + val + "\n"
else:
    text = pattern.sub(lambda m: key + "=" + val, text, count=1)
with open(path, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(text)
try:
    os.chmod(path, 0o600)
except OSError:
    pass
' "$key" "$SECRETS_FILE"
}

# ---------------------------------------------------------------------------
#  commands
# ---------------------------------------------------------------------------
cmd_init() {
  local force=0
  [ "${1:-}" = "--force" ] && force=1
  [ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"
  mkdir -p "$SECRETS_DIR"
  chmod 700 "$SECRETS_DIR" 2>/dev/null || true
  if [ -e "$SECRETS_FILE" ] && [ "$force" != 1 ]; then
    die "$SECRETS_FILE already exists (use --force to overwrite; that destroys every value)"
  fi
  cp "$TEMPLATE" "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE" 2>/dev/null || true
  if fs_honors_mode; then
    note "created $SECRETS_FILE (mode 600)"
  else
    note "created $SECRETS_FILE (this filesystem ignores POSIX modes; access is"
    note "controlled by the gitignore and by the file's NTFS ACLs instead)"
  fi
  note "fill it in, then run: $0 check"
}

cmd_edit() {
  [ -f "$SECRETS_FILE" ] || cmd_init
  "${EDITOR:-${VISUAL:-vi}}" "$SECRETS_FILE"
}

cmd_path() { printf '%s\n' "$SECRETS_FILE"; }

cmd_get() {
  [ $# -eq 1 ] || die "usage: $0 get KEY"
  read_store
  local v
  v="$(lookup "$1")" || die "unknown key: $1 (not in $TEMPLATE)"
  [ -n "$v" ] || { note "$1 is empty in $SECRETS_FILE"; exit 3; }
  printf '%s' "$v"
}

cmd_has() {
  [ $# -eq 1 ] || die "usage: $0 has KEY"
  read_store
  local v
  v="$(lookup "$1")" || return 1
  [ -n "$v" ]
}

cmd_set() {
  [ $# -eq 1 ] || die "usage: printf %s VALUE | $0 set KEY"
  [ -t 0 ] && die "the value must arrive on stdin, not a terminal (it would land in history)"
  [ -f "$SECRETS_FILE" ] || cmd_init
  read_store
  schema_flags "$1" >/dev/null || die "unknown key: $1 (not in $TEMPLATE)"
  local val
  val="$(cat)"
  val="$(trim "${val%$'\r'}")"
  printf '%s' "$val" | write_key "$1"
  note "set $1 (${#val} chars, sha $(value_sha "$val"))"
}

cmd_require() {
  [ $# -gt 0 ] || die "usage: $0 require KEY..."
  read_store
  local missing=() k v
  for k in "$@"; do
    v="$(lookup "$k" || true)"
    [ -n "$v" ] || missing+=("$k")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "not configured: ${missing[*]} - set them in $SECRETS_FILE"
  fi
}

cmd_fingerprint() {
  [ $# -eq 1 ] || die "usage: $0 fingerprint KEY"
  read_store
  local v
  v="$(lookup "$1")" || die "unknown key: $1"
  if [ -z "$v" ]; then printf '%s\tempty\n' "$1"; else
    printf '%s\t%s\t%d chars\n' "$1" "$(value_sha "$v")" "${#v}"
  fi
}

# Current TOTP code for RD_2FA_SECRET, so a baked-in 2FA can be checked without
# opening the phone. The secret travels on stdin, never on the command line.
cmd_totp() {
  read_store
  local sec
  sec="$(lookup RD_2FA_SECRET || true)"
  [ -n "$sec" ] || die "RD_2FA_SECRET is empty in $SECRETS_FILE"
  printf '%s' "$sec" | "$PY" -c '
import base64, hashlib, hmac, struct, sys, time
s = sys.stdin.read().strip().upper()
s += "=" * (-len(s) % 8)
key = base64.b32decode(s)
step = 30
ctr = int(time.time()) // step
d = hmac.new(key, struct.pack(">Q", ctr), hashlib.sha1).digest()
o = d[-1] & 0x0F
code = (struct.unpack(">I", d[o:o + 4])[0] & 0x7FFFFFFF) % 1000000
print("%06d  (%ds left)" % (code, step - int(time.time()) % step))
'
}

# The otpauth:// URL an authenticator app expects. Prints the secret by design.
cmd_totp_uri() {
  read_store
  local sec
  sec="$(lookup RD_2FA_SECRET || true)"
  [ -n "$sec" ] || die "RD_2FA_SECRET is empty in $SECRETS_FILE"
  printf 'otpauth://totp/RustDesk:rustdesk?secret=%s&issuer=RustDesk&algorithm=SHA1&digits=6&period=30\n' "$sec"
}

cmd_status() {
  read_store
  local key flags v state len
  printf '%-28s %-8s %5s  %s\n' KEY STATE LEN FLAGS
  printf '%-28s %-8s %5s  %s\n' --- ----- --- -----
  while IFS=$'\t' read -r key flags; do
    v="$(lookup "$key" || true)"
    if [ -n "$v" ]; then state=SET; len="${#v}"; else state=empty; len=-; fi
    printf '%-28s %-8s %5s  %s\n' "$key" "$state" "$len" "$flags"
  done < <(schema)
}

cmd_check() {
  local quiet=0
  [ "${1:-}" = "-q" ] && quiet=1
  local errors=0 warnings=0

  [ -f "$SECRETS_FILE" ] || die "no secret store at $SECRETS_FILE - run: $0 init"

  # the store must not be tracked, and must be ignored (only meaningful when it
  # lives inside this repo; RD_SECRETS_DIR may point somewhere else entirely)
  if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    case "$SECRETS_FILE" in
      "$root"/*)
        if git -C "$root" ls-files --error-unmatch "${SECRETS_FILE#$root/}" >/dev/null 2>&1; then
          printf 'secrets: ERROR %s is TRACKED by git - remove it from the index now\n' \
            "${SECRETS_FILE#$root/}" >&2
          errors=$((errors + 1))
        fi
        if ! git -C "$root" check-ignore -q "${SECRETS_FILE#$root/}"; then
          printf 'secrets: ERROR %s is not gitignored\n' "${SECRETS_FILE#$root/}" >&2
          errors=$((errors + 1))
        fi
        ;;
    esac
  fi

  # permissions: 600 where the filesystem supports it
  local mode
  mode="$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || echo '')"
  if ! fs_honors_mode; then
    if [ "$quiet" = 0 ]; then
      printf 'secrets: NOTE  this filesystem ignores POSIX modes; relying on the gitignore\n' >&2
    fi
  elif [ -n "$mode" ] && [ "$mode" != "600" ]; then
    printf 'secrets: WARN  mode is %s, expected 600 - run: chmod 600 %s\n' \
      "$mode" "${SECRETS_FILE#$root/}" >&2
    warnings=$((warnings + 1))
  fi

  read_store || exit 1

  # duplicates
  local i j
  for i in "${!KEYS[@]}"; do
    for j in "${!KEYS[@]}"; do
      [ "$i" -lt "$j" ] || continue
      if [ "${KEYS[$i]}" = "${KEYS[$j]}" ]; then
        printf 'secrets: ERROR duplicate key %s (last one wins)\n' "${KEYS[$i]}" >&2
        errors=$((errors + 1))
      fi
    done
  done

  # unknown keys
  for i in "${!KEYS[@]}"; do
    if ! schema_flags "${KEYS[$i]}" >/dev/null; then
      printf 'secrets: WARN  unknown key %s (ignored by the build)\n' "${KEYS[$i]}" >&2
      warnings=$((warnings + 1))
    fi
  done

  # required / required-if
  local key flags v other
  while IFS=$'\t' read -r key flags; do
    v="$(lookup "$key" || true)"
    if flag "$flags" required && [ -z "$v" ]; then
      printf 'secrets: ERROR %s is required and empty\n' "$key" >&2
      errors=$((errors + 1))
    fi
    if flag "$flags" "reqif:ARTIFACTS_REPO" && [ -n "$(lookup ARTIFACTS_REPO || true)" ] && [ -z "$v" ]; then
      printf 'secrets: ERROR %s is required because ARTIFACTS_REPO is set\n' "$key" >&2
      errors=$((errors + 1))
    fi
    if flag "$flags" "reqif:ANDROID_KEYSTORE_B64" && [ -n "$(lookup ANDROID_KEYSTORE_B64 || true)" ] && [ -z "$v" ]; then
      printf 'secrets: ERROR %s is required because ANDROID_KEYSTORE_B64 is set\n' "$key" >&2
      errors=$((errors + 1))
    fi
  done < <(schema)

  # value sanity, without ever echoing a value
  local token
  token="$(lookup GH_TOKEN || true)"
  if [ -n "$token" ]; then
    case "$token" in
      ghp_*|gho_*|ghu_*|ghs_*|github_pat_*) : ;;
      *) printf 'secrets: WARN  GH_TOKEN does not look like a GitHub token\n' >&2
         warnings=$((warnings + 1)) ;;
    esac
  fi

  local pass
  pass="$(lookup ARTIFACTS_PASSPHRASE || true)"
  if [ -n "$pass" ]; then
    if [ "${#pass}" -lt 32 ]; then
      printf 'secrets: WARN  ARTIFACTS_PASSPHRASE is only %d chars, use 64+\n' "${#pass}" >&2
      warnings=$((warnings + 1))
    fi
    case "$pass" in
      *[[:space:]]*) printf 'secrets: WARN  ARTIFACTS_PASSPHRASE contains whitespace\n' >&2
                     warnings=$((warnings + 1)) ;;
    esac
  fi

  # baked-in access control: mirror the patcher's validators so a bad value fails here
  # instead of 40 minutes into a build.
  local pw totp
  pw="$(lookup RD_PERMANENT_PASSWORD || true)"
  if [ -n "$pw" ]; then
    if [ "${#pw}" -lt 6 ] || [ "${#pw}" -gt 64 ]; then
      printf 'secrets: ERROR RD_PERMANENT_PASSWORD must be 6-64 characters (is %d)\n' "${#pw}" >&2
      errors=$((errors + 1))
    fi
    case "$pw" in
      *[\"\'\\]*|*$'\t'*)
        printf 'secrets: ERROR RD_PERMANENT_PASSWORD must not contain quotes, backslash or tab\n' >&2
        errors=$((errors + 1)) ;;
    esac
  fi
  totp="$(lookup RD_2FA_SECRET || true)"
  if [ -n "$totp" ]; then
    case "$totp" in
      *[!A-Z2-7]*)
        printf 'secrets: ERROR RD_2FA_SECRET must be base32: A-Z and 2-7 only\n' >&2
        errors=$((errors + 1)) ;;
      *)
        if [ "${#totp}" -lt 16 ]; then
          printf 'secrets: ERROR RD_2FA_SECRET is too short (%d, need 16+)\n' "${#totp}" >&2
          errors=$((errors + 1))
        fi ;;
    esac
  fi

  local b64
  b64="$(lookup ANDROID_KEYSTORE_B64 || true)"
  if [ -n "$b64" ]; then
    local magic
    magic="$(printf '%s' "$b64" | base64 -d 2>/dev/null | od -An -tx1 -N4 2>/dev/null | tr -d ' \n' || true)"
    if [ -z "$magic" ]; then
      printf 'secrets: ERROR ANDROID_KEYSTORE_B64 is not valid base64\n' >&2
      errors=$((errors + 1))
    elif [ "${magic:0:8}" != "feedfeed" ] && [ "${magic:0:2}" != "30" ]; then
      printf 'secrets: WARN  ANDROID_KEYSTORE_B64 does not start like a JKS/PKCS12 keystore\n' >&2
      warnings=$((warnings + 1))
    fi
  else
    local ks
    ks="$(lookup ANDROID_KEYSTORE_FILE || true)"
    if [ -n "$ks" ]; then
      case "$ks" in /*) ;; *) ks="$root/$ks" ;; esac
      if [ -f "$ks" ]; then
        printf 'secrets: NOTE  %s exists but ANDROID_KEYSTORE_B64 is empty - run: %s keystore-encode\n' \
          "${ks#$root/}" "$0" >&2
      fi
    fi
  fi

  # cross-check the artifacts settings the way the workflow does
  if [ -n "$(lookup ARTIFACTS_REPO || true)" ] && [ -z "$(lookup ARTIFACTS_TOKEN || true)" ]; then
    printf 'secrets: ERROR ARTIFACTS_REPO is set but ARTIFACTS_TOKEN is empty\n' >&2
    errors=$((errors + 1))
  fi

  if [ "$quiet" = 0 ]; then
    local set=0
    for i in "${!VALS[@]}"; do [ -n "${VALS[$i]}" ] && set=$((set + 1)); done
    printf 'secrets: %d/%d keys set, %d error(s), %d warning(s) - %s\n' \
      "$set" "${#KEYS[@]}" "$errors" "$warnings" "${SECRETS_FILE#$root/}" >&2
  fi
  [ "$errors" -eq 0 ] || exit 1
}

cmd_run() {
  [ "${1:-}" = "--" ] && shift
  [ $# -gt 0 ] || die "usage: $0 run -- <command> [args...]"
  read_store
  local -a assigns=()
  local i
  for i in "${!KEYS[@]}"; do
    [ -n "${VALS[$i]}" ] || continue
    assigns+=("${KEYS[$i]}=${VALS[$i]}")
  done
  exec env "${assigns[@]}" "$@"
}

cmd_keystore_encode() {
  read_store
  local ks="${1:-}"
  [ -n "$ks" ] || ks="$(lookup ANDROID_KEYSTORE_FILE || true)"
  [ -n "$ks" ] || ks="keystore/release.keystore"
  case "$ks" in
    /*) ;;
    secrets/*) ks="$root/$ks" ;;
    *) ks="$SECRETS_DIR/$ks" ;;
  esac
  [ -f "$ks" ] || die "keystore not found: $ks"
  local b64
  b64="$(base64 -w0 "$ks" | tr -d '\r\n')"
  [ -n "$b64" ] || die "base64 of $ks came out empty"
  printf '%s' "$b64" | write_key ANDROID_KEYSTORE_B64
  note "ANDROID_KEYSTORE_B64 refreshed from ${ks#$root/} (${#b64} chars, sha $(value_sha "$b64"))"
}

# ---------------------------------------------------------------------------
#  migrate: pull the old scattered files into the store
# ---------------------------------------------------------------------------
shred_file() {
  [ -f "$1" ] || return 0
  [ -n "$PY" ] || { rm -f "$1"; return 0; }
  "$PY" -c '
import os, sys
p = sys.argv[1]
try:
    n = os.path.getsize(p)
    with open(p, "r+b") as fh:
        fh.write(b"\0" * n)
        fh.flush()
        os.fsync(fh.fileno())
    os.remove(p)
except OSError as exc:
    sys.stderr.write("secrets: could not shred %s: %s\n" % (p, exc))
' "$1"
}

import_value() {
  # import_value KEY VALUE SOURCE
  local key="$1" val="$2" src="$3"
  val="$(trim "${val%$'\r'}")"
  [ -n "$val" ] || { note "skip $src (empty)"; return 0; }
  local cur
  cur="$(lookup "$key" || true)"
  if [ -n "$cur" ]; then
    note "keep existing $key (from $SECRETS_FILE), not overwriting from $src"
    return 0
  fi
  printf '%s' "$val" | write_key "$key"
  KEYS+=("$key"); VALS+=("$val")
  local want got
  want="$(value_sha "$val")"
  read_store
  got="$(value_sha "$(lookup "$key" || true)")"
  if [ "$want" != "$got" ]; then
    die "import of $key from $src did not round-trip (expected $want, stored $got)"
  fi
  note "imported $key from $src (sha $want, ${#val} chars)"
}

cmd_migrate() {
  local shred=0
  for a in "$@"; do [ "$a" = "--shred-legacy" ] && shred=1; done
  [ -f "$SECRETS_FILE" ] || cmd_init
  read_store

  local imported=0

  if [ -f "$root/ght.txt" ]; then
    import_value GH_TOKEN "$(tr -d '\r\n' < "$root/ght.txt")" ght.txt
    imported=$((imported + 1))
  fi
  if [ -f "$root/ARTIFACTS_PASSPHRASE.txt" ]; then
    import_value ARTIFACTS_PASSPHRASE \
      "$(tr -d '\r\n' < "$root/ARTIFACTS_PASSPHRASE.txt")" ARTIFACTS_PASSPHRASE.txt
    imported=$((imported + 1))
  fi
  if [ -f "$here/.keystore.env" ]; then
    local k v
    while IFS='=' read -r k v; do
      case "$k" in
        ''|'#'*) continue ;;
        KEYSTORE_PASSWORD) import_value ANDROID_KEYSTORE_PASSWORD "$v" tools/.keystore.env ;;
        KEY_PASSWORD)      import_value ANDROID_KEY_PASSWORD "$v" tools/.keystore.env ;;
        KEY_ALIAS)         import_value ANDROID_KEY_ALIAS "$v" tools/.keystore.env ;;
      esac
    done < "$here/.keystore.env"
    imported=$((imported + 1))
  fi

  # the keystore itself moves into the store
  local ks_src=""
  for cand in "$root/release.keystore" "$root/app.keystore" "$root/key.jks"; do
    [ -f "$cand" ] && { ks_src="$cand"; break; }
  done
  if [ -n "$ks_src" ]; then
    mkdir -p "$KEYSTORE_DIR"
    chmod 700 "$KEYSTORE_DIR" 2>/dev/null || true
    local ks_dst="$KEYSTORE_DIR/release.keystore"
    if [ -f "$ks_dst" ] && ! cmp -s "$ks_src" "$ks_dst"; then
      die "$ks_dst already exists and differs from $ks_src - refusing to overwrite a signing key"
    fi
    cp "$ks_src" "$ks_dst"
    chmod 600 "$ks_dst" 2>/dev/null || true
    if cmp -s "$ks_src" "$ks_dst"; then
      note "keystore copied to ${ks_dst#$root/} (sha $(sha256sum "$ks_dst" | cut -c1-12))"
      imported=$((imported + 1))
    else
      die "keystore copy did not verify"
    fi
  fi
  [ -f "$KEYSTORE_DIR/release.keystore" ] && cmd_keystore_encode

  # stale base64 copy at the root
  if [ -f "$root/release.keystore.b64" ]; then
    note "root release.keystore.b64 is now redundant (the store holds the encoding)"
  fi

  read_store
  if [ "$imported" -eq 0 ]; then
    note "nothing to migrate"
  fi

  if [ "$shred" = 1 ]; then
    local f
    for f in "$root/ght.txt" "$root/ARTIFACTS_PASSPHRASE.txt" \
             "$here/.keystore.env" "$root/release.keystore" "$root/release.keystore.b64"; do
      [ -f "$f" ] || continue
      shred_file "$f" && note "shredded ${f#$root/} (value now lives only in the store)"
    done
  else
    note "legacy files left in place - re-run with --shred-legacy to wipe them"
  fi

  note "done; verify with: $0 check"
}

# ---------------------------------------------------------------------------
#  push: upload the CI secrets through the gh CLI (optional convenience)
# ---------------------------------------------------------------------------
cmd_push() {
  local repo=""
  local -a only=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ $# -ge 2 ] || die "--repo needs owner/name"; repo="$2"; shift 2 ;;
      *) only+=("$1"); shift ;;
    esac
  done
  read_store
  command -v gh >/dev/null 2>&1 || die "gh is not installed - add the secrets in the web UI instead (Settings -> Secrets and variables -> Actions)"
  if [ -z "$repo" ]; then
    local owner
    owner="$(lookup GH_OWNER || true)"
    repo="$owner/$(lookup GH_REPO || true)"
  fi
  [ -n "$repo" ] && [ "$repo" != "/" ] || die "cannot work out the target repo; pass --repo owner/name"

  local key flags v pushed=0 skipped=0
  while IFS=$'\t' read -r key flags; do
    if [ ${#only[@]} -gt 0 ]; then
      local wanted=0 o
      for o in "${only[@]}"; do [ "$o" = "$key" ] && wanted=1; done
      [ "$wanted" = 1 ] || continue
    fi
    if flag "$flags" local; then skipped=$((skipped + 1)); continue; fi
    v="$(lookup "$key" || true)"
    [ -n "$v" ] || { skipped=$((skipped + 1)); continue; }
    # value goes in on stdin: never argv, never the log
    printf '%s' "$v" | "$here/ght.sh" secret set "$key" --repo "$repo" --app actions
    pushed=$((pushed + 1))
  done < <(schema)
  note "pushed $pushed secret(s) to $repo, skipped $skipped (empty or local-only)"
}

usage() {
  cat >&2 <<'USAGE'
secrets.sh - the single door to every local credential.

  init [--force]        create secrets/secrets.env from tools/secrets.env.template
  edit                  open the store in $EDITOR
  path                  print the store path
  check [-q]            validate: format, required keys, gitignore, values
  status                redacted table: KEY / set|empty / length / flags
  get KEY               print one value (for command substitution)
  has KEY               exit 0 if the key is set and non-empty
  require KEY...        exit non-zero unless every key is set
  set KEY               store a value read from stdin (never from argv)
  fingerprint KEY       print sha256[:12] and length, never the value
  totp                  current 6-digit code for RD_2FA_SECRET
  totp-uri              otpauth:// URL for RD_2FA_SECRET (prints the secret)
  run -- cmd [args]     run cmd with every configured value in the environment
  migrate [--shred-legacy]
                        import ght.txt, ARTIFACTS_PASSPHRASE.txt, keystore env
  keystore-encode [F]   refresh ANDROID_KEYSTORE_B64 from the keystore file
  push [--repo R] [K..] upload the CI secrets through gh

Exit codes: 0 ok, 1 error, 2 usage, 3 missing/empty value.
USAGE
  exit 2
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  init)            cmd_init "$@" ;;
  edit)            cmd_edit ;;
  path)            cmd_path ;;
  get)             cmd_get "$@" ;;
  has)             cmd_has "$@" ;;
  set)             cmd_set "$@" ;;
  require)         cmd_require "$@" ;;
  fingerprint)     cmd_fingerprint "$@" ;;
  totp)            cmd_totp ;;
  totp-uri)        cmd_totp_uri ;;
  status)          cmd_status ;;
  check)           cmd_check "$@" ;;
  run)             cmd_run "$@" ;;
  migrate)         cmd_migrate "$@" ;;
  keystore-encode) cmd_keystore_encode "$@" ;;
  push)            cmd_push "$@" ;;
  ""|-h|--help|help) usage ;;
  *) printf 'secrets: unknown command: %s\n\n' "$cmd" >&2; usage ;;
esac
