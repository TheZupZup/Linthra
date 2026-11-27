//! C ABI for [crate::search_rank]: one call, nothing allocated for Dart to
//! free.
//!
//! The query and every result's name are UTF-8 in buffers Dart owns. Each
//! name is a span of two `u32`s into `text` (start, length); each kind is a
//! `u8` numbered like `SearchResultKind.values` (artist, album, song). Rust
//! writes the order into `out`, which holds `count` positions.

use crate::ffi::{STATUS_INVALID_UTF8, STATUS_NULL_ARGUMENT, STATUS_OK};
use crate::search_rank::{rank_results, ResultKind};

/// A span fell outside `text`, or a kind was not known.
pub const STATUS_INVALID_INPUT: i32 = 3;

/// Writes into `out` the positions of the `count` results in the order to
/// show them for the query.
///
/// Returns [STATUS_OK], [STATUS_NULL_ARGUMENT] (an array is null while its
/// length is not zero), [STATUS_INVALID_UTF8] or [STATUS_INVALID_INPUT]. On an
/// error `out` is left as it was.
///
/// # Safety
///
/// `query` must be null or valid for `query_len` reads, `text` for
/// `text_len`, `kinds` for `count`, `spans` for `2 * count` and `out` for
/// `count` writes, for the duration of the call.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn linthra_search_rank(
    query: *const u8,
    query_len: usize,
    text: *const u8,
    text_len: usize,
    kinds: *const u8,
    spans: *const u32,
    count: usize,
    out: *mut u32,
) -> i32 {
    crate::ffi::guard(crate::ffi::STATUS_PANIC, || {
        crate::ffi::fail_safe(
            || {
                let (Some(query), Some(text), Some(kinds), Some(spans)) = (
                    bytes(query, query_len),
                    bytes(text, text_len),
                    bytes(kinds, count),
                    count.checked_mul(2).and_then(|n| bytes(spans, n)),
                ) else {
                    return STATUS_NULL_ARGUMENT;
                };
                if count > 0 && out.is_null() {
                    return STATUS_NULL_ARGUMENT;
                }
                let Ok(query) = std::str::from_utf8(query) else {
                    return STATUS_INVALID_UTF8;
                };
                let mut results: Vec<(ResultKind, &str)> = Vec::with_capacity(count);
                for i in 0..count {
                    let kind = match kinds[i] {
                        0 => ResultKind::Artist,
                        1 => ResultKind::Album,
                        2 => ResultKind::Song,
                        _ => return STATUS_INVALID_INPUT,
                    };
                    let start = spans[2 * i] as usize;
                    let Some(end) = start.checked_add(spans[2 * i + 1] as usize) else {
                        return STATUS_INVALID_INPUT;
                    };
                    let Some(raw) = text.get(start..end) else {
                        return STATUS_INVALID_INPUT;
                    };
                    let Ok(name) = std::str::from_utf8(raw) else {
                        return STATUS_INVALID_UTF8;
                    };
                    results.push((kind, name));
                }
                for (slot, position) in rank_results(query, &results).into_iter().enumerate() {
                    *out.add(slot) = position as u32;
                }
                STATUS_OK
            },
            || {
                // Safe answer: the order given.
                if count > 0 && out.is_null() {
                    return STATUS_NULL_ARGUMENT;
                }
                for i in 0..count {
                    *out.add(i) = i as u32;
                }
                STATUS_OK
            },
        )
    })
}

/// `len` values at `p`, or none when `p` is null while `len` is not zero.
///
/// # Safety
///
/// `p` must be null or valid for `len` reads.
unsafe fn bytes<'a, T>(p: *const T, len: usize) -> Option<&'a [T]> {
    if len == 0 {
        Some(&[])
    } else if p.is_null() {
        None
    } else {
        Some(std::slice::from_raw_parts(p, len))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ptr;

    #[test]
    fn ranks_through_the_buffers() {
        let query = "metallica";
        let text = "BatteryMetallica";
        let kinds = [2u8, 0];
        let spans = [0u32, 7, 7, 9];
        let mut out = [9u32; 2];
        let status = unsafe {
            linthra_search_rank(
                query.as_ptr(),
                query.len(),
                text.as_ptr(),
                text.len(),
                kinds.as_ptr(),
                spans.as_ptr(),
                2,
                out.as_mut_ptr(),
            )
        };
        assert_eq!(status, STATUS_OK);
        assert_eq!(out, [1, 0]);
    }

    #[test]
    fn refuses_bad_input() {
        let text = "abc";
        let mut out = [0u32; 1];
        let call = |kinds: &[u8], spans: &[u32], out: *mut u32| unsafe {
            linthra_search_rank(
                ptr::null(),
                0,
                text.as_ptr(),
                text.len(),
                kinds.as_ptr(),
                spans.as_ptr(),
                1,
                out,
            )
        };
        assert_eq!(call(&[7], &[0, 1], out.as_mut_ptr()), STATUS_INVALID_INPUT);
        assert_eq!(call(&[0], &[2, 5], out.as_mut_ptr()), STATUS_INVALID_INPUT);
        assert_eq!(call(&[0], &[0, 1], ptr::null_mut()), STATUS_NULL_ARGUMENT);
    }
}
