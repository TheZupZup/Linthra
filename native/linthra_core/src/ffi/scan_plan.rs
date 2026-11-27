//! C ABI for [crate::scan::incremental]: one call per audio file the scan
//! walks, before its tags are read ([linthra_scan_plan]) and after
//! ([linthra_scan_settle]).
//!
//! Records are flat `i64` arrays, a flag before each optional value:
//!
//! - a file: `[stamp known, size, mtime]` ([FILE_FIELDS]);
//! - an indexed row: `[present, stamp known, size, mtime, cue size known,
//!   cue size, cue mtime known, cue mtime, artwork missing]`
//!   ([INDEXED_FIELDS]);
//! - a CUE track: `[sheet stamp known, size, mtime]` then its indexed row
//!   ([CUE_FIELDS] in all).

use crate::scan::incremental::{plan, settle, CueEntry, Indexed, Read, ScanFile, Settled, Stamp};

pub const FILE_FIELDS: usize = 3;
pub const INDEXED_FIELDS: usize = 9;
pub const CUE_FIELDS: usize = 3 + INDEXED_FIELDS;

/// [linthra_scan_settle]'s answer, as bits.
pub const SETTLE_KEEP: i32 = 1;
pub const SETTLE_STAMP: i32 = 2;
pub const SETTLE_VANISHED: i32 = 4;
pub const SETTLE_REUSED: i32 = 8;

fn stamp(fields: &[i64]) -> Option<Stamp> {
    (fields[0] != 0).then_some(Stamp {
        size: fields[1],
        modified_ms: fields[2],
    })
}

fn indexed(fields: &[i64]) -> Option<Indexed> {
    (fields[0] != 0).then(|| Indexed {
        stamp: stamp(&fields[1..4]),
        cue_sheet_size: (fields[4] != 0).then_some(fields[5]),
        cue_sheet_modified_ms: (fields[6] != 0).then_some(fields[7]),
        artwork_missing: fields[8] != 0,
    })
}

/// The file the arrays describe, or None for a null array that should
/// hold something.
///
/// # Safety
///
/// As [linthra_scan_plan].
unsafe fn scan_file(
    file: *const i64,
    indexed_row: *const i64,
    cue: *const i64,
    cue_count: usize,
) -> Option<ScanFile> {
    if file.is_null() || indexed_row.is_null() || (cue.is_null() && cue_count > 0) {
        return None;
    }
    let file_fields = std::slice::from_raw_parts(file, FILE_FIELDS);
    let indexed_fields = std::slice::from_raw_parts(indexed_row, INDEXED_FIELDS);
    let cue_fields = if cue_count == 0 {
        &[][..]
    } else {
        std::slice::from_raw_parts(cue, cue_count.checked_mul(CUE_FIELDS)?)
    };
    Some(ScanFile {
        stamp: stamp(file_fields),
        indexed: indexed(indexed_fields),
        cue: cue_fields
            .as_chunks::<CUE_FIELDS>()
            .0
            .iter()
            .map(|entry| CueEntry {
                sheet: stamp(&entry[..3]),
                indexed: indexed(&entry[3..]),
            })
            .collect(),
    })
}

/// [plan]: 1 when the file's indexed row(s) are reused without reading it,
/// 0 when its tags are read, -1 when an array is null.
///
/// # Safety
///
/// `file` must be valid for [FILE_FIELDS] reads and `indexed` for
/// [INDEXED_FIELDS]; `cue` must be null or valid for `cue_count *`
/// [CUE_FIELDS].
#[no_mangle]
pub unsafe extern "C" fn linthra_scan_plan(
    file: *const i64,
    indexed: *const i64,
    cue: *const i64,
    cue_count: usize,
    read_unchanged: bool,
) -> i32 {
    crate::ffi::guard(-1, || {
        crate::ffi::fail_safe(
            || match scan_file(file, indexed, cue, cue_count) {
                Some(f) => i32::from(plan(&f, read_unchanged)),
                None => -1,
            },
            || {
                // Safe answer: read the file.
                0
            },
        )
    })
}

/// [settle]: [SETTLE_KEEP] when the indexed row(s) stand, with
/// [SETTLE_VANISHED] and [SETTLE_REUSED] as [Settled::Keep] says, and
/// [SETTLE_STAMP] when the file's stamp is stored; -1 when an array is null.
///
/// # Safety
///
/// As [linthra_scan_plan].
#[no_mangle]
pub unsafe extern "C" fn linthra_scan_settle(
    file: *const i64,
    indexed: *const i64,
    cue: *const i64,
    cue_count: usize,
    read_unchanged: bool,
    has_tags: bool,
    failed: bool,
) -> i32 {
    crate::ffi::guard(-1, || {
        crate::ffi::fail_safe(
            || {
                let Some(f) = scan_file(file, indexed, cue, cue_count) else {
                    return -1;
                };
                match settle(&f, Read { has_tags, failed }, read_unchanged) {
                    Settled::Keep {
                        stamp,
                        vanished,
                        reused,
                    } => {
                        SETTLE_KEEP
                            | if stamp { SETTLE_STAMP } else { 0 }
                            | if vanished { SETTLE_VANISHED } else { 0 }
                            | if reused { SETTLE_REUSED } else { 0 }
                    }
                    Settled::Build { stamp } => {
                        if stamp {
                            SETTLE_STAMP
                        } else {
                            0
                        }
                    }
                }
            },
            || {
                // Safe answer: keep what is indexed when there is a row for
                // everything, else build from the read; no stamp either way,
                // so the next scan reads the file again.
                match scan_file(file, indexed, cue, cue_count) {
                    Some(f)
                        if (f.cue.is_empty() && f.indexed.is_some())
                            || (!f.cue.is_empty()
                                && f.cue.iter().all(|entry| entry.indexed.is_some())) =>
                    {
                        SETTLE_KEEP
                    }
                    _ => 0,
                }
            },
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const NONE: [i64; INDEXED_FIELDS] = [0; INDEXED_FIELDS];

    fn row(size: i64, mtime: i64) -> [i64; INDEXED_FIELDS] {
        [1, 1, size, mtime, 0, 0, 0, 0, 0]
    }

    #[test]
    fn reuses_an_unchanged_file_and_reads_a_changed_one() {
        let file = [1, 100, 5];
        unsafe {
            assert_eq!(
                linthra_scan_plan(
                    file.as_ptr(),
                    row(100, 5).as_ptr(),
                    std::ptr::null(),
                    0,
                    false
                ),
                1
            );
            assert_eq!(
                linthra_scan_plan(
                    file.as_ptr(),
                    row(90, 5).as_ptr(),
                    std::ptr::null(),
                    0,
                    false
                ),
                0
            );
            assert_eq!(
                linthra_scan_plan(file.as_ptr(), NONE.as_ptr(), std::ptr::null(), 0, false),
                0
            );
        }
    }

    #[test]
    fn reads_cue_tracks_from_their_records() {
        let file = [1, 100, 5];
        let mut cue = [0i64; 2 * CUE_FIELDS];
        for entry in cue.as_chunks_mut::<CUE_FIELDS>().0 {
            entry.copy_from_slice(&[1, 7, 9, 1, 1, 100, 5, 1, 7, 1, 9, 0]);
        }
        unsafe {
            assert_eq!(
                linthra_scan_plan(file.as_ptr(), NONE.as_ptr(), cue.as_ptr(), 2, false),
                1
            );
            // The second track's sheet changed.
            cue[CUE_FIELDS + 2] = 10;
            assert_eq!(
                linthra_scan_plan(file.as_ptr(), NONE.as_ptr(), cue.as_ptr(), 2, false),
                0
            );
        }
    }

    #[test]
    fn settles_into_bits() {
        unsafe {
            // Vanished mid-scan: kept, reused, no stamp.
            let gone = [0, 0, 0];
            assert_eq!(
                linthra_scan_settle(
                    gone.as_ptr(),
                    row(100, 5).as_ptr(),
                    std::ptr::null(),
                    0,
                    false,
                    false,
                    true
                ),
                SETTLE_KEEP | SETTLE_VANISHED | SETTLE_REUSED
            );
            // A new file read fine: built and stamped.
            let file = [1, 100, 5];
            assert_eq!(
                linthra_scan_settle(
                    file.as_ptr(),
                    NONE.as_ptr(),
                    std::ptr::null(),
                    0,
                    false,
                    true,
                    false
                ),
                SETTLE_STAMP
            );
            // Unchanged, re-read for its cover and the read failed: kept.
            assert_eq!(
                linthra_scan_settle(
                    file.as_ptr(),
                    row(100, 5).as_ptr(),
                    std::ptr::null(),
                    0,
                    false,
                    false,
                    true
                ),
                SETTLE_KEEP | SETTLE_STAMP
            );
        }
    }

    #[test]
    fn refuses_null_arrays() {
        let file = [1, 100, 5];
        unsafe {
            assert_eq!(
                linthra_scan_plan(std::ptr::null(), NONE.as_ptr(), std::ptr::null(), 0, false),
                -1
            );
            assert_eq!(
                linthra_scan_plan(file.as_ptr(), std::ptr::null(), std::ptr::null(), 0, false),
                -1
            );
            assert_eq!(
                linthra_scan_plan(file.as_ptr(), NONE.as_ptr(), std::ptr::null(), 1, false),
                -1
            );
            assert_eq!(
                linthra_scan_settle(
                    file.as_ptr(),
                    NONE.as_ptr(),
                    std::ptr::null(),
                    1,
                    false,
                    true,
                    false
                ),
                -1
            );
        }
    }
}
