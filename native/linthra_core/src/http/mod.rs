//! HTTP for the server clients (Phase 2 of docs/development/rust-backend.md).
//!
//! TLS is rustls, with ring as its crypto, and every certificate is checked by
//! the platform's own verifier ([rustls_platform_verifier]): the system CA
//! bundle on Linux (or the one `SSL_CERT_FILE` / `SSL_CERT_DIR` point at),
//! and on Android the system's trust manager, which follows the app's network
//! security config and so trusts the CAs the user installed. Never a root list
//! bundled in the app: a self-hosted server behind a private CA has to keep
//! working.
//!
//! Nothing sends requests through here yet. Each client moves over once this
//! path is proven on the platform it runs on; on Android that needs
//! [android::init] first (see android/app/.../NativeTls.kt).
//!
//! Android's cleartext rule (the network security config) applies to the
//! platform's HTTP stack, not to sockets opened here: a client that moves
//! over has to keep its own rule about plain `http://`.

#[cfg(target_os = "android")]
pub mod android;

use std::io::{self, Read};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use ureq::tls::{RootCerts, TlsConfig, TlsProvider};

/// How long a whole request may take, the same as the Dart clients' timeout.
pub const TIMEOUT: Duration = Duration::from_secs(20);

/// The largest body read into memory. A library page is a few hundred
/// kilobytes; this only stops a runaway answer.
pub const BODY_LIMIT: u64 = 64 * 1024 * 1024;

/// How many redirects a request follows when it follows any.
const MAX_REDIRECTS: u32 = 10;

/// A request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub method: Method,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    /// Off for a request that must reach the address it names and no other
    /// (one carrying a password in its query, say): a redirect then comes
    /// back as its own 3xx.
    pub follow_redirects: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
}

/// An answer, whatever its status.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub content_type: Option<String>,
    pub body: Vec<u8>,
}

/// Why a request got no answer. Says what kind of failure it was and
/// nothing else: the URL, which can carry credentials, is never in it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Failure {
    /// No connection: the host didn't resolve, refused, or dropped it.
    Unreachable,
    /// No answer within [TIMEOUT].
    TimedOut,
    /// The TLS handshake failed: most often a certificate the platform
    /// doesn't trust, or one for another name.
    Insecure,
    /// An answer too large, or one that broke the protocol.
    BadResponse,
    /// The request itself couldn't be made (a malformed URL).
    BadRequest,
}

/// The status line and headers of an answer, its body not read yet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Head {
    pub status: u16,
    /// Names lower-cased, in the order the server sent them.
    pub headers: Vec<(String, String)>,
}

impl Head {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.as_str())
    }
}

/// An answer whose body is read as it is wanted, at most [BODY_LIMIT]. Dropping
/// it unread lets go of the connection: a ranged probe of a track a server
/// streams whole anyway reads its headers and stops there.
pub struct Opened {
    pub head: Head,
    body: Box<dyn io::Read + Send>,
}

impl Opened {
    /// Reads the next part of the body into `buf`; 0 at its end.
    pub fn read(&mut self, buf: &mut [u8]) -> Result<usize, Failure> {
        self.body.read(buf).map_err(|e| io_failure(&e))
    }
}

/// Sends `request` and reads its whole answer.
pub fn send(request: &Request) -> Result<Response, Failure> {
    let mut opened = open(request)?;
    let mut body = Vec::new();
    opened
        .body
        .read_to_end(&mut body)
        .map_err(|e| io_failure(&e))?;
    Ok(Response {
        status: opened.head.status,
        content_type: opened.head.header("content-type").map(str::to_string),
        body,
    })
}

/// Sends `request` and reads its answer as far as the headers.
pub fn open(request: &Request) -> Result<Opened, Failure> {
    let agent = agent();
    let redirects = if request.follow_redirects {
        MAX_REDIRECTS
    } else {
        0
    };
    let result = match request.method {
        Method::Get => {
            let mut builder = agent.get(&request.url);
            for (name, value) in &request.headers {
                builder = builder.header(name, value);
            }
            builder.config().max_redirects(redirects).build().call()
        }
        Method::Post => {
            let mut builder = agent.post(&request.url);
            for (name, value) in &request.headers {
                builder = builder.header(name, value);
            }
            builder
                .config()
                .max_redirects(redirects)
                .build()
                .send(request.body.as_deref().unwrap_or_default())
        }
    };
    let response = result.map_err(|e| failure(&e))?;
    let head = Head {
        status: response.status().as_u16(),
        headers: response
            .headers()
            .iter()
            .filter_map(|(name, value)| {
                Some((
                    name.as_str().to_ascii_lowercase(),
                    value.to_str().ok()?.to_string(),
                ))
            })
            .collect(),
    };
    let body = response
        .into_body()
        .into_with_config()
        .limit(BODY_LIMIT)
        .reader();
    Ok(Opened {
        head,
        body: Box::new(body),
    })
}

/// The one agent: its connection pool is shared by every request.
fn agent() -> &'static ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| {
        let tls = TlsConfig::builder()
            .provider(TlsProvider::Rustls)
            .root_certs(RootCerts::PlatformVerifier)
            .unversioned_rustls_crypto_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .build();
        ureq::Agent::config_builder()
            .tls_config(tls)
            // Every status comes back as an answer; the client decides.
            .http_status_as_error(false)
            .max_redirects(MAX_REDIRECTS)
            // A redirect a request doesn't follow comes back as its 3xx.
            .max_redirects_will_error(false)
            .timeout_global(Some(TIMEOUT))
            .build()
            .into()
    })
}

fn failure(error: &ureq::Error) -> Failure {
    match error {
        ureq::Error::Timeout(_) => Failure::TimedOut,
        ureq::Error::HostNotFound | ureq::Error::ConnectionFailed => Failure::Unreachable,
        ureq::Error::Tls(_) | ureq::Error::Rustls(_) | ureq::Error::TlsRequired => {
            Failure::Insecure
        }
        ureq::Error::Io(e) => io_failure(e),
        ureq::Error::BadUri(_) | ureq::Error::Http(_) => Failure::BadRequest,
        _ => Failure::BadResponse,
    }
}

/// An I/O error: a TLS failure when rustls is what raised it, which is how a
/// certificate the platform refuses surfaces during the handshake.
fn io_failure(error: &io::Error) -> Failure {
    if error
        .get_ref()
        .is_some_and(|inner| inner.is::<rustls::Error>())
    {
        return Failure::Insecure;
    }
    match error.kind() {
        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => Failure::TimedOut,
        io::ErrorKind::InvalidData => Failure::BadResponse,
        _ => Failure::Unreachable,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_refused_connection_is_unreachable() {
        // Nothing listens on port 1 of the loopback.
        let request = Request {
            method: Method::Get,
            url: "http://127.0.0.1:1/".into(),
            headers: Vec::new(),
            body: None,
            follow_redirects: true,
        };
        assert_eq!(send(&request), Err(Failure::Unreachable));
    }

    #[test]
    fn a_malformed_url_is_a_bad_request() {
        let request = Request {
            method: Method::Get,
            url: "not a url".into(),
            headers: Vec::new(),
            body: None,
            follow_redirects: true,
        };
        assert_eq!(send(&request), Err(Failure::BadRequest));
    }

    #[test]
    fn dropping_an_unread_answer_closes_the_connection() {
        // A server that streams a track whatever the request said: once the
        // headers are read and the answer is let go of, the connection has to
        // close, not keep pulling the track.
        use std::io::Write;
        use std::net::TcpListener;
        use std::time::Instant;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut request = [0u8; 4096];
            let _ = io::Read::read(&mut socket, &mut request);
            socket
                .write_all(b"HTTP/1.1 200 OK\r\ncontent-type: audio/mpeg\r\n\r\n")
                .unwrap();
            let chunk = vec![7u8; 64 * 1024];
            let start = Instant::now();
            let mut sent = 0usize;
            while start.elapsed() < Duration::from_secs(10) {
                if socket.write_all(&chunk).is_err() {
                    return Some(sent);
                }
                sent += chunk.len();
            }
            None
        });
        let mut opened = open(&Request {
            method: Method::Get,
            url: format!("http://127.0.0.1:{port}/"),
            headers: Vec::new(),
            body: None,
            follow_redirects: true,
        })
        .unwrap();
        assert_eq!(opened.head.header("content-type"), Some("audio/mpeg"));
        opened.read(&mut [0u8; 1024]).unwrap();
        drop(opened);
        let sent = server
            .join()
            .unwrap()
            .expect("the connection was kept open");
        // What the socket buffers hold, not the track.
        assert!(sent < 16 * 1024 * 1024, "{sent} bytes went out");
    }
}
