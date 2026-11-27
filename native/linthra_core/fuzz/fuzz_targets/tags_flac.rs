#![no_main]

libfuzzer_sys::fuzz_target!(|data: &[u8]| {
    linthra_core::tags::fuzz::read("flac", data);
});
