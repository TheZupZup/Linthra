//! Gives the shared library a SONAME on Linux and Android.
//!
//! hook/build.dart hands the library to Dart as a code asset, which loads it
//! by its full path. flutter_rust_bridge opens it again by name
//! (`liblinthra_core.so`), and the dynamic linker only matches that name to
//! the copy already loaded when the library carries it as its SONAME.

fn main() {
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if os == "linux" || os == "android" {
        println!("cargo:rustc-cdylib-link-arg=-Wl,-soname,liblinthra_core.so");
    }
}
