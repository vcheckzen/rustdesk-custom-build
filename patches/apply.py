#!/usr/bin/env python3
"""Anchor-based patcher for a custom RustDesk build.

Design rules
------------
* Every edit is an exact-anchor replacement. If an anchor is missing or ambiguous we abort
  loudly instead of producing a silently wrong binary.
* Idempotent: if the replacement is already in place the step is skipped, so the script can be
  re-run against an already-patched tree.
* `--dry-run` reports what would change without writing.

Usage
-----
    python3 patches/apply.py <upstream-checkout> [--dry-run]

<upstream-checkout> is the root of alonginwind/rustdesk (the dir containing `src/` and
`flutter/`), with `libs/hbb_common` checked out as a submodule.
"""

import argparse
import os
import pathlib
import re
import shutil
import sys

# Windows runners default stdout to cp1252, which cannot encode the app name. Force UTF-8.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

# --------------------------------------------------------------------------------------
# Build parameters.
#
# NOTHING real lives in this file. Values are injected at build time, in this order:
#   1. CLI flag   (--id-server ...)
#   2. environment variable (RD_ID_SERVER ...), set by the workflow from workflow_dispatch
#      inputs, repository secrets or repository variables
#   3. the placeholder below
#
# Placeholders are deliberately non-functional so a build with no configuration can never
# silently connect to somebody else's server.
# --------------------------------------------------------------------------------------
PLACEHOLDERS = {
    "app_id": "im.logi.rd",
    "app_name": "远程协助",
    "id_server": "rd.example.com",
    "relay_server": "",
    "pub_key": "",
    "api_server": "",
    "site_domain": "rd.example.com",
}

ENV_KEYS = {
    "app_id": "RD_APP_ID",
    "app_name": "RD_APP_NAME",
    "id_server": "RD_ID_SERVER",
    "relay_server": "RD_RELAY_SERVER",
    "pub_key": "RD_PUB_KEY",
    "api_server": "RD_API_SERVER",
    "site_domain": "RD_SITE_DOMAIN",
}

# These values are spliced into Rust/Dart string literals, and on a public repo the dispatch
# inputs are attacker-controllable. Validate hard, refuse anything that could break out of a
# string literal or inject code.
VALIDATORS = {
    "app_id": r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$",
    "app_name": r"^[^\"'\\\r\n]{1,64}$",
    "id_server": r"^[A-Za-z0-9.\-]{1,253}(:[0-9]{1,5})?$",
    "relay_server": r"^$|^[A-Za-z0-9.\-]{1,253}(:[0-9]{1,5})?$",
    "pub_key": r"^[A-Za-z0-9+/=]{0,128}$",
    "api_server": r"^$|^https?://[A-Za-z0-9.\-]{1,253}(:[0-9]{1,5})?(/[A-Za-z0-9._\-/]*)?$",
    "site_domain": r"^[A-Za-z0-9.\-]{1,253}$",
}

CONFIG = dict(PLACEHOLDERS)
INJECTED = []  # keys whose value came from CLI/env, not from the placeholder table


def resolve_config(cli: dict) -> None:
    """CLI > env > placeholder, with validation."""
    for key, env_key in ENV_KEYS.items():
        value = (cli.get(key) or "").strip() or os.environ.get(env_key, "").strip()
        if value:
            INJECTED.append(key)
        else:
            value = PLACEHOLDERS[key]
        if not re.match(VALIDATORS[key], value):
            raise SystemExit(
                f"[FAIL] invalid value for {key} ({env_key}): {value[:60]!r}\n"
                f"       must match {VALIDATORS[key]}"
            )
        CONFIG[key] = value

    if not CONFIG["site_domain"]:
        CONFIG["site_domain"] = PLACEHOLDERS["site_domain"]
    if not CONFIG["api_server"]:
        # Fall back to the site domain so API/audit calls never point at rustdesk.com.
        CONFIG["api_server"] = f"https://{CONFIG['site_domain']}"

    print("== effective configuration ==")
    for key in ("app_id", "app_name"):
        print(f"   {key:<13} = {CONFIG[key]}")
    # Server coordinates are never echoed: on a public repo the run log is public.
    for key in ("id_server", "relay_server", "api_server", "pub_key", "site_domain"):
        print(f"   {key:<13} = ({'set' if CONFIG[key] else 'empty'})")

    # Mask injected server coordinates so they cannot surface in a later step's log.
    for key in ("id_server", "relay_server", "api_server", "pub_key", "site_domain"):
        if key in INJECTED and CONFIG[key]:
            print(f"::add-mask::{CONFIG[key]}")



class Patcher:
    def __init__(self, root: pathlib.Path, dry_run: bool):
        self.root = root
        self.dry_run = dry_run
        self.changed = 0
        self.skipped = 0

    def path(self, rel: str) -> pathlib.Path:
        return self.root / rel

    def _read(self, rel: str) -> str:
        p = self.path(rel)
        if not p.is_file():
            raise SystemExit(f"[FAIL] missing file: {p}")
        # Normalise CRLF: Windows checkouts may have autocrlf enabled, and every anchor
        # below is written with plain \n.
        return p.read_text(encoding="utf-8").replace("\r\n", "\n")

    def _write(self, rel: str, text: str) -> None:
        if self.dry_run:
            return
        p = self.path(rel)
        p.write_text(text, encoding="utf-8", newline="")

    def sub(self, rel: str, old: str, new: str, *, optional: bool = False, expect: int = 1) -> None:
        text = self._read(rel)
        if new and new in text and old not in text:
            self.skipped += 1
            print(f"[skip] {rel}: already patched")
            return
        n = text.count(old)
        if n == 0:
            if optional:
                self.skipped += 1
                print(f"[skip] {rel}: optional anchor not present")
                return
            raise SystemExit(
                f"[FAIL] {rel}: anchor not found. Upstream changed.\n"
                f"       expected: {old[:120]!r}"
            )
        if n != expect:
            raise SystemExit(
                f"[FAIL] {rel}: anchor matched {n} times, expected {expect}. Refusing to guess.\n"
                f"       anchor: {old[:120]!r}"
            )
        self._write(rel, text.replace(old, new, expect))
        self.changed += 1
        print(f"[ok]   {rel}")

    def write_new(self, rel: str, source: pathlib.Path) -> None:
        dest = self.path(rel)
        if dest.is_file() and dest.read_text(encoding="utf-8") == source.read_text(encoding="utf-8"):
            self.skipped += 1
            print(f"[skip] {rel}: up to date")
            return
        if not self.dry_run:
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, dest)
        self.changed += 1
        print(f"[ok]   {rel} (new file)")

    SKIP_DIRS = {".git", "target", "build", "node_modules", ".dart_tool", ".gradle"}
    SKIP_SUFFIXES = {
        ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".bmp", ".svgz",
        ".so", ".dll", ".dylib", ".a", ".lib", ".exe", ".msi", ".zip", ".gz",
        ".woff", ".woff2", ".ttf", ".otf", ".pdf", ".bin", ".rlib", ".o",
    }

    def iter_text_files(self, dirs):
        for d in dirs:
            base = self.path(d)
            if not base.is_dir():
                continue
            for f in base.rglob("*"):
                if not f.is_file():
                    continue
                if f.suffix.lower() in self.SKIP_SUFFIXES:
                    continue
                if any(part in self.SKIP_DIRS for part in f.relative_to(base).parts):
                    continue
                try:
                    if f.stat().st_size > 4 * 1024 * 1024:
                        continue
                    text = f.read_text(encoding="utf-8")
                except (UnicodeDecodeError, OSError):
                    continue
                yield f, text

    def replace_domain_tree(self, dirs, needle="rustdesk.com", repl="rd.example.com") -> None:
        # Scan every text file rather than a suffix allowlist: the first CI run missed
        # `src/ui/*.tis` and the gate caught it.
        for f, text in self.iter_text_files(dirs):
            if needle not in text:
                continue
            if not self.dry_run:
                f.write_text(text.replace(needle, repl), encoding="utf-8", newline="")
            self.changed += 1
            print(f"[ok]   {f.relative_to(self.root)}: {needle} -> {repl}")

    def gate(self, dirs, banned) -> None:
        hits = []
        for f, text in self.iter_text_files(dirs):
            for word in banned:
                if word in text:
                    hits.append(f"{f.relative_to(self.root)}: {word}")
        if hits:
            print("\n[FAIL] forbidden strings survived patching:", file=sys.stderr)
            for h in hits:
                print("   " + h, file=sys.stderr)
            raise SystemExit(1)
        print("[ok]   gate: no forbidden strings left")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", help="root of the upstream rustdesk checkout")
    ap.add_argument("--dry-run", action="store_true")
    for key, env_key in ENV_KEYS.items():
        ap.add_argument(f"--{key.replace('_', '-')}", default="", help=f"default: env {env_key}")
    args = ap.parse_args()

    resolve_config(vars(args))

    root = pathlib.Path(args.root).resolve()
    if not (root / "src" / "common.rs").is_file():
        raise SystemExit(f"[FAIL] {root} does not look like a rustdesk checkout")
    if not (root / "libs" / "hbb_common" / "src" / "config.rs").is_file():
        raise SystemExit("[FAIL] libs/hbb_common submodule missing; use submodules: recursive")

    p = Patcher(root, args.dry_run)

    print("== identity ==")
    p.sub(
        "flutter/android/app/build.gradle",
        '        applicationId "com.carriez.flutter_hbb"',
        f'        applicationId "{CONFIG["app_id"]}"',
    )
    p.sub(
        "flutter/android/app/src/main/res/values/strings.xml",
        '    <string name="app_name">RustDesk</string>',
        f'    <string name="app_name">{CONFIG["app_name"]}</string>',
    )

    print("== server defaults (no hard-coded third-party server) ==")
    p.sub(
        "libs/hbb_common/src/config.rs",
        'pub const RENDEZVOUS_SERVERS: &[&str] = &["rs-ny.rustdesk.com"];',
        f'pub const RENDEZVOUS_SERVERS: &[&str] = &["{CONFIG["id_server"]}"];',
    )
    p.sub(
        "libs/hbb_common/src/config.rs",
        'pub const RS_PUB_KEY: &str = "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=";',
        f'pub const RS_PUB_KEY: &str = "{CONFIG["pub_key"]}";',
    )

    print("== default options ==")
    opts_map = {
        "disable-udp": "Y",          # no UDP hole punching / UDP registration
        "force-always-relay": "Y",   # every session over TCP relay
        "baidu-proxy": "Y",          # Baidu front-proxy master switch
    }
    if CONFIG["id_server"]:
        opts_map["custom-rendezvous-server"] = CONFIG["id_server"]
    if CONFIG["relay_server"]:
        opts_map["relay-server"] = CONFIG["relay_server"]
    if CONFIG["api_server"]:
        opts_map["api-server"] = CONFIG["api_server"]
    if CONFIG["pub_key"]:
        opts_map["key"] = CONFIG["pub_key"]
    opts = "\n".join(f'        m.insert("{k}".to_owned(), "{v}".to_owned());' for k, v in opts_map.items())
    p.sub(
        "libs/hbb_common/src/config.rs",
        "    pub static ref DEFAULT_SETTINGS: RwLock<HashMap<String, String>> = Default::default();",
        "    pub static ref DEFAULT_SETTINGS: RwLock<HashMap<String, String>> = {\n"
        "        let mut m = HashMap::new();\n"
        f"{opts}\n"
        "        RwLock::new(m)\n"
        "    };",
    )

    print("== proxy funnel: route everything through the local Baidu shim ==")
    p.sub(
        "libs/hbb_common/src/config.rs",
        "    pub fn get_socks() -> Option<Socks5Server> {\n"
        "        Self::get_socks_from_custom_client_advanced_settings(&OVERWRITE_SETTINGS.read().unwrap())",
        "    pub fn get_socks() -> Option<Socks5Server> {\n"
        "        if crate::baidu_tunnel::enabled() {\n"
        "            let port = crate::baidu_tunnel::port();\n"
        "            if port != 0 {\n"
        "                return Some(Socks5Server {\n"
        '                    proxy: format!("http://127.0.0.1:{}", port),\n'
        "                    username: String::new(),\n"
        "                    password: String::new(),\n"
        "                });\n"
        "            }\n"
        "        }\n"
        "        Self::get_socks_from_custom_client_advanced_settings(&OVERWRITE_SETTINGS.read().unwrap())",
    )
    p.sub(
        "libs/hbb_common/src/lib.rs",
        "pub mod proxy;\npub mod socket_client;",
        "pub mod proxy;\npub mod baidu_tunnel;\npub mod socket_client;",
    )
    # `is_proxy()` only inspects the `proxy-url` option, so without this the rendezvous
    # registration would still use UDP and sessions would not be forced onto the relay.
    p.sub(
        "libs/hbb_common/src/config.rs",
        "    pub fn get_network_type() -> NetworkType {\n        if OVERWRITE_SETTINGS",
        "    pub fn get_network_type() -> NetworkType {\n"
        "        if crate::baidu_tunnel::enabled() && crate::baidu_tunnel::port() != 0 {\n"
        "            return NetworkType::ProxySocks;\n"
        "        }\n"
        "        if OVERWRITE_SETTINGS",
    )
    p.write_new("libs/hbb_common/src/baidu_tunnel.rs", pathlib.Path(__file__).with_name("baidu_tunnel.rs"))

    print("== drop public-server heuristics (also fixes the 30 FPS cap) ==")
    p.sub(
        "src/common.rs",
        '    "https://admin.rustdesk.com".to_owned()',
        f'    "{CONFIG["api_server"]}".to_owned()',
    )
    p.sub(
        "src/common.rs",
        "pub fn using_public_server() -> bool {\n"
        "    let api = Config::get_api_server();\n"
        "    if !api.is_empty() {\n"
        "        is_public(&api)\n"
        "    }\n"
        "    else {\n"
        '        crate::get_custom_rendezvous_server(get_option("custom-rendezvous-server")).is_empty()\n'
        "    }\n"
        "}",
        "pub fn using_public_server() -> bool {\n    false\n}",
    )
    p.sub(
        "src/common.rs",
        "    let host = host.strip_suffix('.').unwrap_or(host);\n"
        '    host == "rustdesk.com" || host.ends_with(".rustdesk.com")\n'
        "}",
        "    let _host = host.strip_suffix('.').unwrap_or(host);\n    false\n}",
    )

    print("== remove any baked-in maintenance password (defensive) ==")
    p.sub(
        "libs/hbb_common/src/config.rs",
        '    map.insert("password".to_string(), "qdsq1234".to_string());',
        "    // removed by custom build",
        optional=True,
    )

    print("== replace remaining official domains ==")
    p.replace_domain_tree(
        ["src", "libs/hbb_common/src", "flutter/lib", "flutter/android/app/src"],
        needle="rustdesk.com",
        repl=CONFIG["site_domain"],
    )

    print("== gate ==")
    if args.dry_run:
        print("[skip] gate: dry-run does not modify files")
    else:
        p.gate(
            ["src", "libs/hbb_common/src", "flutter/lib", "flutter/android/app/src"],
            banned=["rustdesk.com", "shuangqingtech", "qdsq1234"],
        )

    mode = "DRY-RUN" if args.dry_run else "APPLIED"
    print(f"\n{mode}: {p.changed} changed, {p.skipped} skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
