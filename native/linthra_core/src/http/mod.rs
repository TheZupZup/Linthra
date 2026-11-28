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

use std::io;
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

/// Sends `request` and reads its whole answer.
pub fn send(request: &Request) -> Result<Response, Failure> {
    let agent = agent();
    let redirects = if request.follow_redirects {
        MAX_REDIRECTS
    } else {
        0
    };
    let result = match (request.method, &request.body) {
        (Method::Get, _) => {
            let mut builder = agent.get(&request.url);
            for (name, value) in &request.headers {
                builder = builder.header(name, value);
            }
            builder.config().max_redirects(redirects).build().call()
        }
        (Method::Post, body) => {
            let mut builder = agent.post(&request.url);
            for (name, value) in &request.headers {
                builder = builder.header(name, value);
            }
            builder
                .config()
                .max_redirects(redirects)
                .build()
                .send(body.as_deref().unwrap_or_default())
        }
    };
    let mut response = result.map_err(|e| failure(&e))?;
    let status = response.status().as_u16();
    let content_type = response
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    let body = response
        .body_mut()
        .with_config()
        .limit(BODY_LIMIT)
        .read_to_vec()
        .map_err(|e| failure(&e))?;
    Ok(Response {
        status,
        content_type,
        body,
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
}
