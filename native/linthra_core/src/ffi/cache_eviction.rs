//! C ABI for [crate::cache_eviction]: one call takes the whole cache's
//! metadata and returns the plan.
//!
//! Strings do not cross one by one. Every source and id is written into one
//! UTF-8 buffer, and each key is a span of four `u32`s into it: source start,
//! source length, id start, id length. Everything else is a parallel array
//! with one element per cached entry, so a plan over thousands of entries is a
//! single call.

use std::collections::HashSet;
use std::ptr;

use crate::cache_eviction::{plan, CacheKey, CachedEntry, EvictionRequest};

/// Entry flag: Linthra manages the file, so deleting it frees space.
pub const EVICTION_MANAGED: u8 = 1;
/// Entry flag: kept offline by the user.
pub const EVICTION_PINNED: u8 = 1 << 1;
/// Entry flag: cached automatically ahead of playback.
pub const EVICTION_PRELOADED: u8 = 1 << 2;
/// Entry flag: `last_accessed` holds a time (otherwise never played).
pub const EVICTION_HAS_LAST_ACCESSED: u8 = 1 << 3;
/// Entry flag: `cached_at` holds a time.
pub const EVICTION_HAS_CACHED_AT: u8 = 1 << 4;

/// A plan: whether the download fits, and which entries to delete, as indices
/// into the arrays the plan was made from, in the order to delete them.
pub struct EvictionResult {
    fits: bool,
    evict: Vec<u32>,
}

/// Plans which cached entries to delete so `incoming_bytes` fits under
/// `max_bytes`.
///
/// `count` entries are described by `spans` (`4 * count` values), `sizes`,
/// `last_accessed`, `cached_at` and `flags` (`count` values each; a time is
/// only read when its flag is set). `protect_spans` holds `4 * protect_count`
/// values: keys that must not be evicted. `incoming_span` is null, or four
/// values naming the track being downloaded. Every span points into `text`.
///
/// Returns null when an array is null while its length is not zero, a span
/// falls outside `text`, or a span is not valid UTF-8. Free the result with
/// [linthra_eviction_result_free].
///
/// # Safety
///
/// Each pointer must be null or valid for reads of the length given above,
/// for the duration of the call.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn linthra_eviction_plan(
    text: *const u8,
    text_len: usize,
    spans: *const u32,
    sizes: *const i64,
    last_accessed: *const i64,
    cached_at: *const i64,
    flags: *const u8,
    count: usize,
    protect_spans: *const u32,
    protect_count: usize,
    incoming_span: *const u32,
    incoming_bytes: i64,
    max_bytes: i64,
    only_preloaded: bool,
) -> *mut EvictionResult {
    let input = || -> Option<EvictionResult> {
        let text = array(text, text_len)?;
        let spans = array(spans, count.checked_mul(4)?)?;
        let sizes = array(sizes, count)?;
        let last_accessed = array(last_accessed, count)?;
        let cached_at = array(cached_at, count)?;
        let flags = array(flags, count)?;
        let protect_spans = array(protect_spans, protect_count.checked_mul(4)?)?;

        let mut cached = Vec::with_capacity(count);
        for i in 0..count {
            let flag = flags[i];
            cached.push(CachedEntry {
                key: key(text, &spans[4 * i..4 * i + 4])?,
                managed: flag & EVICTION_MANAGED != 0,
                size_bytes: sizes[i],
                last_accessed: (flag & EVICTION_HAS_LAST_ACCESSED != 0).then_some(last_accessed[i]),
                cached_at: (flag & EVICTION_HAS_CACHED_AT != 0).then_some(cached_at[i]),
                pinned: flag & EVICTION_PINNED != 0,
                preloaded: flag & EVICTION_PRELOADED != 0,
            });
        }
        let protected = (0..protect_count)
            .map(|i| key(text, &protect_spans[4 * i..4 * i + 4]))
            .collect::<Option<HashSet<CacheKey>>>()?;
        let incoming = if incoming_span.is_null() {
            None
        } else {
            Some(key(text, array(incoming_span, 4)?)?)
        };

        let request = EvictionRequest {
            incoming_bytes,
            max_bytes,
            protected,
            only_preloaded,
            incoming,
        };
        let result = plan(&cached, &request);
        Some(EvictionResult {
            fits: result.fits,
            evict: result.evict.into_iter().map(|i| i as u32).collect(),
        })
    };
    match input() {
        Some(result) => Box::into_raw(Box::new(result)),
        None => ptr::null_mut(),
    }
}

/// Whether the download fits once the planned entries are deleted. False for
/// a null `result`.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_eviction_plan].
#[no_mangle]
pub unsafe extern "C" fn linthra_eviction_result_fits(result: *const EvictionResult) -> bool {
    result.as_ref().is_some_and(|r| r.fits)
}

/// How many entries to delete. 0 for a null `result`.
///
/// # Safety
///
/// As for [linthra_eviction_result_fits].
#[no_mangle]
pub unsafe extern "C" fn linthra_eviction_result_len(result: *const EvictionResult) -> usize {
    result.as_ref().map_or(0, |r| r.evict.len())
}

/// The entries to delete, as [linthra_eviction_result_len] indices, valid
/// until the result is freed. Null for a null `result`.
///
/// # Safety
///
/// As for [linthra_eviction_result_fits].
#[no_mangle]
pub unsafe extern "C" fn linthra_eviction_result_indices(
    result: *const EvictionResult,
) -> *const u32 {
    result.as_ref().map_or(ptr::null(), |r| r.evict.as_ptr())
}

/// Frees a plan. Null is a no-op.
///
/// # Safety
///
/// `result` must be null or a pointer from [linthra_eviction_plan] that has
/// not been freed yet.
#[no_mangle]
pub unsafe extern "C" fn linthra_eviction_result_free(result: *mut EvictionResult) {
    if !result.is_null() {
        drop(Box::from_raw(result));
    }
}

/// `len` elements at `data`, or None when `data` is null and `len` is not 0.
///
/// # Safety
///
/// A non-null `data` must be valid for reads of `len` elements.
unsafe fn array<'a, T>(data: *const T, len: usize) -> Option<&'a [T]> {
    if len == 0 {
        Some(&[])
    } else if data.is_null() {
        None
    } else {
        Some(std::slice::from_raw_parts(data, len))
    }
}

/// The key a span names, or None when it falls outside `text` or is not UTF-8.
fn key<'a>(text: &'a [u8], span: &[u32]) -> Option<CacheKey<'a>> {
    let part = |start: u32, len: u32| {
        let start = start as usize;
        let bytes = text.get(start..start.checked_add(len as usize)?)?;
        std::str::from_utf8(bytes).ok()
    };
    let source = part(span[0], span[1])?;
    let id = part(span[2], span[3])?;
    Some(CacheKey::new(Some(source), id))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Writes `keys` into one buffer and returns it with their spans.
    fn pack(keys: &[(&str, &str)]) -> (Vec<u8>, Vec<u32>) {
        let mut text = Vec::new();
        let mut spans = Vec::new();
        for (source, id) in keys {
            for part in [source, id] {
                spans.push(text.len() as u32);
                spans.push(part.len() as u32);
                text.extend_from_slice(part.as_bytes());
            }
        }
        (text, spans)
    }

    /// Runs a plan and reads it back as (fits, indices).
    unsafe fn run(
        keys: &[(&str, &str)],
        sizes: &[i64],
        accessed: &[Option<i64>],
        protect: &[(&str, &str)],
        incoming_bytes: i64,
        max_bytes: i64,
    ) -> Option<(bool, Vec<u32>)> {
        let mut all = keys.to_vec();
        all.extend_from_slice(protect);
        let (text, spans) = pack(&all);
        let flags: Vec<u8> = accessed
            .iter()
            .map(|a| {
                EVICTION_MANAGED
                    | if a.is_some() {
                        EVICTION_HAS_LAST_ACCESSED
                    } else {
                        0
                    }
            })
            .collect();
        let times: Vec<i64> = accessed.iter().map(|a| a.unwrap_or(0)).collect();
        let result = linthra_eviction_plan(
            text.as_ptr(),
            text.len(),
            spans.as_ptr(),
            sizes.as_ptr(),
            times.as_ptr(),
            times.as_ptr(),
            flags.as_ptr(),
            keys.len(),
            spans[4 * keys.len()..].as_ptr(),
            protect.len(),
            ptr::null(),
            incoming_bytes,
            max_bytes,
            false,
        );
        if result.is_null() {
            return None;
        }
        let len = linthra_eviction_result_len(result);
        let indices =
            std::slice::from_raw_parts(linthra_eviction_result_indices(result), len).to_vec();
        let fits = linthra_eviction_result_fits(result);
        linthra_eviction_result_free(result);
        Some((fits, indices))
    }

    #[test]
    fn plans_across_the_boundary() {
        let planned = unsafe {
            run(
                &[("jellyfin", "a"), ("jellyfin", "b"), ("plex", "c")],
                &[100, 100, 100],
                &[Some(30), None, Some(20)],
                &[("plex", "c")],
                150,
                300,
            )
        };
        // b (never played) goes first; c is protected, so a goes next.
        assert_eq!(planned, Some((true, vec![1, 0])));
    }

    #[test]
    fn non_ascii_ids_survive_the_buffer() {
        let planned = unsafe {
            run(
                &[("jellyfin", "café"), ("jellyfin", "曲")],
                &[100, 100],
                &[Some(2), Some(1)],
                &[],
                100,
                200,
            )
        };
        assert_eq!(planned, Some((true, vec![1])));
    }

    #[test]
    fn an_empty_cache_needs_no_arrays() {
        let result = unsafe {
            linthra_eviction_plan(
                ptr::null(),
                0,
                ptr::null(),
                ptr::null(),
                ptr::null(),
                ptr::null(),
                ptr::null(),
                0,
                ptr::null(),
                0,
                ptr::null(),
                10,
                100,
                false,
            )
        };
        assert!(!result.is_null());
        unsafe {
            assert!(linthra_eviction_result_fits(result));
            assert_eq!(linthra_eviction_result_len(result), 0);
            linthra_eviction_result_free(result);
        }
    }

    #[test]
    fn a_span_outside_the_buffer_is_refused() {
        let text = b"jellyfina";
        let spans: [u32; 4] = [0, 8, 8, 5];
        let result = unsafe {
            linthra_eviction_plan(
                text.as_ptr(),
                text.len(),
                spans.as_ptr(),
                [1i64].as_ptr(),
                [0i64].as_ptr(),
                [0i64].as_ptr(),
                [EVICTION_MANAGED].as_ptr(),
                1,
                ptr::null(),
                0,
                ptr::null(),
                1,
                1,
                false,
            )
        };
        assert!(result.is_null());
    }

    #[test]
    fn null_results_read_as_empty() {
        unsafe {
            assert!(!linthra_eviction_result_fits(ptr::null()));
            assert_eq!(linthra_eviction_result_len(ptr::null()), 0);
            assert!(linthra_eviction_result_indices(ptr::null()).is_null());
            linthra_eviction_result_free(ptr::null_mut());
        }
    }
}
