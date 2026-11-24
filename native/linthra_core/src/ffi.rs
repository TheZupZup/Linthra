//! C ABI for the Dart side of Linthra.
//!
//! `hook/build.dart` builds this crate as a shared library during
//! `flutter build` / `flutter test`, and `lib/core/native/linthra_core_ffi.dart`
//! declares the same functions with `@Native`. The two files are the whole
//! boundary: keep them in step, and bump [ABI_VERSION] whenever a signature or
//! a meaning changes, so an app built against one version refuses a library
//! from another instead of calling it wrongly.
//!
//! Conventions:
//!
//! - Strings cross as NUL-terminated UTF-8 (`const char*`). Rust never keeps a
//!   pointer it was given; it copies what it needs before returning.
//! - Objects cross as opaque pointers. Each one has exactly one `*_free` (or
//!   `*_finish`, which consumes the builder), and passing null to any of them is
//!   a no-op, so the Dart side can free without checking.
//! - No function here panics on bad input: a null or non-UTF-8 argument comes
//!   back as a status code or a null pointer. The release profile aborts on
//!   panic (`panic = "abort"`), so a panic would end the app rather than unwind
//!   across the boundary.

use std::ffi::{c_char, CStr, CString};
use std::ptr;

use crate::{LibraryIndex, TrackRecord};

pub mod cache_eviction;
pub mod library_grouping;

/// Version of this C ABI. Dart checks it before calling anything else.
pub const ABI_VERSION: u32 = 4;

/// The call did what it was asked.
pub const STATUS_OK: i32 = 0;
/// A required pointer argument was null.
pub const STATUS_NULL_ARGUMENT: i32 = 1;
/// A string argument was not valid UTF-8.
pub const STATUS_INVALID_UTF8: i32 = 2;

/// Collects tracks before the immutable [LibraryIndex] is built from them.
pub struct IndexBuilder {
    tracks: Vec<TrackRecord>,
}

/// The ids of one search's hits, best first, kept alive until freed so Dart
/// can read each id without copying the whole list in one call.
pub struct SearchResults {
    ids: Vec<CString>,
}

/// The positions (in the order tracks were added to the builder) of every
/// track a query matches, ascending. One contiguous array, so Dart copies it
/// in a single read however many tracks match.
pub struct MatchResults {
    positions: Vec<u32>,
}

/// Returns [ABI_VERSION].
#[no_mangle]
pub extern "C" fn linthra_core_abi_version() -> u32 {
    ABI_VERSION
}

/// Starts an empty index builder. Never returns null.
#[no_mangle]
pub extern "C" fn linthra_index_builder_new() -> *mut IndexBuilder {
    Box::into_raw(Box::new(IndexBuilder { tracks: Vec::new() }))
}

/// Adds one track to `builder`. `album_artist` may be null (no album artist);
/// every other argument is required.
///
/// Returns [STATUS_OK], [STATUS_NULL_ARGUMENT] or [STATUS_INVALID_UTF8]. On an
/// error nothing is added.
///
/// # Safety
///
/// `builder` must be null or a pointer from [linthra_index_builder_new] that
/// has not been finished or freed yet. Each string argument must be null or
/// point to a NUL-terminated string that stays valid for the call.
#[no_mangle]
pub unsafe extern "C" fn linthra_index_builder_add(
    builder: *mut IndexBuilder,
    id: *const c_char,
    title: *const c_char,
    artist: *const c_char,
    album: *const c_char,
    album_artist: *const c_char,
    provider: *const c_char,
) -> i32 {
    match add_track(builder, id, title, artist, album, album_artist, provider) {
        Ok(()) => STATUS_OK,
        Err(status) => status,
    }
}

/// [linthra_index_builder_add] with `?`: the error is the status to return.
///
/// # Safety
///
/// As for [linthra_index_builder_add].
unsafe fn add_track(
    builder: *mut IndexBuilder,
    id: *const c_char,
    title: *const c_char,
    artist: *const c_char,
    album: *const c_char,
    album_artist: *const c_char,
    provider: *const c_char,
) -> Result<(), i32> {
    let builder = builder.as_mut().ok_or(STATUS_NULL_ARGUMENT)?;
    // Every null is reported before any string is read, so nothing is copied
    // for a call that is going to be refused anyway.
    if [id, title, artist, album, provider]
        .iter()
        .any(|field| field.is_null())
    {
        return Err(STATUS_NULL_ARGUMENT);
    }
    let album_artist = if album_artist.is_null() {
        None
    } else {
        Some(utf8(album_artist)?)
    };
    let track = TrackRecord::new(
        utf8(id)?,
        utf8(title)?,
        utf8(artist)?,
        utf8(album)?,
        album_artist,
        utf8(provider)?,
    );
    builder.tracks.push(track);
    Ok(())
}

/// Builds the index from everything added to `builder` and frees the builder.
/// Returns null only when `builder` is null.
///
/// # Safety
///
/// `builder` must be null or a pointer from [linthra_index_builder_new] that
/// has not been finished or freed yet. It must not be used again afterwards.
#[no_mangle]
pub unsafe extern "C" fn linthra_index_builder_finish(
    builder: *mut IndexBuilder,
) -> *mut LibraryIndex {
    if builder.is_null() {
        return ptr::null_mut();
    }
    let builder = Box::from_raw(builder);
    Box::into_raw(Box::new(LibraryIndex::build(builder.tracks)))
}

/// Frees a builder without building anything. Null is a no-op.
///
/// # Safety
///
/// `builder` must be null or a pointer from [linthra_index_builder_new] that
/// has not been finished or freed yet. It must not be used again afterwards.
#[no_mangle]
pub unsafe extern "C" fn linthra_index_builder_free(builder: *mut IndexBuilder) {
    if !builder.is_null() {
        drop(Box::from_raw(builder));
    }
}

/// Number of tracks in `index`, or 0 when `index` is null.
///
/// # Safety
///
/// `index` must be null or a live pointer from [linthra_index_builder_finish].
#[no_mangle]
pub unsafe extern "C" fn linthra_index_len(index: *const LibraryIndex) -> usize {
    index.as_ref().map_or(0, LibraryIndex::len)
}

/// Frees an index. Null is a no-op.
///
/// # Safety
///
/// `index` must be null or a pointer from [linthra_index_builder_finish] that
/// has not been freed yet. It must not be used again afterwards.
#[no_mangle]
pub unsafe extern "C" fn linthra_index_free(index: *mut LibraryIndex) {
    if !index.is_null() {
        drop(Box::from_raw(index));
    }
}

/// Searches `index` for `query` (see [LibraryIndex::search]) and returns at
/// most `limit` hits, best first. Returns null when `index` or `query` is null
/// or `query` is not valid UTF-8; an empty result is a non-null, empty list.
///
/// # Safety
///
/// `index` must be null or a live pointer from [linthra_index_builder_finish].
/// `query` must be null or point to a NUL-terminated string that stays valid
/// for the call.
#[no_mangle]
pub unsafe extern "C" fn linthra_index_search(
    index: *const LibraryIndex,
    query: *const c_char,
    limit: usize,
) -> *mut SearchResults {
    let Some(index) = index.as_ref() else {
        return ptr::null_mut();
    };
    if query.is_null() {
        return ptr::null_mut();
    }
    let Ok(query) = utf8(query) else {
        return ptr::null_mut();
    };
    let ids = index
        .search(&query, limit)
        .into_iter()
        // An id came in as a C string, so it has no interior NUL to refuse.
        .filter_map(|hit| CString::new(hit.track.id.as_str()).ok())
        .collect();
    Box::into_raw(Box::new(SearchResults { ids }))
}

/// Number of hits in `results`, or 0 when `results` is null.
///
/// # Safety
///
/// `results` must be null or a live pointer from [linthra_index_search].
#[no_mangle]
pub unsafe extern "C" fn linthra_search_results_len(results: *const SearchResults) -> usize {
    results.as_ref().map_or(0, |results| results.ids.len())
}

/// The id of hit `position` (0 is the best), or null when `results` is null or
/// `position` is out of range. The string belongs to `results` and stays valid
/// until [linthra_search_results_free].
///
/// # Safety
///
/// `results` must be null or a live pointer from [linthra_index_search].
#[no_mangle]
pub unsafe extern "C" fn linthra_search_results_id(
    results: *const SearchResults,
    position: usize,
) -> *const c_char {
    results
        .as_ref()
        .and_then(|results| results.ids.get(position))
        .map_or(ptr::null(), |id| id.as_ptr())
}

/// Frees search results. Null is a no-op.
///
/// # Safety
///
/// `results` must be null or a pointer from [linthra_index_search] that has
/// not been freed yet. It and every id read from it must not be used again
/// afterwards.
#[no_mangle]
pub unsafe extern "C" fn linthra_search_results_free(results: *mut SearchResults) {
    if !results.is_null() {
        drop(Box::from_raw(results));
    }
}

/// Every track of `index` that `query` matches (see [LibraryIndex::matching]),
/// as positions in the order the tracks were added, ascending and unranked.
/// Returns null when `index` or `query` is null, `query` is not valid UTF-8,
/// or the index holds more tracks than a `u32` can number; no match is a
/// non-null, empty list.
///
/// # Safety
///
/// `index` must be null or a live pointer from [linthra_index_builder_finish].
/// `query` must be null or point to a NUL-terminated string that stays valid
/// for the call.
#[no_mangle]
pub unsafe extern "C" fn linthra_index_match(
    index: *const LibraryIndex,
    query: *const c_char,
) -> *mut MatchResults {
    let Some(index) = index.as_ref() else {
        return ptr::null_mut();
    };
    if query.is_null() || u32::try_from(index.len()).is_err() {
        return ptr::null_mut();
    }
    let Ok(query) = utf8(query) else {
        return ptr::null_mut();
    };
    let positions = index
        .matching(&query)
        .into_iter()
        // Every position is below the track count, which fits in a u32.
        .map(|position| position as u32)
        .collect();
    Box::into_raw(Box::new(MatchResults { positions }))
}

/// Number of positions in `results`, or 0 when `results` is null.
///
/// # Safety
///
/// `results` must be null or a live pointer from [linthra_index_match].
#[no_mangle]
pub unsafe extern "C" fn linthra_match_results_len(results: *const MatchResults) -> usize {
    results
        .as_ref()
        .map_or(0, |results| results.positions.len())
}

/// The positions themselves, [linthra_match_results_len] of them, or null
/// when `results` is null. The array belongs to `results` and stays valid
/// until [linthra_match_results_free].
///
/// # Safety
///
/// `results` must be null or a live pointer from [linthra_index_match].
#[no_mangle]
pub unsafe extern "C" fn linthra_match_results_positions(
    results: *const MatchResults,
) -> *const u32 {
    results
        .as_ref()
        .map_or(ptr::null(), |results| results.positions.as_ptr())
}

/// Frees match results. Null is a no-op.
///
/// # Safety
///
/// `results` must be null or a pointer from [linthra_index_match] that has not
/// been freed yet. It and the array read from it must not be used again
/// afterwards.
#[no_mangle]
pub unsafe extern "C" fn linthra_match_results_free(results: *mut MatchResults) {
    if !results.is_null() {
        drop(Box::from_raw(results));
    }
}

/// Copies a non-null C string, or fails with [STATUS_INVALID_UTF8].
///
/// # Safety
///
/// `text` must be non-null and point to a NUL-terminated string.
unsafe fn utf8(text: *const c_char) -> Result<String, i32> {
    CStr::from_ptr(text)
        .to_str()
        .map(str::to_owned)
        .map_err(|_| STATUS_INVALID_UTF8)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(text: &str) -> CString {
        CString::new(text).expect("test strings have no NUL")
    }

    /// Adds a track through the C ABI and returns the status.
    fn add(builder: *mut IndexBuilder, fields: [&str; 5], album_artist: Option<&str>) -> i32 {
        let [id, title, artist, album, provider] = fields.map(c);
        let album_artist = album_artist.map(c);
        unsafe {
            linthra_index_builder_add(
                builder,
                id.as_ptr(),
                title.as_ptr(),
                artist.as_ptr(),
                album.as_ptr(),
                album_artist
                    .as_ref()
                    .map_or(ptr::null(), |text| text.as_ptr()),
                provider.as_ptr(),
            )
        }
    }

    /// Runs a search through the C ABI and returns the hit ids.
    fn search(index: *const LibraryIndex, query: &str, limit: usize) -> Vec<String> {
        let query = c(query);
        unsafe {
            let results = linthra_index_search(index, query.as_ptr(), limit);
            assert!(!results.is_null());
            let ids = (0..linthra_search_results_len(results))
                .map(|position| {
                    CStr::from_ptr(linthra_search_results_id(results, position))
                        .to_str()
                        .expect("ids are UTF-8")
                        .to_owned()
                })
                .collect();
            linthra_search_results_free(results);
            ids
        }
    }

    fn sample_index() -> *mut LibraryIndex {
        let builder = linthra_index_builder_new();
        assert_eq!(
            add(
                builder,
                ["jf:1", "Jóga", "Björk", "Homogenic", "jellyfin"],
                None
            ),
            STATUS_OK
        );
        assert_eq!(
            add(
                builder,
                ["nd:2", "Hunter", "Björk", "Homogenic", "navidrome"],
                Some("Björk"),
            ),
            STATUS_OK
        );
        assert_eq!(
            add(
                builder,
                [
                    "local:3",
                    "Ace of Spades",
                    "Motörhead",
                    "Ace of Spades",
                    "local"
                ],
                None,
            ),
            STATUS_OK
        );
        unsafe { linthra_index_builder_finish(builder) }
    }

    #[test]
    fn reports_its_abi_version() {
        assert_eq!(linthra_core_abi_version(), ABI_VERSION);
    }

    #[test]
    fn builds_and_searches_through_the_c_abi() {
        let index = sample_index();
        assert_eq!(unsafe { linthra_index_len(index) }, 3);
        // Accent-folded, prefix, AND across terms: the same rules as the core.
        assert_eq!(search(index, "bjork hun", 10), vec!["nd:2"]);
        assert_eq!(search(index, "motorhead", 10), vec!["local:3"]);
        assert_eq!(search(index, "bjork", 1).len(), 1);
        assert!(search(index, "", 10).is_empty());
        assert!(search(index, "bjork", 0).is_empty());
        assert!(search(index, "nothing like this", 10).is_empty());
        unsafe { linthra_index_free(index) };
    }

    #[test]
    fn non_ascii_ids_round_trip() {
        let builder = linthra_index_builder_new();
        assert_eq!(
            add(
                builder,
                ["id:é✓", "Title", "Artist", "Album", "local"],
                None
            ),
            STATUS_OK
        );
        let index = unsafe { linthra_index_builder_finish(builder) };
        assert_eq!(search(index, "title", 10), vec!["id:é✓"]);
        unsafe { linthra_index_free(index) };
    }

    #[test]
    fn refuses_null_and_invalid_arguments_without_adding_anything() {
        let builder = linthra_index_builder_new();
        let text = c("x");
        let invalid: [u8; 2] = [0xff, 0];
        unsafe {
            assert_eq!(
                linthra_index_builder_add(
                    ptr::null_mut(),
                    text.as_ptr(),
                    text.as_ptr(),
                    text.as_ptr(),
                    text.as_ptr(),
                    ptr::null(),
                    text.as_ptr(),
                ),
                STATUS_NULL_ARGUMENT
            );
            assert_eq!(
                linthra_index_builder_add(
                    builder,
                    ptr::null(),
                    text.as_ptr(),
                    text.as_ptr(),
                    text.as_ptr(),
                    ptr::null(),
                    text.as_ptr(),
                ),
                STATUS_NULL_ARGUMENT
            );
            assert_eq!(
                linthra_index_builder_add(
                    builder,
                    text.as_ptr(),
                    invalid.as_ptr().cast(),
                    text.as_ptr(),
                    text.as_ptr(),
                    ptr::null(),
                    text.as_ptr(),
                ),
                STATUS_INVALID_UTF8
            );
            assert_eq!(
                linthra_index_builder_add(
                    builder,
                    text.as_ptr(),
                    text.as_ptr(),
                    text.as_ptr(),
                    text.as_ptr(),
                    invalid.as_ptr().cast(),
                    text.as_ptr(),
                ),
                STATUS_INVALID_UTF8
            );
            let index = linthra_index_builder_finish(builder);
            assert_eq!(linthra_index_len(index), 0);

            assert!(linthra_index_search(index, ptr::null(), 10).is_null());
            assert!(linthra_index_search(index, invalid.as_ptr().cast(), 10).is_null());
            assert!(linthra_index_search(ptr::null(), text.as_ptr(), 10).is_null());
            linthra_index_free(index);
        }
    }

    #[test]
    fn null_handles_are_harmless() {
        unsafe {
            assert!(linthra_index_builder_finish(ptr::null_mut()).is_null());
            linthra_index_builder_free(ptr::null_mut());
            linthra_index_free(ptr::null_mut());
            linthra_search_results_free(ptr::null_mut());
            assert_eq!(linthra_index_len(ptr::null()), 0);
            assert_eq!(linthra_search_results_len(ptr::null()), 0);
            assert!(linthra_search_results_id(ptr::null(), 0).is_null());
            linthra_match_results_free(ptr::null_mut());
            assert_eq!(linthra_match_results_len(ptr::null()), 0);
            assert!(linthra_match_results_positions(ptr::null()).is_null());
        }
    }

    /// Runs a match through the C ABI and returns the positions.
    fn match_positions(index: *const LibraryIndex, query: &str) -> Vec<u32> {
        let query = c(query);
        unsafe {
            let results = linthra_index_match(index, query.as_ptr());
            assert!(!results.is_null());
            let len = linthra_match_results_len(results);
            let positions = if len == 0 {
                Vec::new()
            } else {
                std::slice::from_raw_parts(linthra_match_results_positions(results), len).to_vec()
            };
            linthra_match_results_free(results);
            positions
        }
    }

    #[test]
    fn matches_come_back_as_ascending_build_positions() {
        let index = sample_index();
        // jf:1 and nd:2 are both Björk, added first and second.
        assert_eq!(match_positions(index, "bjork"), vec![0, 1]);
        assert_eq!(match_positions(index, "motorhead"), vec![2]);
        assert_eq!(match_positions(index, "homogenic hunter"), vec![1]);
        assert!(match_positions(index, "").is_empty());
        assert!(match_positions(index, "nothing like this").is_empty());
        unsafe { linthra_index_free(index) };
    }

    #[test]
    fn match_refuses_null_and_invalid_arguments() {
        let index = sample_index();
        let text = c("bjork");
        let invalid: [u8; 2] = [0xff, 0];
        unsafe {
            assert!(linthra_index_match(ptr::null(), text.as_ptr()).is_null());
            assert!(linthra_index_match(index, ptr::null()).is_null());
            assert!(linthra_index_match(index, invalid.as_ptr().cast()).is_null());
            linthra_index_free(index);
        }
    }

    #[test]
    fn out_of_range_result_position_is_null() {
        let index = sample_index();
        let query = c("bjork");
        unsafe {
            let results = linthra_index_search(index, query.as_ptr(), 10);
            let len = linthra_search_results_len(results);
            assert_eq!(len, 2);
            assert!(linthra_search_results_id(results, len).is_null());
            linthra_search_results_free(results);
            linthra_index_free(index);
        }
    }

    #[test]
    fn a_builder_can_be_abandoned() {
        let builder = linthra_index_builder_new();
        assert_eq!(
            add(builder, ["a", "Title", "Artist", "Album", "local"], None),
            STATUS_OK
        );
        unsafe { linthra_index_builder_free(builder) };
    }
}
