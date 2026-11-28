//! A trusted certificate for another name is refused: the host name is
//! checked, not only the chain.

mod tls;

use linthra_core::http::Failure;

#[test]
fn a_certificate_for_another_name_is_refused() {
    let dir = tls::scratch("wrong-name");
    tls::make_ca(&dir, "ca");
    tls::trust_only(&dir.join("ca.pem"));
    let server = tls::serve(dir, "ca", "music.example.com");

    assert_eq!(
        tls::get(&format!("https://localhost:{}/", server.port)),
        Err(Failure::Insecure)
    );
}
