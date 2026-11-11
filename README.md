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
| App name | `远程协助` |
| Server | injected at build time from dispatch inputs / secrets; placeholders otherwise. Always overridable at runtime via **Settings → ID/Relay Server** |
| Official domains | every `rustdesk.com` in `src/`, `libs/`, `flutter/lib/`, `flutter/android/` rewritten; CI fails if any survive |
| Public-server heuristics | `is_public()` / `using_public_server()` forced to `false` (also removes the 30 FPS cap from [rustdesk-api#403](https://github.com/lejianwen/rustdesk-api/issues/403)) |
| Networking | `disable-udp=Y`, `force-always-relay=Y`, `baidu-proxy=Y` by default |
| Backdoor | any baked-in `HARD_SETTINGS` maintenance password is stripped (defensive) |

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

## Build

```bash
./tools/bootstrap.sh            # creates a PUBLIC repo, pushes, generates keystore + secrets
```

The script refuses to commit if anything matching `ght.txt`, `*.keystore`, `*.jks`,
`keystore.env` or `key.properties` is staged.

Then set the `RD_*` secrets (see below) and either push to `main` or run
**Actions → Build custom RustDesk → Run workflow**.

Artifacts: `rustdesk-1.5.3-arm64-v8a.apk`, `rustdesk-1.5.3-windows-x64.zip`, plus a GitHub Release
(unless `publish_release` is turned off).

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

Set the secrets once:

```bash
./tools/ght.sh secret set RD_ID_SERVER   --body "id.example.com"
./tools/ght.sh secret set RD_RELAY_SERVER --body "relay.example.com"
./tools/ght.sh secret set RD_API_SERVER  --body "https://api.example.com"
./tools/ght.sh secret set RD_PUB_KEY     --body "your-hbbs-public-key"
./tools/ght.sh secret set RD_SITE_DOMAIN --body "example.com"
```

Then run **Actions → Build custom RustDesk → Run workflow** and leave the inputs empty.

**Use secrets, not dispatch inputs, on a public repo.** Dispatch inputs are recorded in the
public run log; secrets are masked. `apply.py` also refuses values that do not match a strict
per-field pattern, so an input can never break out of the Rust string literal it is spliced into.

**Release exposure.** A configured build embeds the server address, so publishing it as a public
Release makes that address public. Set `publish_release: false` to keep the build in private
artifacts only.

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
.github/workflows/build.yml android + windows + release
tools/ght.sh                gh wrapper (token from ght.txt, never on argv)
tools/askpass.sh            GIT_ASKPASS helper
tools/bootstrap.sh          repo + keystore + secrets
```
