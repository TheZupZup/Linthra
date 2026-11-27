#![no_main]

use linthra_core::cue_sheet::{decode, parse};

libfuzzer_sys::fuzz_target!(|data: &[u8]| {
    // A sheet as the scan reads it: decoded from its bytes, then parsed.
    let _ = parse(&decode(data));
});
