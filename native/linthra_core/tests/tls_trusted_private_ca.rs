//! A server behind a private CA the system trusts (here through
//! `SSL_CERT_FILE`, the Linux way of choosing the CA bundle) is reached:
//! the verifier asks the platform, not a list bundled in the app.

mod tls;

#[test]
fn a_private_ca_the_system_trusts_is_trusted() {
    let dir = tls::scratch("trusted");
    tls::make_ca(&dir, "ca");
    tls::trust_only(&dir.join("ca.pem"));
    let server = tls::serve(dir, "ca", "localhost");

    let response = tls::get(&format!("https://localhost:{}/", server.port))
        .expect("a trusted server is reached");
    assert_eq!(response.status, 200);
    assert!(!response.body.is_empty());
}
