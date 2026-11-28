//! A TLS server for the platform-trust tests: `openssl s_server`, with a
//! certificate issued by a CA made up for the test. Each test is a binary of
//! its own, since the platform verifier reads the system's roots once per
//! process, and points `SSL_CERT_FILE` (how the system CA bundle is chosen
//! on Linux) at the roots that test needs before the first request.

use std::fs;
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

pub struct Server {
    child: Child,
    pub port: u16,
    pub dir: PathBuf,
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn openssl(dir: &Path, args: &[&str]) {
    let status = Command::new("openssl")
        .args(args)
        .current_dir(dir)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("these tests need the openssl command");
    assert!(status.success(), "openssl {args:?} failed");
}

/// A CA made up for the test, as `name.pem` / `name.key` in `dir`.
pub fn make_ca(dir: &Path, name: &str) {
    openssl(
        dir,
        &[
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "2",
            "-subj",
            &format!("/CN=Linthra test {name}"),
            "-keyout",
            &format!("{name}.key"),
            "-out",
            &format!("{name}.pem"),
            "-addext",
            "basicConstraints=critical,CA:TRUE",
            "-addext",
            "keyUsage=critical,keyCertSign,cRLSign",
        ],
    );
}

/// A server certificate for `host`, issued by the CA `ca`.
fn make_leaf(dir: &Path, ca: &str, host: &str) {
    fs::write(
        dir.join("leaf.ext"),
        format!(
            "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\n\
             extendedKeyUsage=serverAuth\nsubjectAltName=DNS:{host}\n"
        ),
    )
    .unwrap();
    openssl(
        dir,
        &[
            "req",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-subj",
            &format!("/CN={host}"),
            "-keyout",
            "leaf.key",
            "-out",
            "leaf.csr",
        ],
    );
    openssl(
        dir,
        &[
            "x509",
            "-req",
            "-in",
            "leaf.csr",
            "-CA",
            &format!("{ca}.pem"),
            "-CAkey",
            &format!("{ca}.key"),
            "-CAcreateserial",
            "-days",
            "2",
            "-extfile",
            "leaf.ext",
            "-out",
            "leaf.pem",
        ],
    );
}

/// A fresh directory for one test's certificates.
pub fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("linthra-tls-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// Serves HTTPS on the loopback with a certificate for `host` issued by the
/// CA `ca` (made with [make_ca] in `dir`).
pub fn serve(dir: PathBuf, ca: &str, host: &str) -> Server {
    make_leaf(&dir, ca, host);
    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let child = Command::new("openssl")
        .args([
            "s_server",
            "-quiet",
            "-www",
            "-accept",
            &port.to_string(),
            "-cert",
            "leaf.pem",
            "-key",
            "leaf.key",
        ])
        .current_dir(&dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("these tests need the openssl command");
    let server = Server { child, port, dir };
    let deadline = Instant::now() + Duration::from_secs(10);
    while TcpStream::connect(("127.0.0.1", port)).is_err() {
        assert!(Instant::now() < deadline, "openssl s_server never listened");
        std::thread::sleep(Duration::from_millis(50));
    }
    server
}

/// Makes `pem` the system's CA bundle for this process.
pub fn trust_only(pem: &Path) {
    // Safe: set before the first request, while this test is the only
    // thread that reads the environment.
    unsafe { std::env::set_var("SSL_CERT_FILE", pem) };
    unsafe { std::env::remove_var("SSL_CERT_DIR") };
}

pub fn get(url: &str) -> Result<linthra_core::http::Response, linthra_core::http::Failure> {
    linthra_core::http::send(&linthra_core::http::Request {
        method: linthra_core::http::Method::Get,
        url: url.to_string(),
        headers: Vec::new(),
        body: None,
        follow_redirects: true,
    })
}
