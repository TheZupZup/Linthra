//! C ABI for [crate::track_unifier]: one call merges the whole catalog.
//!
//! As for the grouping, strings do not cross one by one. Every track's title,
//! artist, album and uri go into one UTF-8 buffer, and each track is a span of
//! eight `u32`s into it (start and length of each field, in that order). The
//! numbers come in two more arrays: three `i64`s per track (duration in
//! seconds, 1 or 0 for whether it has a track number, the track number) and
//! two `u32`s (provider, provider rank).
//!
//! The answer is the logical tracks, flattened: `count + 1` offsets into one
//! array of track positions.

use std::ptr;

use crate::track_unifier::{unify, UnifierTrack};

/// The logical tracks, kept alive until freed.
pub struct UnifyResult {
    offsets: Vec<u32>,
    members: Vec<u32>,
}

/// Borrowed pointers into a [UnifyResult]. Both arrays are non-null, even
/// when empty, and valid until the result is freed.
#[repr(C)]
pub struct UnifyView {
    pub count: usize,
    /// `count + 1` offsets into `members`; logical track `i` is
    /// `members[offsets[i]..offsets[i + 1]]`, best copy first.
    pub offsets: *const u32,
    pub members: *const u32,
}

/// Merges `count` tracks. The title, artist and album must already be
/// lower-cased with Dart's `String.toLowerCase`; the uri is passed as is.
///
/// Returns null when an array is null while its length is not zero, a span
/// falls outside `text` or is not UTF-8, or there are more tracks than a `u32`
/// can index. Free the result with [linthra_unify_result_free].
///
/// # Safety
///
/// Each pointer must be null or valid for reads of the length given above
/// (`8 * count` spans, `3 * count` numbers, `2 * count` sources), for the
/// duration of the call.
#[no_mangle]
pub unsafe extern "C" fn linthra_unify_tracks(
    text: *const u8,
    text_len: usize,
    spans: *const u32,
    numbers: *const i64,
    sources: *const u32,
    count: usize,
) -> *mut UnifyResult {
    let input = || -> Option<UnifyResult> {
        u32::try_from(count).ok()?;
        let text = array(text, text_len)?;
        let spans = array(spans, count.checked_mul(8)?)?;
        let numbers = array(numbers, count.checked_mul(3)?)?;
        let sources = array(sources, count.checked_mul(2)?)?;
        let tracks = (0..count)
            .map(|i| {
                let span = &spans[8 * i..8 * i + 8];
                let number = &numbers[3 * i..3 * i + 3];
                Some(UnifierTrack {
                    title: part(text, span[0], span[1])?,
                    artist: part(text, span[2], span[3])?,
                    album: part(text, span[4], span[5])?,
                    uri: part(text, span[6], span[7])?,
                    duration_seconds: number[0],
                    track_number: (number[1] != 0).then_some(number[2]),
                    source: sources[2 * i],
                    rank: sources[2 * i + 1],
                })
            })
            .collect::<Option<Vec<_>>>()?;
        let logical = unify(&tracks);
        let mut offsets = Vec::with_capacity(logical.len() + 1);
        let mut members = Vec::with_capacity(count);
        offsets.push(0);
        for copies in logical {
            members.extend(copies.into_iter().map(|i| i as u32));
            offsets.push(members.len() as u32);
        }
        Some(UnifyResult { offsets, members })
    };
    match input() {
        Some(result) => Box::into_raw(Box::new(result)),
        None => ptr::null_mut(),
    }
}

/// The arrays of `result`. Zero and null for a null `result`.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_unify_tracks].
#[no_mangle]
pub unsafe extern "C" fn linthra_unify_result_view(result: *const UnifyResult) -> UnifyView {
    match result.as_ref() {
        Some(r) => UnifyView {
            count: r.offsets.len() - 1,
            offsets: r.offsets.as_ptr(),
            members: r.members.as_ptr(),
        },
        None => UnifyView {
            count: 0,
            offsets: ptr::null(),
            members: ptr::null(),
        },
    }
}

/// Frees a result. Null is a no-op.
///
/// # Safety
///
/// `result` must be null or a pointer from [linthra_unify_tracks] that has
/// not been freed yet.
#[no_mangle]
pub unsafe extern "C" fn linthra_unify_result_free(result: *mut UnifyResult) {
    if !result.is_null() {
        drop(Box::from_raw(result));
    }
}

/// `len` items at `data`, or None for a null `data` with a non-zero `len`.
///
/// # Safety
///
/// As for [std::slice::from_raw_parts] when `data` is not null.
unsafe fn array<'a, T>(data: *const T, len: usize) -> Option<&'a [T]> {
    if len == 0 {
        Some(&[])
    } else if data.is_null() {
        None
    } else {
        Some(std::slice::from_raw_parts(data, len))
    }
}

/// The text a span names, or None when it falls outside `text` or is not
/// UTF-8.
fn part(text: &[u8], start: u32, len: u32) -> Option<&str> {
    let start = start as usize;
    let bytes = text.get(start..start.checked_add(len as usize)?)?;
    std::str::from_utf8(bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merges_through_the_abi() {
        let fields = [
            ["hello", "adele", "25", "jellyfin:1"],
            ["hello", "adele", "25 (deluxe)", "subsonic:1"],
        ];
        let mut text = Vec::new();
        let mut spans = Vec::new();
        for field in fields.iter().flatten() {
            spans.extend([text.len() as u32, field.len() as u32]);
            text.extend_from_slice(field.as_bytes());
        }
        let numbers = [180i64, 0, 0, 181, 0, 0];
        let sources = [0u32, 0, 1, 1];
        unsafe {
            let result = linthra_unify_tracks(
                text.as_ptr(),
                text.len(),
                spans.as_ptr(),
                numbers.as_ptr(),
                sources.as_ptr(),
                2,
            );
            assert!(!result.is_null());
            let view = linthra_unify_result_view(result);
            assert_eq!(view.count, 1);
            assert_eq!(std::slice::from_raw_parts(view.offsets, 2), [0, 2]);
            assert_eq!(std::slice::from_raw_parts(view.members, 2), [0, 1]);
            linthra_unify_result_free(result);
        }
    }

    #[test]
    fn refuses_a_span_outside_the_text() {
        let spans = [0u32, 9, 0, 0, 0, 0, 0, 0];
        let numbers = [1i64, 0, 0];
        let sources = [0u32, 0];
        let result = unsafe {
            linthra_unify_tracks(
                b"abc".as_ptr(),
                3,
                spans.as_ptr(),
                numbers.as_ptr(),
                sources.as_ptr(),
                1,
            )
        };
        assert!(result.is_null());
    }

    #[test]
    fn handles_an_empty_catalog() {
        unsafe {
            let result =
                linthra_unify_tracks(ptr::null(), 0, ptr::null(), ptr::null(), ptr::null(), 0);
            let view = linthra_unify_result_view(result);
            assert_eq!(view.count, 0);
            linthra_unify_result_free(result);
        }
    }
}
