//! C ABI for [crate::song_sort]: the songs to sort, then the catalog their
//! albums are filed against, in one call.
//!
//! Each entry's uri, title, lower-cased title, artist, album and album
//! artist, and album id go into one UTF-8 buffer as spans (start, length),
//! fourteen `u32`s per entry in that order. Disc, track and date added are
//! parallel `i64` arrays, `i64::MIN` for none. The first `count` entries are
//! the songs, the next `catalog_count` the catalog (none: the songs are
//! their own catalog).

use std::ptr;

use crate::song_sort::{sort_songs, SortField, SortTrack, Sorted};

/// Returns null when `field` is unknown, an array is null while its length
/// is not 0, or a span falls outside `text` or isn't UTF-8. Free the result
/// with [linthra_song_sort_free].
///
/// # Safety
///
/// `text` must be valid for `text_len` bytes, `spans` for `14 * n` values,
/// and `discs`, `tracks` and `added` for `n` each, where `n` is `count +
/// catalog_count`.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn linthra_song_sort(
    text: *const u8,
    text_len: usize,
    spans: *const u32,
    discs: *const i64,
    tracks: *const i64,
    added: *const i64,
    count: usize,
    catalog_count: usize,
    field: u8,
    descending: bool,
) -> *mut Sorted {
    crate::ffi::guard(ptr::null_mut(), || {
        crate::ffi::fail_safe(
            || {
                let Some(field) = SortField::from_code(field) else {
                    return ptr::null_mut();
                };
                let n = count + catalog_count;
                let text = if text_len == 0 {
                    &[][..]
                } else if text.is_null() {
                    return ptr::null_mut();
                } else {
                    std::slice::from_raw_parts(text, text_len)
                };
                if n > 0
                    && (spans.is_null() || discs.is_null() || tracks.is_null() || added.is_null())
                {
                    return ptr::null_mut();
                }
                let number = |p: *const i64, i: usize| {
                    let v = *p.add(i);
                    (v != i64::MIN).then_some(v)
                };
                let read = |i: usize| -> Option<SortTrack> {
                    let span = std::slice::from_raw_parts(spans.add(14 * i), 14);
                    let part = |k: usize| {
                        let start = span[2 * k] as usize;
                        let bytes =
                            text.get(start..start.checked_add(span[2 * k + 1] as usize)?)?;
                        std::str::from_utf8(bytes).ok()
                    };
                    Some(SortTrack {
                        uri: part(0)?,
                        title: part(1)?,
                        title_lower: part(2)?,
                        artist_lower: part(3)?,
                        album_lower: part(4)?,
                        album_artist_lower: part(5)?,
                        album_id: part(6)?,
                        disc: number(discs, i),
                        track: number(tracks, i),
                        added_at: number(added, i),
                    })
                };
                let Some(entries) = (0..n).map(read).collect::<Option<Vec<_>>>() else {
                    return ptr::null_mut();
                };
                let (songs, catalog) = entries.split_at(count);
                Box::into_raw(Box::new(sort_songs(songs, catalog, field, descending)))
            },
            || {
                Box::into_raw(Box::new(Sorted {
                    // Safe answer: the order given, all under '#' (no sections by date).
                    order: (0..count as u32).collect(),
                    sections: if field == 3 {
                        Vec::new()
                    } else {
                        vec![b'#'; count]
                    },
                }))
            },
        )
    })
}

/// The sorted order, `count` positions, valid until freed.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_song_sort].
#[no_mangle]
pub unsafe extern "C" fn linthra_song_sort_order(result: *const Sorted) -> *const u32 {
    crate::ffi::guard(ptr::null(), || {
        result.as_ref().map_or(ptr::null(), |r| r.order.as_ptr())
    })
}

/// Each sorted song's section as an ASCII character, or null for an order
/// with no sections.
///
/// # Safety
///
/// As for [linthra_song_sort_order].
#[no_mangle]
pub unsafe extern "C" fn linthra_song_sort_sections(result: *const Sorted) -> *const u8 {
    crate::ffi::guard(ptr::null(), || {
        result
            .as_ref()
            .filter(|r| !r.sections.is_empty())
            .map_or(ptr::null(), |r| r.sections.as_ptr())
    })
}

/// Frees a result. Null is a no-op.
///
/// # Safety
///
/// `result` must be null or a pointer from [linthra_song_sort] not yet freed.
#[no_mangle]
pub unsafe extern "C" fn linthra_song_sort_free(result: *mut Sorted) {
    crate::ffi::guard((), || {
        if !result.is_null() {
            drop(Box::from_raw(result));
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sorts_across_the_boundary() {
        let entries = [
            ["u:1", "Beta", "beta", "", "", "", ""],
            ["u:2", "Alpha", "alpha", "", "", "", ""],
        ];
        let mut text = Vec::new();
        let mut spans = Vec::new();
        for entry in entries {
            for part in entry {
                spans.push(text.len() as u32);
                spans.push(part.len() as u32);
                text.extend_from_slice(part.as_bytes());
            }
        }
        let none = [i64::MIN, i64::MIN];
        unsafe {
            let result = linthra_song_sort(
                text.as_ptr(),
                text.len(),
                spans.as_ptr(),
                none.as_ptr(),
                none.as_ptr(),
                none.as_ptr(),
                2,
                0,
                0,
                false,
            );
            assert_eq!(
                std::slice::from_raw_parts(linthra_song_sort_order(result), 2),
                [1, 0]
            );
            assert_eq!(
                std::slice::from_raw_parts(linthra_song_sort_sections(result), 2),
                b"AB"
            );
            linthra_song_sort_free(result);
            let dated = linthra_song_sort(
                text.as_ptr(),
                text.len(),
                spans.as_ptr(),
                none.as_ptr(),
                none.as_ptr(),
                none.as_ptr(),
                2,
                0,
                3,
                true,
            );
            assert!(linthra_song_sort_sections(dated).is_null());
            linthra_song_sort_free(dated);
            assert!(linthra_song_sort(
                text.as_ptr(),
                text.len(),
                spans.as_ptr(),
                none.as_ptr(),
                none.as_ptr(),
                none.as_ptr(),
                2,
                0,
                9,
                false
            )
            .is_null());
        }
    }
}
