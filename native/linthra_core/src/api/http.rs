//! HTTP for Dart: `RustHttpClient` (lib/core/native/rust_http_client.dart),
//! a `package:http` client whose requests go out through `crate::http`, so
//! with TLS checked by the platform's trust store.

use crate::frb_generated::StreamSink;
use crate::http::{self, Failure, Method, Request};

pub struct HttpHeader {
    pub name: String,
    pub value: String,
}

/// Why a request got no answer. Never carries the URL, which can hold
/// credentials.
pub enum HttpFailure {
    Unreachable,
    TimedOut,
    Insecure,
    BadResponse,
    BadRequest,
}

/// One part of an answer. The first carries `status` and `headers`, or a
/// `failure` and nothing else; the ones after it carry the body in order.
/// A failure while the body is read ends it with a part carrying only the
/// failure.
pub struct HttpPart {
    pub status: Option<u16>,
    pub headers: Vec<HttpHeader>,
    pub chunk: Vec<u8>,
    pub failure: Option<HttpFailure>,
}

/// How much of the body each part carries at most.
const CHUNK: usize = 64 * 1024;

/// Sends a request and streams its answer into `sink`, then closes it.
///
/// On a thread of its own, so a server that is slow to answer holds that
/// thread and not one the bridge's other calls need. The body is read only
/// as fast as Dart takes it: cancelling the stream stops the read and lets go
/// of the connection, so a probe that wanted the headers never downloads the
/// track.
pub fn http_fetch(
    method: String,
    url: String,
    headers: Vec<HttpHeader>,
    body: Option<Vec<u8>>,
    follow_redirects: bool,
    sink: StreamSink<HttpPart>,
) {
    std::thread::spawn(move || {
        let fetched = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            fetch(&method, url, headers, body, follow_redirects, &sink)
        }));
        if fetched.is_err() {
            // A panic is an answer that broke: say so, as a failure.
            let _ = sink.add(failed(Failure::BadResponse));
        }
    });
}

fn fetch(
    method: &str,
    url: String,
    headers: Vec<HttpHeader>,
    body: Option<Vec<u8>>,
    follow_redirects: bool,
    sink: &StreamSink<HttpPart>,
) {
    let method = match method {
        "GET" => Method::Get,
        "POST" => Method::Post,
        _ => {
            let _ = sink.add(failed(Failure::BadRequest));
            return;
        }
    };
    let request = Request {
        method,
        url,
        headers: headers.into_iter().map(|h| (h.name, h.value)).collect(),
        body,
        follow_redirects,
    };
    let mut opened = match http::open(&request) {
        Ok(opened) => opened,
        Err(failure) => {
            let _ = sink.add(failed(failure));
            return;
        }
    };
    let head = HttpPart {
        status: Some(opened.head.status),
        headers: opened
            .head
            .headers
            .iter()
            .map(|(name, value)| HttpHeader {
                name: name.clone(),
                value: value.clone(),
            })
            .collect(),
        chunk: Vec::new(),
        failure: None,
    };
    if sink.add(head).is_err() {
        return;
    }
    let mut buf = vec![0; CHUNK];
    loop {
        match opened.read(&mut buf) {
            Ok(0) => return,
            Ok(n) => {
                let part = HttpPart {
                    status: None,
                    headers: Vec::new(),
                    chunk: buf[..n].to_vec(),
                    failure: None,
                };
                // Dart cancelled: stop reading, and drop the connection.
                if sink.add(part).is_err() {
                    return;
                }
            }
            Err(failure) => {
                let _ = sink.add(failed(failure));
                return;
            }
        }
    }
}

fn failed(failure: Failure) -> HttpPart {
    HttpPart {
        status: None,
        headers: Vec::new(),
        chunk: Vec::new(),
        failure: Some(match failure {
            Failure::Unreachable => HttpFailure::Unreachable,
            Failure::TimedOut => HttpFailure::TimedOut,
            Failure::Insecure => HttpFailure::Insecure,
            Failure::BadResponse => HttpFailure::BadResponse,
            Failure::BadRequest => HttpFailure::BadRequest,
        }),
    }
}
