# RustDesk custom build (Windows + Android)

Builds a customized RustDesk from [`alonginwind/rustdesk`](https://github.com/alonginwind/rustdesk)
entirely on GitHub Actions, with **all outbound TCP tunnelled through the Baidu front proxy**
(`cloudnproxy.baidu.com`).

No large repo is ever cloned locally: this repo holds only the patcher, the proxy module and the
workflow. CI checks out the upstream source at a pinned commit, patches it, and builds.

## What gets changed

| Area | Change |
|---|---|
| Android package | `applicationId` → `im.logi.rd` (namespace/JNI untouched, so nothing can break) |
| App name | `远程协助` — `strings.xml` **and** `AndroidManifest.xml`, which is where the launcher label actually comes from |
| Server | injected at build time from dispatch inputs / secrets; placeholders otherwise. Always overridable at runtime via **Settings → ID/Relay Server** |
| Official domains | every `rustdesk.com` in `src/`, `libs/`, `flutter/lib/`, `flutter/android/` rewritten; CI fails if any survive |
| Public-server heuristics | `is_public()` / `using_public_server()` forced to `false` (also removes the 30 FPS cap from [rustdesk-api#403](https://github.com/lejianwen/rustdesk-api/issues/403)) |
| Networking | see the table below; `force-always-relay=Y` and `baidu-proxy=Y` on both platforms |
| Access control | optional fixed password + baked TOTP secret (2FA); see **Access control** below |
| Backdoor | any baked-in `HARD_SETTINGS` maintenance password is stripped (defensive) |

### Default network options

Set through `DEFAULT_SETTINGS`, so they are also the last-resort default for an install that has
not saved its own value, and the UI switches reflect them on a fresh install.

| Option | Windows | Android | Meaning |
|---|---|---|---|
| `disable-udp` | `Y` | `Y` | never use UDP |
| `allow-websocket` | `Y` | `Y` | rendezvous and sessions over WebSocket |
| `enable-tcp-punch` | — | `N` | no TCP hole punching |
| `enable-udp-punch` | — | `N` | no UDP hole punching |
| `enable-ipv6-punch` | — | `N` | no IPv6 P2P |
| `enable-webrtc` | — | `N` | no WebRTC P2P |
| `enable-check-update` | — | `N` | no update check at startup (`DEFAULT_LOCAL_SETTINGS`) |

Note the key names: it is `enable-ipv6-punch` and `enable-webrtc`, not `…-p2p`. They are defined in
`libs/base/src/config/keys.rs`, and the `enable-` prefix means *true unless `N`*, which is why
disabling them writes `N`.

### Access control

Both values are optional; leave them empty and the build keeps stock behaviour.

| Field | Secret | Effect |
|---|---|---|
| `permanent_password` | `RD_PERMANENT_PASSWORD` | baked as the preset password, and flips `verification-method=use-permanent-password` + `approve-mode=password`, i.e. only that password works and no click approval is offered |
| `totp_secret` | `RD_2FA_SECRET` | base32 TOTP secret, enforced on every incoming connection |

The password goes into `HARD_SETTINGS`, which is the only map
`Config::get_preset_password_storage_and_salt()` reads; the plaintext form is the fork's supported
legacy form and is migrated to salted storage on first use. `disable-change-permanent-password` is
deliberately **not** set, so the in-app password can still be changed as an escape hatch.

The 2FA stored form cannot be precomputed — it is secretbox-encrypted with each device's uuid — so
the raw base32 secret is compiled in and used directly, and the UI's QR code shows the same secret.
Check it from the shell with `./tools/secrets.sh totp`; get the URL for your authenticator with
`./tools/secrets.sh totp-uri`.

> Both are **in the binary**. Anyone who has the APK can extract them; that is inherent to a baked
> password, not a bug. Keep the artifacts private (see below).


## How the proxy is wired

RustDesk already routes **every** TCP connection, the rendezvous registration and all `reqwest`
HTTP calls through one function: `Config::get_socks()`. It cannot, however, emit the fake `Host:`
header that the Baidu proxy demands. So instead of touching the socket layer:

```
RustDesk ──standard CONNECT──► 127.0.0.1:<ephemeral> ──CONNECT + fake Host + X-T5-Auth──►
                                                                  cloudnproxy.baidu.com:443 ──► target
```

* `libs/hbb_common/src/baidu_tunnel.rs` — the local shim. Lazily started on first `get_socks()`
  call, binds `127.0.0.1:0`, handles both `CONNECT host:port` and absolute-URI plain-HTTP
  requests, resolves the proxy hostname through DNS (never a hard-coded IP), 60 s DNS cache.
* `Config::get_socks()` — returns `http://127.0.0.1:<port>` while the tunnel is enabled.
* `Config::get_network_type()` — reports `ProxySocks`, which is what makes the rendezvous switch
  to TCP and forces sessions onto the relay.

The wire format is taken from [`fscarmen/cfnat`](https://github.com/fscarmen/cfnat/blob/main/cfnat.go):

```
CONNECT <target> HTTP/1.1
Host: sptest.baidu.com
X-T5-Auth: 482857715
User-Agent: okhttp/3.11.0 Dalvik/2.1.0 (...) baiduboxapp/11.0.5.12 (Baidu; P1 11)
Proxy-Connection: keep-alive
```

## Local secrets — one file, one door

Every credential lives in **one** gitignored file, `secrets/secrets.env`. Nothing else in the repo
holds a secret, and no script knows a path: `tools/ght.sh`, `tools/askpass.sh` and
`tools/bootstrap.sh` all go through `tools/secrets.sh`, which is the only reader.

```bash
./tools/secrets.sh init        # secrets/secrets.env from tools/secrets.env.template
$EDITOR secrets/secrets.env    # fill in the values
./tools/secrets.sh check       # validate: format, required keys, gitignore, value shapes
./tools/secrets.sh status      # KEY / set|empty / length / flags — never a value
```

The committed template `tools/secrets.env.template` is the documentation: every key, why it
exists, how to get it, and the annotation that drives validation (`@required`, `@optional`,
`@required-if KEY`, `@derived`, `@local`). CI fails if a tracked file under `secrets/` appears or
if the template ever carries a value for a secret key.

Values are printed only by `get` (for command substitution) and `run` (into a child environment).
Everything else reports state and length. The store is parsed as data, never sourced, so a stray
line cannot execute anything.

```bash
TOKEN="$(./tools/secrets.sh get GH_TOKEN)"          # one value
./tools/secrets.sh run -- gh pr list                # whole environment
printf '%s' "$new" | ./tools/secrets.sh set RD_PUB_KEY   # value via stdin, never argv
./tools/secrets.sh fingerprint RD_PUB_KEY           # sha256[:12] + length, to compare without exposing
./tools/secrets.sh push                             # upload the CI secrets through gh
```

`secrets/` holds the Android signing keystore too (`secrets/keystore/release.keystore`).
**Back it up somewhere outside the repo** — losing it means future APKs cannot upgrade the
installed app.

## Build

```bash
./tools/bootstrap.sh            # creates a PUBLIC repo, pushes, generates keystore + secrets
```

The script refuses to commit if anything matching `secrets/`, `ght.txt`, `*.keystore`, `*.jks`,
`keystore.env` or `key.properties` is staged, and then probes the remote to confirm none of them
was published.

Then set the `RD_*` secrets (see below) and either push to `main` or run
**Actions → Build custom RustDesk → Run workflow**.

A new run cancels the previous one on the same branch (concurrency group `build-<ref>`), so a
push never leaves two builds racing. Tick `allow_parallel` on a manual run when you deliberately
want several builds side by side.

Artifacts: `rustdesk-1.5.3-arm64-v8a.apk` and `rustdesk-1.5.3-windows-x64.zip`. Where they land
depends on the `ARTIFACTS_*` settings — see below.

## Keeping build output private

GitHub has **no per-user permission on workflow artifacts**. The docs are explicit: *"People who
are signed into GitHub and have read access to a repository can download workflow artifacts."* On
a public repo, read access means everyone, so an artifact uploaded here **cannot** be made
private in place. Three options, in order of preference:

| Option | Setup | Who can download |
|---|---|---|
| **1. Private companion repo** | `ARTIFACTS_REPO` + `ARTIFACTS_TOKEN` | only accounts with read access to that private repo — i.e. you |
| **2. Encrypted artifact** | `ARTIFACTS_PASSPHRASE` only | anyone can fetch the blob, but only you can decrypt it |
| 3. Nothing configured | — | anyone with a GitHub account; auto-deleted after 1 day |

Nothing is ever attached to *this* repo's releases — the old `release` job is gone and the
workflow only has `contents: read`.

**Option 1 (recommended).** Create an empty **private** repo, e.g. `you/rustdesk-artifacts`, then
create a fine-grained PAT scoped to it with **Contents: Read and write**, and store both as
secrets here:

```bash
# Settings -> Secrets and variables -> Actions -> New repository secret
ARTIFACTS_REPO   = you/rustdesk-artifacts
ARTIFACTS_TOKEN  = github_pat_...
```

Each build then appears as a release tagged `build-<run_number>` in that private repo. `gh` is
preinstalled on the runners, so nothing else is needed.

**Option 2 (no second repo).** Store a long random passphrase instead:

```bash
ARTIFACTS_PASSPHRASE = <64+ random chars>
```

The workflow runs `openssl enc -aes-256-cbc -pbkdf2 -md sha256 -salt` before upload, keeps it 3
days, and prints the decrypt command in the log. Download and run:

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -md sha256 -in rustdesk-1.5.3-windows-x64.zip.enc \
                                                -out rustdesk-1.5.3-windows-x64.zip
```

Keep the passphrase in the central store (`ARTIFACTS_PASSPHRASE` in `secrets/secrets.env`) — it is
gitignored, and losing it means the artifacts are unrecoverable. Any printable ASCII with no
spaces or quotes works; the workflow passes it via the environment, never on a command line.

The blob is still publicly fetchable — it is just useless without the passphrase. Use option 1 if
"only I can download" must be literally true.

> The third option is a convenience for a first smoke test. Never leave it in place: a configured
> build embeds your server address and public key.


## Configuration — nothing real is ever committed

This repo is **public** and contains placeholders only. Real values are injected at build time
with this precedence:

```
workflow_dispatch input  >  repository secret  >  repository variable  >  placeholder
```

| Field | Input | Secret / Variable | Placeholder |
|---|---|---|---|
| Android package | `app_id` | `RD_APP_ID` | `im.logi.rd` |
| Display name | `app_name` | `RD_APP_NAME` | `远程协助` |
| ID server | `id_server` | `RD_ID_SERVER` | `rd.example.com` |
| Relay server | `relay_server` | `RD_RELAY_SERVER` | *(none)* |
| API server | `api_server` | `RD_API_SERVER` | `https://<site_domain>` |
| Public key | `pub_key` | `RD_PUB_KEY` | *(empty)* |
| Domain replacement | `site_domain` | `RD_SITE_DOMAIN` | `rd.example.com` |
| Preset password | — | `RD_PERMANENT_PASSWORD` | *(empty)* |
| 2FA TOTP secret | — | `RD_2FA_SECRET` | *(empty)* |

The last two are **secrets only** — there is deliberately no dispatch input for them, because
inputs are written into the public run log. `apply.py` prints `(set)`/`(empty)` for them and never
the value, and only emits `::add-mask::` inside Actions (locally that directive would print the
value).

Set them once in `secrets/secrets.env`, then upload:

```bash
$EDITOR secrets/secrets.env      # fill RD_ID_SERVER, RD_PUB_KEY, ...
./tools/secrets.sh check         # catches typos before a 40-minute build does
./tools/secrets.sh push          # gh secret set for every non-local key
```

No `gh`? Add them in **Settings → Secrets and variables → Actions → New repository secret**, using
`./tools/secrets.sh status` to see which keys are still empty.

Then run **Actions → Build custom RustDesk → Run workflow** and leave the inputs empty.

**Use secrets, not dispatch inputs, on a public repo.** Dispatch inputs are recorded in the
public run log; secrets are masked. `apply.py` also refuses values that do not match a strict
per-field pattern, so an input can never break out of the Rust string literal it is spliced into.

**Release exposure.** A configured build embeds the server address and public key, so it must
never be published publicly. The workflow therefore never creates a release in this repo; set
`ARTIFACTS_REPO` (private) or `ARTIFACTS_PASSPHRASE`, or tick `publish_release: false` to skip
publishing entirely.

Values still persist to `RustDesk2.toml` and can be changed in-app at any time:
**Settings → ID/Relay Server** (ID server, relay, API server, key).

> **Put hbbs/hbbr on port 443 with websocket enabled.** The Baidu front proxy is very likely to
> only allow `:443` targets; bare `21116`/`21117` will be rejected. The fork supports
> `allow-websocket` + 302 reverse proxying, so a single 443 entrypoint is enough.

## Turn the proxy off

Set option `baidu-proxy=N` (Settings, or `RustDesk2.toml`). The client then uses direct
networking again — useful for diagnosing whether a problem is the proxy or the server.

## Verify traffic really goes through the proxy

```bash
RUST_LOG=debug ./rustdesk
```

Look for `[baidu-tunnel] tunnel up: <target> -> cloudnproxy.baidu.com` per connection. Any
connection *not* preceded by that line means a code path bypassed `get_socks()`.

## Upgrading upstream

1. Bump `UPSTREAM_SHA` in `.github/workflows/build.yml`.
2. Run `python3 patches/apply.py <checkout> --dry-run`. It aborts with the exact anchor that moved
   instead of producing a silently wrong binary.
3. Fix the anchors, rebuild.

## Known limits

* **UDP cannot be tunnelled** over HTTP CONNECT. UDP hole punching is disabled and every session
  is forced onto the TCP relay — expect higher latency than a direct P2P connection.
* **Strict mode**: if the proxy is unreachable the client is unusable. That is deliberate; flip
  `baidu-proxy=N` to fall back.
* Windows binaries are **unsigned** → SmartScreen will warn on first run.
* `RustDeskTempTopMostWindow.exe` (the pin-window helper) is not bundled, so that one feature is
  unavailable.
* MSI installer is not produced; ship the portable zip.

## Layout

```
patches/apply.py            anchor-based, idempotent patcher (fails loudly on drift)
patches/baidu_tunnel.rs     local CONNECT shim -> Baidu front proxy
.github/actions/gen-bridge  regenerates flutter_rust_bridge glue (not committed upstream)
.github/workflows/build.yml android + windows (no public release job)
tools/secrets.sh            the only door to local credentials
tools/secrets.env.template  every key + comment, no values (committed)
secrets/                    the real store, gitignored (secrets.env + keystore/)
tools/ght.sh                gh wrapper (token from the store, never on argv)
tools/askpass.sh            GIT_ASKPASS helper (token from the store)
tools/bootstrap.sh          repo + keystore + secrets
```
