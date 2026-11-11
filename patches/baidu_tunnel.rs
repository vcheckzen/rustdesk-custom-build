//! Baidu front-proxy tunnel (a.k.a. "百度前置代理").
//!
//! RustDesk's whole outbound stack already funnels through `Config::get_socks()`:
//! `socket_client::connect_tcp_local` (every TCP connection), `rendezvous_mediator::start`
//! (switches registration to TCP) and `hbbs_http::http_client` (reqwest). But it only speaks a
//! *standard* `CONNECT host:port` with `Host: host:port`.
//!
//! The Baidu front proxy requires a **fake** `Host:` header plus an `X-T5-Auth` token, so a plain
//! proxy config cannot be used directly. Instead this module runs a tiny HTTP CONNECT shim on
//! 127.0.0.1:<ephemeral>, and `Config::get_socks()` points RustDesk at it. Every connection then
//! goes: RustDesk -> local shim -> `cloudnproxy.baidu.com:443` -> real target.
//!
//! Protocol (verified against fscarmen/cfnat, `dialBaiduTunnelViaNode`):
//!
//! ```text
//! CONNECT <target-host:port> HTTP/1.1
//! Host: sptest.baidu.com          <- deliberately NOT the target
//! X-T5-Auth: 482857715
//! User-Agent: okhttp/... baiduboxapp/...
//! Proxy-Connection: keep-alive
//! ```
//!
//! The target is passed as a *domain* so the proxy resolves it; we only resolve the proxy host
//! itself, and never hard-code its IP.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

/// Default front-proxy host. Resolved through DNS every `DNS_TTL`, never hard-coded as an IP.
pub const DEFAULT_PROXY_HOST: &str = "cloudnproxy.baidu.com";
/// Default front-proxy port. Plain TCP + HTTP CONNECT (no TLS handshake).
pub const DEFAULT_PROXY_PORT: u16 = 443;

/// Options that let a deployment override the endpoint without rebuilding.
const OPT_ENABLED: &str = "baidu-proxy";
const OPT_HOST: &str = "baidu-proxy-host";
const OPT_PORT: &str = "baidu-proxy-port";

const FAKE_HOST: &str = "sptest.baidu.com";
const AUTH_TOKEN: &str = "482857715";
const USER_AGENT: &str =
    "okhttp/3.11.0 Dalvik/2.1.0 (Linux; Build/RKQ1.200826.002) baiduboxapp/11.0.5.12 (Baidu; P1 11)";

const MAX_HEADER: usize = 8 * 1024;
const IO_TIMEOUT: Duration = Duration::from_secs(10);
const DNS_TTL: Duration = Duration::from_secs(60);

static PORT: AtomicU16 = AtomicU16::new(0);
static BOOT: OnceLock<()> = OnceLock::new();
static DNS_CACHE: OnceLock<Mutex<DnsCache>> = OnceLock::new();

struct DnsCache {
    key: String,
    addrs: Vec<SocketAddr>,
    at: Instant,
}

/// Whether the tunnel is enabled. Defaults to on; set option `baidu-proxy=N` to bypass it and
/// fall back to RustDesk's normal (direct) networking.
pub fn enabled() -> bool {
    let v = crate::config::Config::get_option(OPT_ENABLED);
    let v = v.trim();
    if v.is_empty() {
        return true;
    }
    !(v.eq_ignore_ascii_case("n")
        || v.eq_ignore_ascii_case("no")
        || v.eq_ignore_ascii_case("false")
        || v == "0")
}

/// Local shim port. Starts the shim on first call. Returns 0 if it could not be started.
pub fn port() -> u16 {
    let p = PORT.load(Ordering::Relaxed);
    if p != 0 {
        return p;
    }
    BOOT.get_or_init(|| match start() {
        Ok(p) => {
            PORT.store(p, Ordering::SeqCst);
            log::info!("[baidu-tunnel] local CONNECT shim on 127.0.0.1:{}", p);
        }
        Err(e) => log::error!("[baidu-tunnel] failed to start: {:#}", e),
    });
    PORT.load(Ordering::SeqCst)
}

fn start() -> Result<u16> {
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0))?;
    let port = listener.local_addr()?.port();
    listener.set_nonblocking(true)?;

    std::thread::Builder::new()
        .name("baidu-tunnel".to_string())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    log::error!("[baidu-tunnel] runtime: {}", e);
                    return;
                }
            };
            rt.block_on(async move {
                let listener = match tokio::net::TcpListener::from_std(listener) {
                    Ok(l) => l,
                    Err(e) => {
                        log::error!("[baidu-tunnel] from_std: {}", e);
                        return;
                    }
                };
                loop {
                    match listener.accept().await {
                        Ok((sock, _peer)) => {
                            tokio::spawn(handle(sock));
                        }
                        Err(e) => {
                            log::warn!("[baidu-tunnel] accept: {}", e);
                            tokio::time::sleep(Duration::from_millis(200)).await;
                        }
                    }
                }
            });
        })?;

    Ok(port)
}

async fn handle(mut client: TcpStream) {
    if let Err(e) = handle_inner(&mut client).await {
        log::debug!("[baidu-tunnel] connection closed: {:#}", e);
    }
}

async fn handle_inner(client: &mut TcpStream) -> Result<()> {
    let (buf, head_len) = read_head(client).await?;
    let (method, path, version) = parse_request(&buf[..head_len])?;
    let extra = buf[head_len..].to_vec();

    let is_connect = method.eq_ignore_ascii_case("CONNECT");

    // CONNECT carries the authority in the request line; a plain-HTTP request arrives in
    // absolute form (`GET http://host/path`) and must be rewritten before forwarding.
    let (target, rewritten_line) = if is_connect {
        if !path.contains(':') {
            bail!("CONNECT target without port: {}", path);
        }
        (path.clone(), None)
    } else {
        let url = url::Url::parse(&path).map_err(|e| anyhow!("bad absolute URI {:?}: {}", path, e))?;
        let host = url
            .host_str()
            .ok_or_else(|| anyhow!("no host in absolute URI {:?}", path))?;
        let port = url.port_or_known_default().unwrap_or(80);
        let mut new_path = url.path().to_string();
        if let Some(q) = url.query() {
            new_path.push('?');
            new_path.push_str(q);
        }
        if new_path.is_empty() {
            new_path.push('/');
        }
        (
            format!("{}:{}", host, port),
            Some(format!("{} {} {}\r\n", method, new_path, version)),
        )
    };

    let (mut upstream, upstream_extra) = open_tunnel(&target).await?;

    if is_connect {
        client
            .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            .await?;
        if !extra.is_empty() {
            upstream.write_all(&extra).await?;
        }
    } else {
        // Rebuild the request: rewritten request line + original headers verbatim.
        let line_end = find_sub(&buf, b"\r\n").map(|i| i + 2).unwrap_or(head_len);
        let mut out = Vec::with_capacity(head_len + extra.len() + 32);
        out.extend_from_slice(rewritten_line.as_deref().unwrap_or("").as_bytes());
        out.extend_from_slice(&buf[line_end..]);
        upstream.write_all(&out).await?;
    }

    // Bytes the proxy already sent past its own response head belong to the tunnel payload.
    if !upstream_extra.is_empty() {
        client.write_all(&upstream_extra).await?;
    }

    tokio::io::copy_bidirectional(client, &mut upstream).await?;
    Ok(())
}

/// Open a tunnel to `target` through the Baidu front proxy.
/// Returns the upstream stream plus any payload bytes read past the proxy's response head.
async fn open_tunnel(target: &str) -> Result<(TcpStream, Vec<u8>)> {
    let host = proxy_host();
    let port = proxy_port();
    let mut stream = dial(&host, port).await?;

    let req = format!(
        "CONNECT {target} HTTP/1.1\r\n\
         Host: {fake}\r\n\
         X-T5-Auth: {auth}\r\n\
         User-Agent: {ua}\r\n\
         Proxy-Connection: keep-alive\r\n\
         Connection: keep-alive\r\n\
         \r\n",
        target = target,
        fake = FAKE_HOST,
        auth = AUTH_TOKEN,
        ua = USER_AGENT
    );
    stream.write_all(req.as_bytes()).await?;

    let (buf, head_len) = read_head(&mut stream).await?;
    let head = String::from_utf8_lossy(&buf[..head_len]).to_string();
    let ok = head.starts_with("HTTP/1.1 200") || head.starts_with("HTTP/1.0 200");
    if !ok {
        let status = head.lines().next().unwrap_or("<empty>").trim().to_string();
        bail!("front proxy refused CONNECT {}: {}", target, status);
    }

    let extra = buf[head_len..].to_vec();
    log::debug!("[baidu-tunnel] tunnel up: {} -> {}", target, host);
    Ok((stream, extra))
}

fn proxy_host() -> String {
    let v = crate::config::Config::get_option(OPT_HOST);
    let v = v.trim();
    if v.is_empty() {
        DEFAULT_PROXY_HOST.to_string()
    } else {
        v.to_string()
    }
}

fn proxy_port() -> u16 {
    let v = crate::config::Config::get_option(OPT_PORT);
    v.trim().parse().unwrap_or(DEFAULT_PROXY_PORT)
}

async fn dial(host: &str, port: u16) -> Result<TcpStream> {
    let addrs = resolve(host, port).await?;
    let mut last: Option<anyhow::Error> = None;
    for addr in addrs {
        match tokio::time::timeout(IO_TIMEOUT, TcpStream::connect(addr)).await {
            Ok(Ok(s)) => {
                let _ = s.set_nodelay(true);
                return Ok(s);
            }
            Ok(Err(e)) => last = Some(anyhow!("{}: {}", addr, e)),
            Err(_) => last = Some(anyhow!("{}: connect timeout", addr)),
        }
    }
    Err(last.unwrap_or_else(|| anyhow!("no address for {}:{}", host, port)))
}

/// Resolve the front-proxy host through the system resolver, cached briefly.
/// Deliberately never hard-codes an IP.
async fn resolve(host: &str, port: u16) -> Result<Vec<SocketAddr>> {
    let key = format!("{}:{}", host, port);
    let cache = DNS_CACHE.get_or_init(|| {
        Mutex::new(DnsCache {
            key: String::new(),
            addrs: Vec::new(),
            at: Instant::now(),
        })
    });

    if let Ok(c) = cache.lock() {
        if c.key == key && !c.addrs.is_empty() && c.at.elapsed() < DNS_TTL {
            return Ok(c.addrs.clone());
        }
    }

    let addrs: Vec<SocketAddr> = tokio::net::lookup_host((host, port)).await?.collect();
    if addrs.is_empty() {
        bail!("DNS returned no address for {}", key);
    }
    if let Ok(mut c) = cache.lock() {
        c.key = key;
        c.addrs = addrs.clone();
        c.at = Instant::now();
    }
    Ok(addrs)
}

/// Read until the end of the HTTP head. Returns (buffer, header length).
async fn read_head(stream: &mut TcpStream) -> Result<(Vec<u8>, usize)> {
    let mut buf: Vec<u8> = Vec::with_capacity(1024);
    let mut tmp = [0u8; 1024];
    loop {
        if let Some(i) = find_sub(&buf, b"\r\n\r\n") {
            return Ok((buf, i + 4));
        }
        if buf.len() > MAX_HEADER {
            bail!("HTTP head larger than {} bytes", MAX_HEADER);
        }
        let n = tokio::time::timeout(IO_TIMEOUT, stream.read(&mut tmp))
            .await
            .map_err(|_| anyhow!("timeout while reading HTTP head"))??;
        if n == 0 {
            bail!("EOF before end of HTTP head");
        }
        buf.extend_from_slice(&tmp[..n]);
    }
}

fn parse_request(head: &[u8]) -> Result<(String, String, String)> {
    let mut headers = [httparse::EMPTY_HEADER; 64];
    let mut req = httparse::Request::new(&mut headers);
    match req.parse(head) {
        Ok(httparse::Status::Complete(_)) => {}
        Ok(httparse::Status::Partial) => bail!("incomplete HTTP request head"),
        Err(e) => bail!("malformed HTTP request head: {}", e),
    }
    let method = req.method.unwrap_or("").to_string();
    let path = req.path.unwrap_or("").to_string();
    let version = if req.version == Some(1) {
        "HTTP/1.1"
    } else {
        "HTTP/1.0"
    };
    if method.is_empty() || path.is_empty() {
        bail!("missing method or target");
    }
    Ok((method, path, version.to_string()))
}

fn find_sub(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_connect_authority() {
        let head = b"CONNECT rd.example.com:443 HTTP/1.1\r\nHost: rd.example.com:443\r\n\r\n";
        let (m, p, v) = parse_request(head).unwrap();
        assert_eq!(m, "CONNECT");
        assert_eq!(p, "rd.example.com:443");
        assert_eq!(v, "HTTP/1.1");
    }

    #[test]
    fn finds_header_end() {
        assert_eq!(find_sub(b"a\r\n\r\nb", b"\r\n\r\n"), Some(1));
        assert_eq!(find_sub(b"abc", b"\r\n\r\n"), None);
    }
}
