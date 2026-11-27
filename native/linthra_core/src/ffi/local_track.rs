//! C ABI for [crate::scan::mapper]. The inputs cross as one UTF-8 buffer with
//! a start and a length for each text (a negative length for one that is
//! absent), so text holding NUL crosses as it is; the answer is read back one
//! field at a call, as for the CUE sheets.

use std::ptr;

use crate::scan::mapper::{from_cue, from_document, from_path, CueTrack, Mapped, Metadata};

/// What [linthra_local_track_map] maps.
pub const LOCAL_TRACK_PATH: u8 = 0;
pub const LOCAL_TRACK_DOCUMENT: u8 = 1;
pub const LOCAL_TRACK_CUE: u8 = 2;

/// The texts, in this order: the file's path (a document's name, a CUE
/// track's audio path), the scan root, then the tags' title, artist, album,
/// album artist and album id, then the CUE track's title, performer, album
/// and album performer.
pub const LOCAL_TRACK_TEXTS: usize = 11;

/// The numbers, each a (present, value) pair: the tags' track number and
/// duration (µs), then the CUE track's number, start (µs) and end (µs).
pub const LOCAL_TRACK_NUMBERS: usize = 5;

/// Text fields of the answer, for [linthra_mapped_text].
pub const MAPPED_TITLE: u8 = 0;
pub const MAPPED_ARTIST: u8 = 1;
pub const MAPPED_ALBUM: u8 = 2;
pub const MAPPED_ALBUM_ID: u8 = 3;
pub const MAPPED_ALBUM_ARTIST: u8 = 4;

/// Number fields of the answer, for [linthra_mapped_number].
pub const MAPPED_TRACK_NUMBER: u8 = 0;
pub const MAPPED_DURATION_US: u8 = 1;
pub const MAPPED_CUE_END_US: u8 = 2;

/// A mapped track, kept until freed.
pub struct MappedTrack {
    mapped: Mapped,
}

/// Maps one file as `LocalTrackMapper` does. `bounds` holds a (start,
/// length) pair per text into `text` ([LOCAL_TRACK_TEXTS] pairs), `numbers`
/// a (present, value) pair per number ([LOCAL_TRACK_NUMBERS] pairs). Returns
/// null for an unknown `kind`, a null array, a text out of `text`'s bounds or
/// not UTF-8. Free it with [linthra_mapped_free].
///
/// # Safety
///
/// `text` must be null or valid for reads of `text_len` bytes; `bounds` and
/// `numbers` must be null or valid for reads of `2 * LOCAL_TRACK_TEXTS` and
/// `2 * LOCAL_TRACK_NUMBERS` values.
#[no_mangle]
pub unsafe extern "C" fn linthra_local_track_map(
    kind: u8,
    text: *const u8,
    text_len: usize,
    bounds: *const i64,
    numbers: *const i64,
) -> *mut MappedTrack {
    crate::ffi::guard(ptr::null_mut(), || {
        crate::ffi::fail_safe(
            || match map(kind, text, text_len, bounds, numbers) {
                Some(mapped) => Box::into_raw(Box::new(MappedTrack { mapped })),
                None => ptr::null_mut(),
            },
            || {
                Box::into_raw(Box::new(MappedTrack {
                    // Safe answer: the file's text as its title, nothing else.
                    mapped: safe_mapping(text, text_len, bounds),
                }))
            },
        )
    })
}

unsafe fn map(
    kind: u8,
    text: *const u8,
    text_len: usize,
    bounds: *const i64,
    numbers: *const i64,
) -> Option<Mapped> {
    if bounds.is_null() || numbers.is_null() || (text.is_null() && text_len > 0) {
        return None;
    }
    let bytes: &[u8] = if text_len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(text, text_len)
    };
    let bounds = std::slice::from_raw_parts(bounds, 2 * LOCAL_TRACK_TEXTS);
    let numbers = std::slice::from_raw_parts(numbers, 2 * LOCAL_TRACK_NUMBERS);
    let mut texts: [Option<&str>; LOCAL_TRACK_TEXTS] = [None; LOCAL_TRACK_TEXTS];
    for (i, slot) in texts.iter_mut().enumerate() {
        let (start, len) = (bounds[2 * i], bounds[2 * i + 1]);
        if len < 0 {
            continue;
        }
        let start = usize::try_from(start).ok()?;
        let end = start.checked_add(usize::try_from(len).ok()?)?;
        *slot = Some(std::str::from_utf8(bytes.get(start..end)?).ok()?);
    }
    let number = |i: usize| (numbers[2 * i] != 0).then_some(numbers[2 * i + 1]);
    let meta = Metadata {
        title: texts[2],
        artist: texts[3],
        album: texts[4],
        album_artist: texts[5],
        album_id: texts[6],
        track_number: number(0),
        duration_us: number(1),
    };
    let source = texts[0].unwrap_or("");
    match kind {
        LOCAL_TRACK_PATH => Some(from_path(source, texts[1], &meta)),
        LOCAL_TRACK_DOCUMENT => Some(from_document(source, &meta)),
        LOCAL_TRACK_CUE => {
            let cue = CueTrack {
                number: number(2).unwrap_or(0),
                audio_path: source,
                start_us: number(3).unwrap_or(0),
                end_us: number(4),
                title: texts[7],
                performer: texts[8],
                album: texts[9],
                album_performer: texts[10],
            };
            Some(from_cue(&cue, &meta, texts[1].unwrap_or("")))
        }
        _ => None,
    }
}

/// One text field of the answer as UTF-8 bytes, its length written to
/// `len`. Null (and a length of 0) when it is absent, `field` unknown or
/// `mapped` null.
///
/// # Safety
///
/// `mapped` must be null or live from [linthra_local_track_map]; `len` must
/// be valid for one write. The bytes live until the answer is freed.
#[no_mangle]
pub unsafe extern "C" fn linthra_mapped_text(
    mapped: *const MappedTrack,
    field: u8,
    len: *mut usize,
) -> *const u8 {
    crate::ffi::guard(ptr::null(), || {
        let text = mapped.as_ref().and_then(|m| {
            let m = &m.mapped;
            match field {
                MAPPED_TITLE => Some(m.title.as_str()),
                MAPPED_ARTIST => m.artist.as_deref(),
                MAPPED_ALBUM => m.album.as_deref(),
                MAPPED_ALBUM_ID => m.album_id.as_deref(),
                MAPPED_ALBUM_ARTIST => m.album_artist.as_deref(),
                _ => None,
            }
        });
        if !len.is_null() {
            *len = text.map_or(0, str::len);
        }
        text.map_or(ptr::null(), str::as_ptr)
    })
}

/// One number of the answer, whether it is there written to `present`. 0
/// (and absent) when `field` is unknown or `mapped` null.
///
/// # Safety
///
/// `mapped` must be null or live from [linthra_local_track_map]; `present`
/// must be valid for one write.
#[no_mangle]
pub unsafe extern "C" fn linthra_mapped_number(
    mapped: *const MappedTrack,
    field: u8,
    present: *mut u8,
) -> i64 {
    crate::ffi::guard(0, || {
        let value = mapped.as_ref().and_then(|m| {
            let m = &m.mapped;
            match field {
                MAPPED_TRACK_NUMBER => m.track_number,
                MAPPED_DURATION_US => Some(m.duration_us),
                MAPPED_CUE_END_US => m.cue_end_us,
                _ => None,
            }
        });
        if !present.is_null() {
            *present = u8::from(value.is_some());
        }
        value.unwrap_or(0)
    })
}

/// Frees a mapped track. Null is a no-op.
///
/// # Safety
///
/// `mapped` must be null or a pointer from [linthra_local_track_map] that
/// has not been freed yet.
#[no_mangle]
pub unsafe extern "C" fn linthra_mapped_free(mapped: *mut MappedTrack) {
    crate::ffi::guard((), || {
        if !mapped.is_null() {
            drop(Box::from_raw(mapped));
        }
    })
}

/// The safe answer of [linthra_local_track_map]: the file's own text (its
/// path, a document's name) as the title, read without indexing, and
/// nothing else.
///
/// # Safety
///
/// As for [linthra_local_track_map].
unsafe fn safe_mapping(text: *const u8, text_len: usize, bounds: *const i64) -> Mapped {
    let title = (|| {
        if text.is_null() || bounds.is_null() {
            return None;
        }
        let bytes = std::slice::from_raw_parts(text, text_len);
        let start = usize::try_from(*bounds).ok()?;
        let len = usize::try_from(*bounds.add(1)).ok()?;
        let source = bytes.get(start..start.checked_add(len)?)?;
        Some(String::from_utf8_lossy(source).into_owned())
    })()
    .unwrap_or_default();
    Mapped {
        title,
        artist: None,
        album: None,
        album_id: None,
        album_artist: None,
        track_number: None,
        duration_us: 0,
        cue_end_us: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_safe_mapping_names_the_track_after_its_file() {
        let text = b"/m/A/song.flac";
        let mut bounds = [-1i64; 2 * LOCAL_TRACK_TEXTS];
        bounds[0..2].copy_from_slice(&[0, 14]);
        let mapped = unsafe { safe_mapping(text.as_ptr(), text.len(), bounds.as_ptr()) };
        assert_eq!(mapped.title, "/m/A/song.flac");
        assert_eq!((mapped.artist, mapped.track_number), (None, None));
        // Bounds that don't fit give an empty title rather than a panic.
        bounds[0..2].copy_from_slice(&[10, 99]);
        let mapped = unsafe { safe_mapping(text.as_ptr(), text.len(), bounds.as_ptr()) };
        assert_eq!(mapped.title, "");
    }

    #[test]
    fn maps_through_the_abi() {
        let text = b"/m/A/B/01 - Flume.mp3/m";
        let mut bounds = [-1i64; 2 * LOCAL_TRACK_TEXTS];
        bounds[0..4].copy_from_slice(&[0, 21, 21, 2]);
        let numbers = [0i64; 2 * LOCAL_TRACK_NUMBERS];
        unsafe {
            let mapped = linthra_local_track_map(
                LOCAL_TRACK_PATH,
                text.as_ptr(),
                text.len(),
                bounds.as_ptr(),
                numbers.as_ptr(),
            );
            assert!(!mapped.is_null());
            let mut len = 0;
            let title = linthra_mapped_text(mapped, MAPPED_TITLE, &mut len);
            assert_eq!(std::slice::from_raw_parts(title, len), b"Flume");
            let artist = linthra_mapped_text(mapped, MAPPED_ARTIST, &mut len);
            assert_eq!(std::slice::from_raw_parts(artist, len), b"A");
            assert!(linthra_mapped_text(mapped, MAPPED_ALBUM_ID, &mut len).is_null());
            let mut present = 9;
            assert_eq!(
                linthra_mapped_number(mapped, MAPPED_TRACK_NUMBER, &mut present),
                1
            );
            assert_eq!(present, 1);
            linthra_mapped_number(mapped, MAPPED_CUE_END_US, &mut present);
            assert_eq!(present, 0);
            linthra_mapped_free(mapped);
        }
    }

    #[test]
    fn refuses_bad_input() {
        let bounds = [-1i64; 2 * LOCAL_TRACK_TEXTS];
        let numbers = [0i64; 2 * LOCAL_TRACK_NUMBERS];
        let mut outside = bounds;
        outside[0..2].copy_from_slice(&[0, 5]);
        let invalid = [0xFFu8];
        let mut whole = bounds;
        whole[0..2].copy_from_slice(&[0, 1]);
        unsafe {
            assert!(
                linthra_local_track_map(9, ptr::null(), 0, bounds.as_ptr(), numbers.as_ptr())
                    .is_null()
            );
            assert!(
                linthra_local_track_map(0, ptr::null(), 0, ptr::null(), numbers.as_ptr()).is_null()
            );
            assert!(
                linthra_local_track_map(0, ptr::null(), 0, outside.as_ptr(), numbers.as_ptr())
                    .is_null()
            );
            assert!(linthra_local_track_map(
                0,
                invalid.as_ptr(),
                1,
                whole.as_ptr(),
                numbers.as_ptr()
            )
            .is_null());
            linthra_mapped_free(ptr::null_mut());
        }
    }
}
