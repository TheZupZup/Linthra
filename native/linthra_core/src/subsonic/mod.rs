//! The Subsonic / OpenSubsonic API (Navidrome and the servers that speak it).
//!
//! Phase 2 of docs/development/rust-backend.md moves the client here in
//! steps. First, reading what a server answers ([response], over the JSON
//! reader in [json]); the requests still go out from Dart, through the
//! platform's HTTP stack and trust store, until TLS through the system's
//! trust store is proven here.

pub mod json;
pub mod response;
