//! C ABI for [crate::local_reconcile]: one call per scan.
//!
//! The previous tracks come first, then the scanned ones, `count` in all.
//! Each track's uri, title, artist, album, album artist and album id go into
//! one UTF-8 buffer, as twelve `u32`s per track (start and length of each, in
//! that order). Durations (microseconds) and track numbers go as parallel
//! arrays; a track with no number is `i64::MIN`. `refreshed` has one byte per
//! previous track, non-zero when the scan read its folder.

use std::ptr;

use crate::local_reconcile::{resolve, ReconcileTrack, Reconciliation};

/// The answer, kept until freed.
pub struct ReconcileResult {
    /// (previous, scanned) position pairs, flattened.
    moves: Vec<u32>,
    removed: Vec<u32>,
}

/// Reconciles `previous_count` previous tracks against the
/// `count - previous_count` scanned after them. Returns null when an array is
/// null while its length is not 0, `previous_count` exceeds `count`, a span
/// falls outside `text` or isn't UTF-8, or there are more tracks than a `u32`
/// can index. Free the result with [linthra_reconcile_free].
///
/// # Safety
///
/// `text` must be valid for `text_len` bytes, `spans` for `12 * count`
/// values, `durations` and `track_numbers` for `count` each, and `refreshed`
/// for `previous_count`.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn linthra_local_reconcile(
    text: *const u8,
    text_len: usize,
    spans: *const u32,
    durations: *const i64,
    track_numbers: *const i64,
    refreshed: *const u8,
    previous_count: usize,
    count: usize,
) -> *mut ReconcileResult {
    let input = || -> Option<ReconcileResult> {
        u32::try_from(count).ok()?;
        if previous_count > count {
            return None;
        }
        let text = array(text, text_len)?;
        let spans = array(spans, count.checked_mul(12)?)?;
        let durations = array(durations, count)?;
        let numbers = array(track_numbers, count)?;
        let refreshed: Vec<bool> = array(refreshed, previous_count)?
            .iter()
            .map(|&b| b != 0)
            .collect();
        let tracks = (0..count)
            .map(|i| {
                let s = &spans[12 * i..12 * i + 12];
                Some(ReconcileTrack {
                    uri: part(text, s[0], s[1])?,
                    title: part(text, s[2], s[3])?,
                    artist: part(text, s[4], s[5])?,
                    album: part(text, s[6], s[7])?,
                    album_artist: part(text, s[8], s[9])?,
                    album_id: part(text, s[10], s[11])?,
                    duration_micros: durations[i],
                    track_number: (numbers[i] != i64::MIN).then_some(numbers[i]),
                })
            })
            .collect::<Option<Vec<_>>>()?;
        let (previous, scanned) = tracks.split_at(previous_count);
        let Reconciliation { moves, removed } = resolve(previous, &refreshed, scanned);
        Some(ReconcileResult {
            moves: moves
                .into_iter()
                .flat_map(|(from, to)| [from as u32, to as u32])
                .collect(),
            removed: removed.into_iter().map(|i| i as u32).collect(),
        })
    };
    match input() {
        Some(result) => Box::into_raw(Box::new(result)),
        None => ptr::null_mut(),
    }
}

/// How many moves `result` holds. 0 for null.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_local_reconcile].
#[no_mangle]
pub unsafe extern "C" fn linthra_reconcile_move_count(result: *const ReconcileResult) -> usize {
    result.as_ref().map_or(0, |r| r.moves.len() / 2)
}

/// The moves, two `u32`s each (previous, then scanned position). Null for
/// null.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_local_reconcile].
#[no_mangle]
pub unsafe extern "C" fn linthra_reconcile_moves(result: *const ReconcileResult) -> *const u32 {
    result.as_ref().map_or(ptr::null(), |r| r.moves.as_ptr())
}

/// How many previous tracks are gone. 0 for null.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_local_reconcile].
#[no_mangle]
pub unsafe extern "C" fn linthra_reconcile_removed_count(result: *const ReconcileResult) -> usize {
    result.as_ref().map_or(0, |r| r.removed.len())
}

/// The positions of the previous tracks that are gone. Null for null.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_local_reconcile].
#[no_mangle]
pub unsafe extern "C" fn linthra_reconcile_removed(result: *const ReconcileResult) -> *const u32 {
    result.as_ref().map_or(ptr::null(), |r| r.removed.as_ptr())
}

/// Frees a result. Null is a no-op.
///
/// # Safety
///
/// `result` must be null or a pointer from [linthra_local_reconcile] that has
/// not been freed yet.
#[no_mangle]
pub unsafe extern "C" fn linthra_reconcile_free(result: *mut ReconcileResult) {
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
    fn reconciles_through_the_abi() {
        let fields = [
            ["/a/1.flac", "one", "x", "y", "", ""],
            ["/b/1.flac", "one", "x", "y", "", ""],
        ];
        let mut text = Vec::new();
        let mut spans = Vec::new();
        for field in fields.iter().flatten() {
            spans.extend([text.len() as u32, field.len() as u32]);
            text.extend_from_slice(field.as_bytes());
        }
        let durations = [180_000_000i64, 180_000_000];
        let numbers = [i64::MIN, i64::MIN];
        unsafe {
            let result = linthra_local_reconcile(
                text.as_ptr(),
                text.len(),
                spans.as_ptr(),
                durations.as_ptr(),
                numbers.as_ptr(),
                [1u8].as_ptr(),
                1,
                2,
            );
            assert!(!result.is_null());
            assert_eq!(linthra_reconcile_move_count(result), 1);
            assert_eq!(
                std::slice::from_raw_parts(linthra_reconcile_moves(result), 2),
                [0, 0]
            );
            assert_eq!(linthra_reconcile_removed_count(result), 0);
            linthra_reconcile_free(result);
        }
    }

    #[test]
    fn refuses_more_previous_tracks_than_tracks() {
        let result = unsafe {
            linthra_local_reconcile(
                ptr::null(),
                0,
                ptr::null(),
                ptr::null(),
                ptr::null(),
                [1u8].as_ptr(),
                1,
                0,
            )
        };
        assert!(result.is_null());
    }
}
