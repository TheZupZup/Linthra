//! C ABI for [crate::cue_sheet]. A sheet is small, so the answers are read
//! back one field at a call, as for the tags.

use std::ptr;

use crate::cue_sheet::{decode, parse, CueTrack};

/// Field index for [linthra_cue_field]: the FILE name (always there), then
/// the title, performer, album and album performer (each may be absent).
pub const CUE_FILE: u8 = 0;
pub const CUE_TITLE: u8 = 1;
pub const CUE_PERFORMER: u8 = 2;
pub const CUE_ALBUM: u8 = 3;
pub const CUE_ALBUM_PERFORMER: u8 = 4;

/// A decoded sheet, as UTF-16 code units so Dart reads it back without a
/// second decode (which would drop another byte order mark), kept until
/// freed.
pub struct CueText {
    units: Vec<u16>,
}

/// A parsed sheet, kept until freed.
pub struct CueTracks {
    tracks: Vec<CueTrack>,
}

/// Decodes a sheet's bytes as `CueSheet.decode` does. Returns null only when
/// `bytes` is null with a non-zero length. Free it with
/// [linthra_cue_text_free].
///
/// # Safety
///
/// `bytes` must be null or valid for reads of `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn linthra_cue_decode(bytes: *const u8, len: usize) -> *mut CueText {
    crate::ffi::guard(ptr::null_mut(), || {
        crate::ffi::fail_safe(
            || match array(bytes, len) {
                Some(bytes) => Box::into_raw(Box::new(CueText {
                    units: decode(bytes).encode_utf16().collect(),
                })),
                None => ptr::null_mut(),
            },
            || match array(bytes, len) {
                // Safe answer: the bytes as UTF-8, invalid ones replaced.
                Some(b) => Box::into_raw(Box::new(CueText {
                    units: String::from_utf8_lossy(b).encode_utf16().collect(),
                })),
                None => ptr::null_mut(),
            },
        )
    })
}

/// The decoded text as UTF-16 code units, their count written to `len`.
///
/// # Safety
///
/// `text` must be null or live from [linthra_cue_decode]; `len` must be valid
/// for one write. The units live until the text is freed.
#[no_mangle]
pub unsafe extern "C" fn linthra_cue_text(text: *const CueText, len: *mut usize) -> *const u16 {
    crate::ffi::guard(ptr::null(), || {
        let (units, length) = text
            .as_ref()
            .map_or((ptr::null(), 0), |t| (t.units.as_ptr(), t.units.len()));
        if !len.is_null() {
            *len = length;
        }
        units
    })
}

/// Frees a decoded text. Null is a no-op.
///
/// # Safety
///
/// `text` must be null or a pointer from [linthra_cue_decode] that has not
/// been freed yet.
#[no_mangle]
pub unsafe extern "C" fn linthra_cue_text_free(text: *mut CueText) {
    crate::ffi::guard((), || {
        if !text.is_null() {
            drop(Box::from_raw(text));
        }
    })
}

/// Parses a sheet's text (`len` bytes of UTF-8). Returns null when `text` is
/// null with a non-zero length or is not UTF-8. Free it with
/// [linthra_cue_tracks_free].
///
/// # Safety
///
/// `text` must be null or valid for reads of `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn linthra_cue_parse(text: *const u8, len: usize) -> *mut CueTracks {
    crate::ffi::guard(ptr::null_mut(), || {
        crate::ffi::fail_safe(
            || {
                match array(text, len).and_then(|b| std::str::from_utf8(b).ok()) {
                    // A sheet the parser panics on has no tracks: its audio file is
                    // listed on its own, as for a sheet that can't be read.
                    Some(text) => Box::into_raw(Box::new(CueTracks {
                        tracks: crate::ffi::guard(Vec::new(), || parse(text)),
                    })),
                    None => ptr::null_mut(),
                }
            },
            || match array(text, len) {
                // Safe answer: a sheet with no tracks; its audio file is listed alone.
                Some(_) => Box::into_raw(Box::new(CueTracks { tracks: Vec::new() })),
                None => ptr::null_mut(),
            },
        )
    })
}

/// How many tracks the sheet holds. 0 for null.
///
/// # Safety
///
/// `tracks` must be null or live from [linthra_cue_parse].
#[no_mangle]
pub unsafe extern "C" fn linthra_cue_track_count(tracks: *const CueTracks) -> usize {
    crate::ffi::guard(0, || tracks.as_ref().map_or(0, |t| t.tracks.len()))
}

/// Track `i`'s number. 0 when `i` is out of range or `tracks` null.
///
/// # Safety
///
/// `tracks` must be null or live from [linthra_cue_parse].
#[no_mangle]
pub unsafe extern "C" fn linthra_cue_number(tracks: *const CueTracks, i: usize) -> i64 {
    crate::ffi::guard(0, || track(tracks, i).map_or(0, |t| t.number))
}

/// Track `i`'s start in milliseconds. 0 when `i` is out of range or `tracks`
/// null.
///
/// # Safety
///
/// `tracks` must be null or live from [linthra_cue_parse].
#[no_mangle]
pub unsafe extern "C" fn linthra_cue_start_ms(tracks: *const CueTracks, i: usize) -> i64 {
    crate::ffi::guard(0, || track(tracks, i).map_or(0, |t| t.start_ms))
}

/// One text field of track `i` as UTF-8 bytes, its length written to `len`.
/// Null (and a length of 0) when the field is absent, `i` or `field` out of
/// range, or `tracks` null.
///
/// # Safety
///
/// `tracks` must be null or live from [linthra_cue_parse]; `len` must be
/// valid for one write. The bytes live until the tracks are freed.
#[no_mangle]
pub unsafe extern "C" fn linthra_cue_field(
    tracks: *const CueTracks,
    i: usize,
    field: u8,
    len: *mut usize,
) -> *const u8 {
    crate::ffi::guard(ptr::null(), || {
        let text = track(tracks, i).and_then(|t| match field {
            CUE_FILE => Some(t.file.as_str()),
            CUE_TITLE => t.title.as_deref(),
            CUE_PERFORMER => t.performer.as_deref(),
            CUE_ALBUM => t.album.as_deref(),
            CUE_ALBUM_PERFORMER => t.album_performer.as_deref(),
            _ => None,
        });
        if !len.is_null() {
            *len = text.map_or(0, str::len);
        }
        text.map_or(ptr::null(), str::as_ptr)
    })
}

/// Frees parsed tracks. Null is a no-op.
///
/// # Safety
///
/// `tracks` must be null or a pointer from [linthra_cue_parse] that has not
/// been freed yet.
#[no_mangle]
pub unsafe extern "C" fn linthra_cue_tracks_free(tracks: *mut CueTracks) {
    crate::ffi::guard((), || {
        if !tracks.is_null() {
            drop(Box::from_raw(tracks));
        }
    })
}

unsafe fn track<'a>(tracks: *const CueTracks, i: usize) -> Option<&'a CueTrack> {
    tracks.as_ref()?.tracks.get(i)
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
    fn parses_through_the_abi() {
        let sheet = b"FILE a.flac WAVE\nTRACK 01 AUDIO\nINDEX 01 00:02:00\n";
        unsafe {
            let tracks = linthra_cue_parse(sheet.as_ptr(), sheet.len());
            assert_eq!(linthra_cue_track_count(tracks), 1);
            assert_eq!(linthra_cue_number(tracks, 0), 1);
            assert_eq!(linthra_cue_start_ms(tracks, 0), 2000);
            let mut len = 99;
            let file = linthra_cue_field(tracks, 0, CUE_FILE, &mut len);
            assert_eq!(std::slice::from_raw_parts(file, len), b"a.flac");
            assert!(linthra_cue_field(tracks, 0, CUE_TITLE, &mut len).is_null());
            assert_eq!(len, 0);
            linthra_cue_tracks_free(tracks);
        }
    }

    #[test]
    fn refuses_text_that_is_not_utf8() {
        let tracks = unsafe { linthra_cue_parse([0xFFu8].as_ptr(), 1) };
        assert!(tracks.is_null());
    }

    #[test]
    fn decodes_through_the_abi() {
        unsafe {
            let text = linthra_cue_decode([0xC0u8].as_ptr(), 1);
            let mut len = 0;
            let units = linthra_cue_text(text, &mut len);
            assert_eq!(std::slice::from_raw_parts(units, len), [0x0410]);
            linthra_cue_text_free(text);
        }
    }
}
