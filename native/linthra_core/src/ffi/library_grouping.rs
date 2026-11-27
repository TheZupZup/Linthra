//! C ABI for [crate::library_grouping]: one call groups the whole catalog.
//!
//! As for the eviction plan, strings do not cross one by one. Every track's
//! album id, album, artist and album artist go into one UTF-8 buffer, and each
//! track is a span of eight `u32`s into it (start and length of each field, in
//! that order). The answer is read through one [LibraryGroupsView], whose
//! arrays live as long as the result.

use std::ptr;

use crate::library_grouping::{group, GroupingTrack, LibraryGroups};

/// A track index field that names no track.
pub const GROUPING_NO_TRACK: u32 = u32::MAX;

/// Per album: title track, album artist track, artist track, track count.
pub const GROUPING_ALBUM_FIELDS: usize = 4;
/// Per artist: name track, album count, track count.
pub const GROUPING_ARTIST_FIELDS: usize = 3;

/// The grouping, laid out for Dart to read without a call per group.
pub struct GroupingResult {
    /// Every album id, then every artist id, back to back (all ASCII).
    ids: Vec<u8>,
    /// `album_count + 1` offsets into `ids`; album `i` is
    /// `ids[album_ids[i]..album_ids[i + 1]]`.
    album_ids: Vec<u32>,
    /// The same for artists.
    artist_ids: Vec<u32>,
    album_fields: Vec<u32>,
    artist_fields: Vec<u32>,
    track_album: Vec<u32>,
    track_artist: Vec<u32>,
}

/// Borrowed pointers into a [GroupingResult]. Every array is non-null, even
/// when empty, and valid until the result is freed.
#[repr(C)]
pub struct LibraryGroupsView {
    pub album_count: usize,
    pub artist_count: usize,
    pub ids: *const u8,
    pub album_ids: *const u32,
    pub artist_ids: *const u32,
    /// [GROUPING_ALBUM_FIELDS] values per album.
    pub album_fields: *const u32,
    /// [GROUPING_ARTIST_FIELDS] values per artist.
    pub artist_fields: *const u32,
    /// One value per input track: its album's position.
    pub track_album: *const u32,
    /// One value per input track: its artist's position.
    pub track_artist: *const u32,
}

impl LibraryGroupsView {
    /// What [linthra_grouping_result_view] answers if it panics: nothing.
    pub const EMPTY: LibraryGroupsView = LibraryGroupsView {
        album_count: 0,
        artist_count: 0,
        ids: ptr::null(),
        album_ids: ptr::null(),
        artist_ids: ptr::null(),
        album_fields: ptr::null(),
        artist_fields: ptr::null(),
        track_album: ptr::null(),
        track_artist: ptr::null(),
    };
}

/// Groups `count` tracks described by `spans` (`8 * count` values) into
/// `text`. The album, artist and album artist must already be lower-cased
/// with Dart's `String.toLowerCase`; the album id is passed as the source
/// gave it.
///
/// Returns null when `text` or `spans` is null while its length is not zero,
/// a span falls outside `text`, a span is not valid UTF-8, or there are more
/// tracks than a `u32` can index. Free the result with
/// [linthra_grouping_result_free].
///
/// # Safety
///
/// Each pointer must be null or valid for reads of the length given above,
/// for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn linthra_library_group(
    text: *const u8,
    text_len: usize,
    spans: *const u32,
    count: usize,
) -> *mut GroupingResult {
    crate::ffi::guard(ptr::null_mut(), || {
        crate::ffi::fail_safe(
            || {
                let input = || -> Option<GroupingResult> {
                    if u32::try_from(count).ok()? == GROUPING_NO_TRACK {
                        return None;
                    }
                    let text = array(text, text_len)?;
                    let spans = array(spans, count.checked_mul(8)?)?;
                    let tracks = spans
                        .as_chunks::<8>()
                        .0
                        .iter()
                        .map(|span| {
                            Some(GroupingTrack {
                                album_id: part(text, span[0], span[1])?,
                                album: part(text, span[2], span[3])?,
                                artist: part(text, span[4], span[5])?,
                                album_artist: part(text, span[6], span[7])?,
                            })
                        })
                        .collect::<Option<Vec<_>>>()?;
                    layout(group(&tracks))
                };
                match input() {
                    Some(result) => Box::into_raw(Box::new(result)),
                    None => ptr::null_mut(),
                }
            },
            || match unknown_grouping(count) {
                // Safe answer: every track under one unknown album and artist.
                Some(result) => Box::into_raw(Box::new(result)),
                None => ptr::null_mut(),
            },
        )
    })
}

/// The arrays of `result`. All zero and null for a null `result`.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_library_group].
#[no_mangle]
pub unsafe extern "C" fn linthra_grouping_result_view(
    result: *const GroupingResult,
) -> LibraryGroupsView {
    crate::ffi::guard(LibraryGroupsView::EMPTY, || match result.as_ref() {
        Some(r) => LibraryGroupsView {
            album_count: r.album_ids.len() - 1,
            artist_count: r.artist_ids.len() - 1,
            ids: r.ids.as_ptr(),
            album_ids: r.album_ids.as_ptr(),
            artist_ids: r.artist_ids.as_ptr(),
            album_fields: r.album_fields.as_ptr(),
            artist_fields: r.artist_fields.as_ptr(),
            track_album: r.track_album.as_ptr(),
            track_artist: r.track_artist.as_ptr(),
        },
        None => LibraryGroupsView {
            album_count: 0,
            artist_count: 0,
            ids: ptr::null(),
            album_ids: ptr::null(),
            artist_ids: ptr::null(),
            album_fields: ptr::null(),
            artist_fields: ptr::null(),
            track_album: ptr::null(),
            track_artist: ptr::null(),
        },
    })
}

/// Frees a grouping. Null is a no-op.
///
/// # Safety
///
/// `result` must be null or a pointer from [linthra_library_group] that has
/// not been freed yet.
#[no_mangle]
pub unsafe extern "C" fn linthra_grouping_result_free(result: *mut GroupingResult) {
    crate::ffi::guard((), || {
        if !result.is_null() {
            drop(Box::from_raw(result));
        }
    })
}

/// Flattens `groups` into a [GroupingResult]. None when the ids outgrow a
/// `u32` offset.
/// The safe answer of [linthra_library_group]: all `count` tracks under one
/// unknown album and one unknown artist, grouped the ordinary way.
fn unknown_grouping(count: usize) -> Option<GroupingResult> {
    if u32::try_from(count).ok()? == GROUPING_NO_TRACK {
        return None;
    }
    layout(group(&vec![GroupingTrack::default(); count]))
}

fn layout(groups: LibraryGroups) -> Option<GroupingResult> {
    fn index(track: Option<usize>) -> u32 {
        track.map_or(GROUPING_NO_TRACK, |i| i as u32)
    }
    let mut ids = Vec::new();
    let mut offsets = |names: &mut dyn Iterator<Item = &str>| -> Option<Vec<u32>> {
        let mut out = vec![u32::try_from(ids.len()).ok()?];
        for name in names {
            ids.extend_from_slice(name.as_bytes());
            out.push(u32::try_from(ids.len()).ok()?);
        }
        Some(out)
    };
    let album_ids = offsets(&mut groups.albums.iter().map(|a| a.id.as_str()))?;
    let artist_ids = offsets(&mut groups.artists.iter().map(|a| a.id.as_str()))?;
    let album_fields = groups
        .albums
        .iter()
        .flat_map(|a| {
            [
                index(a.title_track),
                index(a.album_artist_track),
                index(a.artist_track),
                a.track_count as u32,
            ]
        })
        .collect();
    let artist_fields = groups
        .artists
        .iter()
        .flat_map(|a| {
            [
                index(a.name_track),
                a.album_count as u32,
                a.track_count as u32,
            ]
        })
        .collect();
    Some(GroupingResult {
        ids,
        album_ids,
        artist_ids,
        album_fields,
        artist_fields,
        track_album: groups.track_album,
        track_artist: groups.track_artist,
    })
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
    fn the_safe_grouping_puts_everything_under_one_album_and_artist() {
        let result = unknown_grouping(3).unwrap();
        // One album and one artist (each list closes with an end offset),
        // and every track in them.
        assert_eq!(result.album_ids.len(), 2);
        assert_eq!(result.artist_ids.len(), 2);
        assert_eq!(result.track_album, vec![0, 0, 0]);
        assert_eq!(result.track_artist, vec![0, 0, 0]);
        assert_eq!(unknown_grouping(0).unwrap().track_album, Vec::<u32>::new());
    }

    /// Writes each track's four fields into one buffer and returns it with
    /// the spans.
    fn pack(tracks: &[[&str; 4]]) -> (Vec<u8>, Vec<u32>) {
        let mut text = Vec::new();
        let mut spans = Vec::new();
        for fields in tracks {
            for field in fields {
                spans.push(text.len() as u32);
                spans.push(field.len() as u32);
                text.extend_from_slice(field.as_bytes());
            }
        }
        (text, spans)
    }

    unsafe fn read<T: Copy>(data: *const T, len: usize) -> Vec<T> {
        std::slice::from_raw_parts(data, len).to_vec()
    }

    #[test]
    fn groups_round_trip_through_the_view() {
        let (text, spans) = pack(&[
            ["", "one", "abba", ""],
            ["", "two", "abba", ""],
            ["", "one", "abba", ""],
        ]);
        unsafe {
            let result = linthra_library_group(text.as_ptr(), text.len(), spans.as_ptr(), 3);
            assert!(!result.is_null());
            let view = linthra_grouping_result_view(result);
            assert_eq!(view.album_count, 2);
            assert_eq!(view.artist_count, 1);
            let album_ids = read(view.album_ids, 3);
            let artist_ids = read(view.artist_ids, 2);
            let ids = read(view.ids, artist_ids[1] as usize);
            let id = |from: u32, to: u32| {
                String::from_utf8(ids[from as usize..to as usize].to_vec()).unwrap()
            };
            assert_eq!(id(album_ids[0], album_ids[1]), "al-YXI6M3xvbmV8YWJiYQ");
            assert_eq!(id(artist_ids[0], artist_ids[1]), "ar-YWJiYQ");
            assert_eq!(
                read(view.album_fields, 8),
                [0, GROUPING_NO_TRACK, 0, 2, 1, GROUPING_NO_TRACK, 1, 1]
            );
            assert_eq!(read(view.artist_fields, 3), [0, 2, 3]);
            assert_eq!(read(view.track_album, 3), [0, 1, 0]);
            assert_eq!(read(view.track_artist, 3), [0, 0, 0]);
            linthra_grouping_result_free(result);
        }
    }

    #[test]
    fn an_empty_catalog_has_non_null_empty_arrays() {
        unsafe {
            let result = linthra_library_group(ptr::null(), 0, ptr::null(), 0);
            assert!(!result.is_null());
            let view = linthra_grouping_result_view(result);
            assert_eq!((view.album_count, view.artist_count), (0, 0));
            assert!(!view.album_ids.is_null());
            assert!(!view.track_album.is_null());
            linthra_grouping_result_free(result);
        }
    }

    #[test]
    fn bad_input_is_refused_not_trusted() {
        let (text, mut spans) = pack(&[["", "one", "abba", ""]]);
        unsafe {
            assert!(linthra_library_group(ptr::null(), 4, spans.as_ptr(), 1).is_null());
            assert!(linthra_library_group(text.as_ptr(), text.len(), ptr::null(), 1).is_null());
            spans[3] = 999;
            assert!(linthra_library_group(text.as_ptr(), text.len(), spans.as_ptr(), 1).is_null());
            let invalid = [0xffu8];
            let span = [0u32, 0, 0, 1, 0, 0, 0, 0];
            assert!(linthra_library_group(invalid.as_ptr(), 1, span.as_ptr(), 1).is_null());
        }
    }

    #[test]
    fn null_result_reads_as_empty_and_frees_as_a_no_op() {
        unsafe {
            let view = linthra_grouping_result_view(ptr::null());
            assert_eq!(view.album_count, 0);
            assert!(view.ids.is_null());
            linthra_grouping_result_free(ptr::null_mut());
        }
    }
}
