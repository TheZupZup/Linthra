//! C ABI for [crate::optical]. A TOC crosses as parallel arrays (track
//! number, start LBA, 1 for a data track), CD-Text as the drive's raw bytes.

use std::ptr;

use crate::optical::{
    cd_text, music_brainz_disc_id, normalized_entries, playable_tracks, CdText, Toc, TocEntry,
};

/// [linthra_cd_text_count] and friends: which list.
pub const CD_TEXT_TITLES: u8 = 0;
pub const CD_TEXT_PERFORMERS: u8 = 1;

/// The length of every disc id: 20 bytes of SHA-1 in base64.
pub const DISC_ID_LENGTH: usize = 28;

/// Decodes a CD-Text response. Null when the disc has no CD-Text this
/// decoder trusts, or when `bytes` is null with a non-zero length. Free a
/// result with [linthra_cd_text_free].
///
/// # Safety
///
/// `bytes` must be null or valid for reads of `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn linthra_cd_text(bytes: *const u8, len: usize) -> *mut CdText {
    match array(bytes, len).and_then(cd_text) {
        Some(text) => Box::into_raw(Box::new(text)),
        None => ptr::null_mut(),
    }
}

/// How many texts `list` holds. 0 for null or an unknown list.
///
/// # Safety
///
/// `text` must be null or live from [linthra_cd_text].
#[no_mangle]
pub unsafe extern "C" fn linthra_cd_text_count(text: *const CdText, list: u8) -> usize {
    texts(text, list).map_or(0, <[_]>::len)
}

/// The item (0 the disc, 1-99 a track) of text `i` in `list`. 0 when out of
/// range.
///
/// # Safety
///
/// `text` must be null or live from [linthra_cd_text].
#[no_mangle]
pub unsafe extern "C" fn linthra_cd_text_item(text: *const CdText, list: u8, i: usize) -> u32 {
    texts(text, list)
        .and_then(|t| t.get(i))
        .map_or(0, |(item, _)| *item)
}

/// Text `i` of `list` as Latin-1 bytes, its length written to `len`. Null
/// (and 0) when out of range.
///
/// # Safety
///
/// `text` must be null or live from [linthra_cd_text]; `len` must be valid
/// for one write. The bytes live until the text is freed.
#[no_mangle]
pub unsafe extern "C" fn linthra_cd_text_value(
    text: *const CdText,
    list: u8,
    i: usize,
    len: *mut usize,
) -> *const u8 {
    let value = texts(text, list).and_then(|t| t.get(i)).map(|(_, v)| v);
    if !len.is_null() {
        *len = value.map_or(0, Vec::len);
    }
    value.map_or(ptr::null(), |v| v.as_ptr())
}

/// Frees a CD-Text result. Null is a no-op.
///
/// # Safety
///
/// `text` must be null or a pointer from [linthra_cd_text] not yet freed.
#[no_mangle]
pub unsafe extern "C" fn linthra_cd_text_free(text: *mut CdText) {
    if !text.is_null() {
        drop(Box::from_raw(text));
    }
}

/// `normalizedTocEntries`: writes the positions of the entries in track order
/// to `order` and returns how many, or -1 when the TOC contradicts itself or
/// an array is null with a non-zero `count`.
///
/// # Safety
///
/// `numbers`, `starts` and `data` must be valid for `count` reads, `order`
/// for `count` writes.
#[no_mangle]
pub unsafe extern "C" fn linthra_cd_toc_order(
    first_track: i64,
    last_track: i64,
    lead_out_lba: i64,
    numbers: *const i64,
    starts: *const i64,
    data: *const u8,
    count: usize,
    order: *mut u32,
) -> i64 {
    let Some(entries) = entries(numbers, starts, data, count) else {
        return -1;
    };
    let toc = Toc {
        first_track,
        last_track,
        lead_out_lba,
        entries: &entries,
    };
    match normalized_entries(&toc) {
        Some(positions) if order.is_null() && !positions.is_empty() => -1,
        Some(positions) => {
            for (k, &p) in positions.iter().enumerate() {
                *order.add(k) = p as u32;
            }
            positions.len() as i64
        }
        None => -1,
    }
}

/// `playableAudioTracks` over `count` entries already in track order: writes
/// three values per track (number, start frame, frame count) to `out` and
/// returns how many tracks, or -1 when an array is null with a non-zero
/// `count`.
///
/// # Safety
///
/// `numbers`, `starts` and `data` must be valid for `count` reads, `out` for
/// `3 * count` writes.
#[no_mangle]
pub unsafe extern "C" fn linthra_cd_playable_tracks(
    numbers: *const i64,
    starts: *const i64,
    data: *const u8,
    count: usize,
    lead_out_lba: i64,
    out: *mut i64,
) -> i64 {
    let Some(entries) = entries(numbers, starts, data, count) else {
        return -1;
    };
    let tracks = playable_tracks(&entries, lead_out_lba);
    if out.is_null() && !tracks.is_empty() {
        return -1;
    }
    for (k, t) in tracks.iter().enumerate() {
        *out.add(3 * k) = t.number;
        *out.add(3 * k + 1) = t.start_frame;
        *out.add(3 * k + 2) = t.frame_count;
    }
    tracks.len() as i64
}

/// `musicBrainzDiscId`: writes the id's [DISC_ID_LENGTH] ASCII bytes to `out`
/// and returns 1, or returns 0 when the TOC cannot produce one, -1 when an
/// array is null with a non-zero `count`.
///
/// # Safety
///
/// `numbers`, `starts` and `data` must be valid for `count` reads, `out` for
/// [DISC_ID_LENGTH] writes.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn linthra_cd_disc_id(
    first_track: i64,
    last_track: i64,
    lead_out_lba: i64,
    numbers: *const i64,
    starts: *const i64,
    data: *const u8,
    count: usize,
    out: *mut u8,
) -> i32 {
    let Some(entries) = entries(numbers, starts, data, count) else {
        return -1;
    };
    let toc = Toc {
        first_track,
        last_track,
        lead_out_lba,
        entries: &entries,
    };
    match music_brainz_disc_id(&toc) {
        Some(id) if id.len() == DISC_ID_LENGTH && !out.is_null() => {
            ptr::copy_nonoverlapping(id.as_ptr(), out, DISC_ID_LENGTH);
            1
        }
        Some(_) => -1,
        None => 0,
    }
}

unsafe fn texts<'a>(text: *const CdText, list: u8) -> Option<&'a [(u32, Vec<u8>)]> {
    let text = text.as_ref()?;
    match list {
        CD_TEXT_TITLES => Some(&text.titles),
        CD_TEXT_PERFORMERS => Some(&text.performers),
        _ => None,
    }
}

unsafe fn entries(
    numbers: *const i64,
    starts: *const i64,
    data: *const u8,
    count: usize,
) -> Option<Vec<TocEntry>> {
    let numbers = array(numbers, count)?;
    let starts = array(starts, count)?;
    let data = array(data, count)?;
    Some(
        (0..count)
            .map(|i| TocEntry {
                number: numbers[i],
                start_lba: starts[i],
                is_data: data[i] != 0,
            })
            .collect(),
    )
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifies_a_disc_through_the_abi() {
        let numbers = [1i64, 2];
        let starts = [0i64, 15000];
        let data = [0u8, 0];
        let mut out = [0u8; DISC_ID_LENGTH];
        let answer = unsafe {
            linthra_cd_disc_id(
                1,
                2,
                30000,
                numbers.as_ptr(),
                starts.as_ptr(),
                data.as_ptr(),
                2,
                out.as_mut_ptr(),
            )
        };
        assert_eq!(answer, 1);
        assert!(out.iter().all(|b| b.is_ascii_graphic()));
        let mut order = [9u32; 2];
        let n = unsafe {
            linthra_cd_toc_order(
                1,
                2,
                30000,
                numbers.as_ptr(),
                starts.as_ptr(),
                data.as_ptr(),
                2,
                order.as_mut_ptr(),
            )
        };
        assert_eq!((n, order), (2, [0, 1]));
    }

    #[test]
    fn has_no_text_for_an_empty_response() {
        assert!(unsafe { linthra_cd_text([0u8, 2, 0, 0].as_ptr(), 4) }.is_null());
    }
}
