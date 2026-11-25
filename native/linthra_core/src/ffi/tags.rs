//! C ABI for [crate::tags]: one call reads a file, and the result is read
//! back field by field.
//!
//! The path crosses as bytes, not a C string, because a Linux file name need
//! not be UTF-8. Text fields cross as UTF-8 bytes with their length, because a
//! Vorbis comment value may hold a NUL.

use std::path::PathBuf;
use std::ptr;

use crate::tags::{read_file, AudioTags};

/// [TagsResult] status: the file's tags were read.
pub const TAGS_READ: u8 = 0;
/// [TagsResult] status: not a format the Rust reader handles, or one whose
/// tags don't hold together. The caller reads it another way.
pub const TAGS_NOT_HANDLED: u8 = 1;
/// [TagsResult] status: the file could not be read. Nothing is known about
/// its tags.
pub const TAGS_IO_ERROR: u8 = 2;

/// Field index for [linthra_tags_text]: title, artist, album artist, album.
pub const TAGS_TITLE: u8 = 0;
pub const TAGS_ARTIST: u8 = 1;
pub const TAGS_ALBUM_ARTIST: u8 = 2;
pub const TAGS_ALBUM: u8 = 3;

/// One read's outcome, kept alive until freed so Dart can copy each field.
pub struct TagsResult {
    status: u8,
    tags: AudioTags,
}

/// Reads the tags of the file at `path` (`path_len` bytes, the file name's
/// bytes as the system has them). The cover is only looked for when
/// `with_cover`. Returns null only when `path` is null with a non-zero
/// length. Free the result with [linthra_tags_free].
///
/// # Safety
///
/// `path` must be null or valid for reads of `path_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn linthra_tags_read(
    path: *const u8,
    path_len: usize,
    with_cover: bool,
) -> *mut TagsResult {
    if path.is_null() && path_len != 0 {
        return ptr::null_mut();
    }
    let bytes = if path_len == 0 {
        &[][..]
    } else {
        std::slice::from_raw_parts(path, path_len)
    };
    let result = match path_from_bytes(bytes) {
        None => TagsResult {
            status: TAGS_IO_ERROR,
            tags: AudioTags::default(),
        },
        Some(path) => match read_file(&path, with_cover) {
            Ok(Some(tags)) => TagsResult {
                status: TAGS_READ,
                tags,
            },
            Ok(None) => TagsResult {
                status: TAGS_NOT_HANDLED,
                tags: AudioTags::default(),
            },
            Err(_) => TagsResult {
                status: TAGS_IO_ERROR,
                tags: AudioTags::default(),
            },
        },
    };
    Box::into_raw(Box::new(result))
}

#[cfg(unix)]
fn path_from_bytes(bytes: &[u8]) -> Option<PathBuf> {
    use std::os::unix::ffi::OsStrExt;
    Some(PathBuf::from(std::ffi::OsStr::from_bytes(bytes)))
}

#[cfg(not(unix))]
fn path_from_bytes(bytes: &[u8]) -> Option<PathBuf> {
    std::str::from_utf8(bytes).ok().map(PathBuf::from)
}

/// The result's status: [TAGS_READ], [TAGS_NOT_HANDLED] or [TAGS_IO_ERROR].
/// [TAGS_IO_ERROR] for a null `result`.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_tags_read].
#[no_mangle]
pub unsafe extern "C" fn linthra_tags_status(result: *const TagsResult) -> u8 {
    result.as_ref().map_or(TAGS_IO_ERROR, |r| r.status)
}

/// One text field as UTF-8 bytes, its length written to `len`. Null (and a
/// length of 0) when the field is absent, the index unknown, or `result` null.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_tags_read]; `len`
/// must be valid for one write. The bytes live until the result is freed.
#[no_mangle]
pub unsafe extern "C" fn linthra_tags_text(
    result: *const TagsResult,
    field: u8,
    len: *mut usize,
) -> *const u8 {
    let text = result.as_ref().and_then(|r| match field {
        TAGS_TITLE => r.tags.title.as_deref(),
        TAGS_ARTIST => r.tags.artist.as_deref(),
        TAGS_ALBUM_ARTIST => r.tags.album_artist.as_deref(),
        TAGS_ALBUM => r.tags.album.as_deref(),
        _ => None,
    });
    if !len.is_null() {
        *len = text.map_or(0, str::len);
    }
    text.map_or(ptr::null(), str::as_ptr)
}

/// The track number, or 0 when there is none (a real one is always positive).
///
/// # Safety
///
/// As for [linthra_tags_status].
#[no_mangle]
pub unsafe extern "C" fn linthra_tags_track_number(result: *const TagsResult) -> i64 {
    result
        .as_ref()
        .and_then(|r| r.tags.track_number)
        .unwrap_or(0)
}

/// The length in microseconds, or 0 when unknown (a real one is positive).
///
/// # Safety
///
/// As for [linthra_tags_status].
#[no_mangle]
pub unsafe extern "C" fn linthra_tags_duration_micros(result: *const TagsResult) -> i64 {
    result
        .as_ref()
        .and_then(|r| r.tags.duration_micros)
        .unwrap_or(0)
}

/// The cover's bytes, their count written to `len`; null and 0 when there is
/// no cover.
///
/// # Safety
///
/// As for [linthra_tags_text].
#[no_mangle]
pub unsafe extern "C" fn linthra_tags_cover(
    result: *const TagsResult,
    len: *mut usize,
) -> *const u8 {
    let cover = result.as_ref().and_then(|r| r.tags.cover.as_deref());
    if !len.is_null() {
        *len = cover.map_or(0, <[u8]>::len);
    }
    cover.map_or(ptr::null(), <[u8]>::as_ptr)
}

/// Frees a result. Null is a no-op.
///
/// # Safety
///
/// `result` must be null or a pointer from [linthra_tags_read] that has not
/// been freed yet.
#[no_mangle]
pub unsafe extern "C" fn linthra_tags_free(result: *mut TagsResult) {
    if !result.is_null() {
        drop(Box::from_raw(result));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!(
            "{}/../../test/fixtures/tags/{name}",
            env!("CARGO_MANIFEST_DIR")
        )
    }

    unsafe fn text(result: *const TagsResult, field: u8) -> Option<String> {
        let mut len = 0usize;
        let bytes = linthra_tags_text(result, field, &mut len);
        (!bytes.is_null())
            .then(|| String::from_utf8(std::slice::from_raw_parts(bytes, len).to_vec()).unwrap())
    }

    #[test]
    fn reads_a_file_across_the_boundary() {
        let path = fixture("flac_tagged.flac");
        unsafe {
            let result = linthra_tags_read(path.as_ptr(), path.len(), true);
            assert_eq!(linthra_tags_status(result), TAGS_READ);
            assert_eq!(text(result, TAGS_TITLE).as_deref(), Some("Hello"));
            assert_eq!(text(result, TAGS_ARTIST).as_deref(), Some("Alice"));
            assert_eq!(
                text(result, TAGS_ALBUM_ARTIST).as_deref(),
                Some("Various Artists")
            );
            assert_eq!(text(result, TAGS_ALBUM).as_deref(), Some("Album"));
            assert_eq!(text(result, 9), None);
            assert_eq!(linthra_tags_track_number(result), 3);
            assert_eq!(linthra_tags_duration_micros(result), 3_000_000);
            let mut len = 0usize;
            let cover = linthra_tags_cover(result, &mut len);
            assert_eq!(std::slice::from_raw_parts(cover, len), [1, 2, 3, 4, 5]);
            linthra_tags_free(result);
        }
    }

    #[test]
    fn tells_not_handled_from_unreadable() {
        let other = fixture("not_audio.bin");
        let gone = fixture("gone.flac");
        unsafe {
            let result = linthra_tags_read(other.as_ptr(), other.len(), false);
            assert_eq!(linthra_tags_status(result), TAGS_NOT_HANDLED);
            assert_eq!(text(result, TAGS_TITLE), None);
            assert_eq!(linthra_tags_track_number(result), 0);
            linthra_tags_free(result);

            let result = linthra_tags_read(gone.as_ptr(), gone.len(), false);
            assert_eq!(linthra_tags_status(result), TAGS_IO_ERROR);
            linthra_tags_free(result);
        }
    }

    #[test]
    fn null_arguments_are_safe() {
        unsafe {
            assert!(linthra_tags_read(ptr::null(), 3, false).is_null());
            assert_eq!(linthra_tags_status(ptr::null()), TAGS_IO_ERROR);
            let mut len = 7usize;
            assert!(linthra_tags_text(ptr::null(), TAGS_TITLE, &mut len).is_null());
            assert_eq!(len, 0);
            assert!(linthra_tags_cover(ptr::null(), ptr::null_mut()).is_null());
            linthra_tags_free(ptr::null_mut());
        }
    }
}
