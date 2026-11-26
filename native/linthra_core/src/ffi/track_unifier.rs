//! C ABI for [crate::track_unifier]: the whole catalog in one call.
//!
//! Every track's uri, title, artist and album go into one UTF-8 buffer, each
//! a span of two `u32`s (start, length), eight per track in that order. The
//! numbers go as parallel arrays; a track with no number is `i64::MIN`. The
//! rows come back as one array of indices and the offsets where each row
//! starts.

use std::ptr;

use crate::track_unifier::{is_current_playback, unify, UnifyTrack};

/// The library rows, kept until freed.
pub struct UnifyResult {
    /// `rows + 1` offsets into `indices`.
    starts: Vec<u32>,
    indices: Vec<u32>,
}

/// Unifies `count` tracks. Returns null when an array is null while `count`
/// is not 0, or a span falls outside `text` or isn't UTF-8. Free the result
/// with [linthra_unify_free].
///
/// # Safety
///
/// `text` must be valid for `text_len` bytes, `spans` for `8 * count`
/// values, and `sources`, `ranks`, `durations` and `track_numbers` for
/// `count` each.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn linthra_unify_tracks(
    text: *const u8,
    text_len: usize,
    spans: *const u32,
    sources: *const u32,
    ranks: *const u32,
    durations: *const i64,
    track_numbers: *const i64,
    count: usize,
) -> *mut UnifyResult {
    let Some(tracks) = read_tracks(
        text,
        text_len,
        spans,
        sources,
        ranks,
        durations,
        track_numbers,
        count,
    ) else {
        return ptr::null_mut();
    };
    let rows = unify(&tracks);
    let mut starts = Vec::with_capacity(rows.len() + 1);
    let mut indices = Vec::with_capacity(count);
    for row in rows {
        starts.push(indices.len() as u32);
        indices.extend(row);
    }
    starts.push(indices.len() as u32);
    Box::into_raw(Box::new(UnifyResult { starts, indices }))
}

/// Whether `row` is the playing `current` track: `isCurrentPlaybackTrack`
/// (lib/core/catalog/now_playing_match.dart). The two tracks are laid out as
/// for [linthra_unify_tracks] with a count of 2, `row` first. Returns 1 or
/// 0, or [CURRENT_TRACK_INVALID] when an array is null or a span falls
/// outside `text` or isn't UTF-8.
///
/// # Safety
///
/// As for [linthra_unify_tracks] with a count of 2.
#[no_mangle]
pub unsafe extern "C" fn linthra_is_current_track(
    text: *const u8,
    text_len: usize,
    spans: *const u32,
    sources: *const u32,
    durations: *const i64,
    track_numbers: *const i64,
) -> u8 {
    let ranks = [0u32; 2];
    match read_tracks(
        text,
        text_len,
        spans,
        sources,
        ranks.as_ptr(),
        durations,
        track_numbers,
        2,
    ) {
        Some(tracks) => is_current_playback(&tracks[0], &tracks[1]) as u8,
        None => CURRENT_TRACK_INVALID,
    }
}

/// [linthra_is_current_track]'s answer to input it could not read.
pub const CURRENT_TRACK_INVALID: u8 = 255;

/// The `count` tracks the arrays describe, or None when one is null while
/// `count` is not 0, or a span falls outside `text` or isn't UTF-8.
///
/// # Safety
///
/// As for [linthra_unify_tracks].
#[allow(clippy::too_many_arguments)]
unsafe fn read_tracks<'a>(
    text: *const u8,
    text_len: usize,
    spans: *const u32,
    sources: *const u32,
    ranks: *const u32,
    durations: *const i64,
    track_numbers: *const i64,
    count: usize,
) -> Option<Vec<UnifyTrack<'a>>> {
    let slice = |p: *const u8, n: usize| {
        if n == 0 {
            Some(&[][..])
        } else if p.is_null() {
            None
        } else {
            Some(std::slice::from_raw_parts(p, n))
        }
    };
    let text = slice(text, text_len)?;
    if count > 0
        && (spans.is_null()
            || sources.is_null()
            || ranks.is_null()
            || durations.is_null()
            || track_numbers.is_null())
    {
        return None;
    }
    let read = |i: usize| -> Option<UnifyTrack> {
        let span = std::slice::from_raw_parts(spans.add(8 * i), 8);
        let part = |k: usize| {
            let start = span[2 * k] as usize;
            let bytes = text.get(start..start.checked_add(span[2 * k + 1] as usize)?)?;
            std::str::from_utf8(bytes).ok()
        };
        let number = *track_numbers.add(i);
        Some(UnifyTrack {
            uri: part(0)?,
            title: part(1)?,
            artist: part(2)?,
            album: part(3)?,
            source: *sources.add(i),
            rank: *ranks.add(i),
            duration_secs: *durations.add(i),
            track_number: (number != i64::MIN).then_some(number),
        })
    };
    (0..count).map(read).collect()
}

/// How many rows. 0 for a null `result`.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_unify_tracks].
#[no_mangle]
pub unsafe extern "C" fn linthra_unify_rows(result: *const UnifyResult) -> usize {
    result.as_ref().map_or(0, |r| r.starts.len() - 1)
}

/// The rows' start offsets, rows + 1 of them, valid until freed.
///
/// # Safety
///
/// As for [linthra_unify_rows].
#[no_mangle]
pub unsafe extern "C" fn linthra_unify_starts(result: *const UnifyResult) -> *const u32 {
    result.as_ref().map_or(ptr::null(), |r| r.starts.as_ptr())
}

/// The track indices of every row, back to back, valid until freed.
///
/// # Safety
///
/// As for [linthra_unify_rows].
#[no_mangle]
pub unsafe extern "C" fn linthra_unify_indices(result: *const UnifyResult) -> *const u32 {
    result.as_ref().map_or(ptr::null(), |r| r.indices.as_ptr())
}

/// Frees a result. Null is a no-op.
///
/// # Safety
///
/// `result` must be null or a pointer from [linthra_unify_tracks] that has not
/// been freed yet.
#[no_mangle]
pub unsafe extern "C" fn linthra_unify_free(result: *mut UnifyResult) {
    if !result.is_null() {
        drop(Box::from_raw(result));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unifies_across_the_boundary() {
        let fields = [
            ["jellyfin:1", "Song", "Artist", "Album"],
            ["subsonic:1", "Song", "Artist", "Album"],
        ];
        let mut text = Vec::new();
        let mut spans = Vec::new();
        for track in fields {
            for part in track {
                spans.push(text.len() as u32);
                spans.push(part.len() as u32);
                text.extend_from_slice(part.as_bytes());
            }
        }
        unsafe {
            let result = linthra_unify_tracks(
                text.as_ptr(),
                text.len(),
                spans.as_ptr(),
                [0u32, 1].as_ptr(),
                [0u32, 1].as_ptr(),
                [200i64, 200].as_ptr(),
                [i64::MIN, i64::MIN].as_ptr(),
                2,
            );
            assert_eq!(linthra_unify_rows(result), 1);
            assert_eq!(
                std::slice::from_raw_parts(linthra_unify_starts(result), 2),
                [0, 2]
            );
            assert_eq!(
                std::slice::from_raw_parts(linthra_unify_indices(result), 2),
                [0, 1]
            );
            linthra_unify_free(result);
            assert!(linthra_unify_tracks(
                text.as_ptr(),
                3,
                spans.as_ptr(),
                [0u32, 1].as_ptr(),
                [0u32, 1].as_ptr(),
                [200i64, 200].as_ptr(),
                [i64::MIN, i64::MIN].as_ptr(),
                2
            )
            .is_null());
        }
    }

    #[test]
    fn answers_the_playing_question_through_the_abi() {
        let fields = [
            "jellyfin:1",
            "Hello",
            "Adele",
            "25",
            "subsonic:1",
            "Hello",
            "Adele",
            "25 (Deluxe)",
        ];
        let mut text = Vec::new();
        let mut spans = Vec::new();
        for field in fields {
            spans.extend([text.len() as u32, field.len() as u32]);
            text.extend_from_slice(field.as_bytes());
        }
        let sources = [0u32, 1];
        let durations = [180i64, 181];
        let numbers = [i64::MIN, i64::MIN];
        let answer = |sources: &[u32; 2]| unsafe {
            linthra_is_current_track(
                text.as_ptr(),
                text.len(),
                spans.as_ptr(),
                sources.as_ptr(),
                durations.as_ptr(),
                numbers.as_ptr(),
            )
        };
        assert_eq!(answer(&sources), 1);
        assert_eq!(answer(&[0, 0]), 0);
        let refused = unsafe {
            linthra_is_current_track(
                text.as_ptr(),
                1,
                spans.as_ptr(),
                sources.as_ptr(),
                durations.as_ptr(),
                numbers.as_ptr(),
            )
        };
        assert_eq!(refused, CURRENT_TRACK_INVALID);
    }
}
