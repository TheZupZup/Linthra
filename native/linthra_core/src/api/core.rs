//! The smallest proof that the bridge works end to end: an async call and a
//! stream. The backend phases build on the same path.

use crate::frb_generated::StreamSink;

/// The C ABI version the hand-written calls speak, through the bridge.
pub async fn bridge_abi_version() -> u32 {
    crate::ffi::ABI_VERSION
}

/// Counts from 1 to `to` into `sink`, then closes it.
pub fn bridge_count(to: u32, sink: StreamSink<u32>) {
    for i in 1..=to {
        if sink.add(i).is_err() {
            return;
        }
    }
}
