//! C ABI for [crate::queue_moves] and [crate::queue_edits].
//!
//! A move crosses as plain numbers. An edit takes the queue's ids as arrays
//! and returns an opaque [QueueEditResult] that Dart reads, then frees with
//! [linthra_queue_edit_free]. Each source crosses as one `i64`: its kind in
//! the high 32 bits (0 play order, 1 order before shuffle, 2 added) and its
//! position in the low 32.

use std::ptr;

use crate::queue_edits::{edit_queue, QueueEdit, QueueIds, QueueOp, Source};
use crate::queue_moves::{queue_move_target, QueueMove};

/// [linthra_queue_move]: the move does nothing.
pub const QUEUE_MOVE_NONE: i64 = -1;
/// [linthra_queue_move]: the move code was not known.
pub const QUEUE_MOVE_INVALID: i64 = -2;

/// Edit codes, as `QueueOp`.
pub const QUEUE_EDIT_INSERT_NEXT: u8 = 0;
pub const QUEUE_EDIT_APPEND: u8 = 1;
pub const QUEUE_EDIT_REMOVE_UP_NEXT_AT: u8 = 2;
pub const QUEUE_EDIT_REORDER_UP_NEXT: u8 = 3;
pub const QUEUE_EDIT_REMOVE_WHERE: u8 = 4;
pub const QUEUE_EDIT_SHUFFLE: u8 = 5;
pub const QUEUE_EDIT_UNSHUFFLE: u8 = 6;

/// An edit's answer: `edit` is `None` when it left the queue alone.
pub struct QueueEditResult {
    edit: Option<QueueEdit>,
    sources: Vec<i64>,
    original_ids: Vec<i64>,
    original_sources: Vec<i64>,
}

/// `QueueMove.values` in Dart: next, previous, restart, moveTo, jumpToUpNext,
/// jumpToHistory.
fn queue_move(code: u8) -> Option<QueueMove> {
    Some(match code {
        0 => QueueMove::Next,
        1 => QueueMove::Previous,
        2 => QueueMove::Restart,
        3 => QueueMove::MoveTo,
        4 => QueueMove::JumpToUpNext,
        5 => QueueMove::JumpToHistory,
        _ => return None,
    })
}

/// [queue_move_target]: the new position, [QUEUE_MOVE_NONE] or
/// [QUEUE_MOVE_INVALID].
#[no_mangle]
pub extern "C" fn linthra_queue_move(length: i64, current: i64, move_code: u8, index: i64) -> i64 {
    crate::ffi::guard(QUEUE_MOVE_INVALID, || match queue_move(move_code) {
        Some(m) => queue_move_target(length, current, m, index).unwrap_or(QUEUE_MOVE_NONE),
        None => QUEUE_MOVE_INVALID,
    })
}

fn source_code(source: Source) -> i64 {
    let (kind, at) = match source {
        Source::Track(i) => (0, i),
        Source::Original(i) => (1, i),
        Source::Added(i) => (2, i),
    };
    (kind << 32) | at as i64
}

/// Edits the queue of `len` entries (`ids`, current at `current`), shuffled
/// when `has_original` with `original_len` ids before shuffle in `original`.
///
/// `a` and `b` are the edit's arguments (insert: the count; remove: the
/// position in up next; reorder: from and to), `seed` the shuffle's.
/// `removed` and `removed_original` are only read by a remove-where, one flag
/// (0 or 1) per entry of each order.
///
/// Returns null for an unknown edit code or an array that is null while its
/// length is not zero. Free the result with [linthra_queue_edit_free].
///
/// # Safety
///
/// Each pointer must be null or valid for reads of the length given above,
/// for the duration of the call.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn linthra_queue_edit(
    op_code: u8,
    a: i64,
    b: i64,
    seed: u64,
    ids: *const i64,
    len: usize,
    current: i64,
    has_original: bool,
    original: *const i64,
    original_len: usize,
    removed: *const u8,
    removed_original: *const u8,
) -> *mut QueueEditResult {
    crate::ffi::guard(ptr::null_mut(), || {
        let run = || -> Option<QueueEditResult> {
            let queue = QueueIds {
                ids: array(ids, len)?.to_vec(),
                current,
                original: if has_original {
                    Some(array(original, original_len)?.to_vec())
                } else {
                    None
                },
            };
            let flags = |p: *const u8, n: usize| -> Option<Vec<bool>> {
                Some(array(p, n)?.iter().map(|f| *f != 0).collect())
            };
            let (removed, removed_original) = if op_code == QUEUE_EDIT_REMOVE_WHERE {
                (
                    flags(removed, len)?,
                    flags(
                        removed_original,
                        if has_original { original_len } else { 0 },
                    )?,
                )
            } else {
                (Vec::new(), Vec::new())
            };
            let op = match op_code {
                QUEUE_EDIT_INSERT_NEXT | QUEUE_EDIT_APPEND => QueueOp::Insert {
                    count: usize::try_from(a).ok()?,
                    after_current: op_code == QUEUE_EDIT_INSERT_NEXT,
                },
                QUEUE_EDIT_REMOVE_UP_NEXT_AT => QueueOp::RemoveUpNextAt(a),
                QUEUE_EDIT_REORDER_UP_NEXT => QueueOp::ReorderUpNext(a, b),
                QUEUE_EDIT_REMOVE_WHERE => QueueOp::RemoveWhere {
                    removed: &removed,
                    removed_original: &removed_original,
                },
                QUEUE_EDIT_SHUFFLE => QueueOp::Shuffle { seed },
                QUEUE_EDIT_UNSHUFFLE => QueueOp::Unshuffle,
                _ => return None,
            };
            let edit = edit_queue(&queue, &op);
            let sources = edit
                .iter()
                .flat_map(|e| e.sources.iter().copied().map(source_code))
                .collect();
            let (original_ids, original_sources) =
                match edit.as_ref().and_then(|e| e.original.as_ref()) {
                    Some((ids, sources)) => (
                        ids.clone(),
                        sources.iter().copied().map(source_code).collect(),
                    ),
                    None => (Vec::new(), Vec::new()),
                };
            Some(QueueEditResult {
                edit,
                sources,
                original_ids,
                original_sources,
            })
        };
        run().map_or(ptr::null_mut(), |r| Box::into_raw(Box::new(r)))
    })
}

/// Reads a result from [linthra_queue_edit], or a default for null.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_queue_edit].
unsafe fn read<T>(
    result: *const QueueEditResult,
    f: impl Fn(&QueueEditResult) -> T,
    default: T,
) -> T {
    result.as_ref().map_or(default, f)
}

/// Whether the edit changed the queue.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_queue_edit].
#[no_mangle]
pub unsafe extern "C" fn linthra_queue_edit_changed(result: *const QueueEditResult) -> bool {
    crate::ffi::guard(false, || read(result, |r| r.edit.is_some(), false))
}

/// The edited queue's length.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_queue_edit].
#[no_mangle]
pub unsafe extern "C" fn linthra_queue_edit_len(result: *const QueueEditResult) -> usize {
    crate::ffi::guard(0, || {
        read(result, |r| r.edit.as_ref().map_or(0, |e| e.ids.len()), 0)
    })
}

/// The edited queue's ids, [linthra_queue_edit_len] of them.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_queue_edit]; the
/// array lives as long as the result.
#[no_mangle]
pub unsafe extern "C" fn linthra_queue_edit_ids(result: *const QueueEditResult) -> *const i64 {
    crate::ffi::guard(ptr::null(), || {
        read(
            result,
            |r| r.edit.as_ref().map_or(ptr::null(), |e| e.ids.as_ptr()),
            ptr::null(),
        )
    })
}

/// Where each entry came from, [linthra_queue_edit_len] of them.
///
/// # Safety
///
/// As [linthra_queue_edit_ids].
#[no_mangle]
pub unsafe extern "C" fn linthra_queue_edit_sources(result: *const QueueEditResult) -> *const i64 {
    crate::ffi::guard(ptr::null(), || {
        read(result, |r| r.sources.as_ptr(), ptr::null())
    })
}

/// The edited queue's current position.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_queue_edit].
#[no_mangle]
pub unsafe extern "C" fn linthra_queue_edit_current(result: *const QueueEditResult) -> i64 {
    crate::ffi::guard(-1, || {
        read(result, |r| r.edit.as_ref().map_or(-1, |e| e.current), -1)
    })
}

/// Whether the edited queue is shuffled.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_queue_edit].
#[no_mangle]
pub unsafe extern "C" fn linthra_queue_edit_has_original(result: *const QueueEditResult) -> bool {
    crate::ffi::guard(false, || {
        read(
            result,
            |r| r.edit.as_ref().is_some_and(|e| e.original.is_some()),
            false,
        )
    })
}

/// How many ids the order before shuffle holds.
///
/// # Safety
///
/// `result` must be null or a live pointer from [linthra_queue_edit].
#[no_mangle]
pub unsafe extern "C" fn linthra_queue_edit_original_len(result: *const QueueEditResult) -> usize {
    crate::ffi::guard(0, || read(result, |r| r.original_ids.len(), 0))
}

/// The ids before shuffle, [linthra_queue_edit_original_len] of them.
///
/// # Safety
///
/// As [linthra_queue_edit_ids].
#[no_mangle]
pub unsafe extern "C" fn linthra_queue_edit_original_ids(
    result: *const QueueEditResult,
) -> *const i64 {
    crate::ffi::guard(ptr::null(), || {
        read(result, |r| r.original_ids.as_ptr(), ptr::null())
    })
}

/// Where each entry before shuffle came from.
///
/// # Safety
///
/// As [linthra_queue_edit_ids].
#[no_mangle]
pub unsafe extern "C" fn linthra_queue_edit_original_sources(
    result: *const QueueEditResult,
) -> *const i64 {
    crate::ffi::guard(ptr::null(), || {
        read(result, |r| r.original_sources.as_ptr(), ptr::null())
    })
}

/// Frees a result from [linthra_queue_edit]. Null is a no-op.
///
/// # Safety
///
/// `result` must be null or a pointer from [linthra_queue_edit] not freed
/// yet. It and the arrays read from it must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn linthra_queue_edit_free(result: *mut QueueEditResult) {
    crate::ffi::guard((), || {
        if !result.is_null() {
            drop(Box::from_raw(result));
        }
    })
}

/// `len` values at `p`, or none when `p` is null while `len` is not zero.
///
/// # Safety
///
/// `p` must be null or valid for `len` reads.
unsafe fn array<'a, T>(p: *const T, len: usize) -> Option<&'a [T]> {
    if len == 0 {
        Some(&[])
    } else if p.is_null() {
        None
    } else {
        Some(std::slice::from_raw_parts(p, len))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn moves_cross_as_numbers() {
        assert_eq!(linthra_queue_move(3, 0, 0, 0), 1);
        assert_eq!(linthra_queue_move(3, 2, 0, 0), QUEUE_MOVE_NONE);
        assert_eq!(linthra_queue_move(3, 0, 9, 0), QUEUE_MOVE_INVALID);
    }

    #[test]
    fn an_edit_reports_ids_and_sources() {
        let ids = [0i64, 1, 2];
        unsafe {
            let r = linthra_queue_edit(
                QUEUE_EDIT_INSERT_NEXT,
                1,
                0,
                0,
                ids.as_ptr(),
                3,
                0,
                false,
                ptr::null(),
                0,
                ptr::null(),
                ptr::null(),
            );
            assert!(linthra_queue_edit_changed(r));
            let len = linthra_queue_edit_len(r);
            let got = std::slice::from_raw_parts(linthra_queue_edit_ids(r), len);
            let sources = std::slice::from_raw_parts(linthra_queue_edit_sources(r), len);
            assert_eq!(got, [0, 3, 1, 2]);
            assert_eq!(sources, [0, 2 << 32, 1, 2]);
            assert!(!linthra_queue_edit_has_original(r));
            linthra_queue_edit_free(r);
        }
    }

    #[test]
    fn refuses_bad_input() {
        unsafe {
            let unknown = linthra_queue_edit(
                99,
                0,
                0,
                0,
                ptr::null(),
                0,
                -1,
                false,
                ptr::null(),
                0,
                ptr::null(),
                ptr::null(),
            );
            assert!(unknown.is_null());
            let missing = linthra_queue_edit(
                QUEUE_EDIT_SHUFFLE,
                0,
                0,
                0,
                ptr::null(),
                3,
                0,
                false,
                ptr::null(),
                0,
                ptr::null(),
                ptr::null(),
            );
            assert!(missing.is_null());
            assert!(!linthra_queue_edit_changed(ptr::null()));
            linthra_queue_edit_free(ptr::null_mut());
        }
    }
}
