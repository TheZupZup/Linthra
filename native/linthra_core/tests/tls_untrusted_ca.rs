//! A certificate from a CA the system doesn't trust is refused, as
//! `Failure::Insecure`, even though a CA exists for it: only the platform's
//! roots count.

mod tls;

use linthra_core::http::Failure;

#[test]
fn a_ca_the_system_does_not_trust_is_refused() {
    let dir = tls::scratch("untrusted");
    tls::make_ca(&dir, "ca");
    tls::make_ca(&dir, "other");
    // The system trusts another CA, not the one that issued the server's.
    tls::trust_only(&dir.join("other.pem"));
    let server = tls::serve(dir, "ca", "localhost");

    assert_eq!(
        tls::get(&format!("https://localhost:{}/", server.port)),
        Err(Failure::Insecure)
    );
}
