//! The local scan, for Dart: `NativeAudioFileScanner`
//! (lib/core/sources/local/native_audio_file_scanner.dart) and
//! `NativeLocalFileStatReader` (lib/core/sources/local/native_file_reads.dart)
//! call these.

use std::sync::Arc;
use std::time::Duration;

use crate::scan::files::{self, SystemFiles};
use crate::scan::walk::{walk, Fault, SystemLister, WalkFailure};

/// What walking a folder found, or why it couldn't.
pub struct FolderWalk {
    /// Every file found, in walk order (`listFiles`' answer).
    pub paths: Vec<String>,
    /// Subfolders that couldn't be listed and were skipped.
    pub unreadable: Vec<String>,
    /// Entries whose name isn't UTF-8 and names nothing as text.
    pub unopenable: Vec<String>,
    /// Set when the walk failed; then the lists above mean nothing.
    pub failure: Option<WalkFault>,
}

/// Why a walk failed, for Dart to classify into a `LocalRootFault`.
pub struct WalkFault {
    /// The folder went away (or stopped answering) during the walk, rather
    /// than failing to open at all.
    pub interrupted: bool,
    /// It stopped answering for the whole stall limit.
    pub stalled: bool,
    /// The errno, when the system gave one.
    pub errno: Option<i32>,
}

/// Walks `folder` for `NativeAudioFileScanner.listFiles` (see
/// `scan::walk`), waiting at most `stall_limit_ms` for each next entry.
pub async fn walk_folder(folder: String, stall_limit_ms: u32) -> FolderWalk {
    let limit = Duration::from_millis(stall_limit_ms as u64);
    match walk(&folder, limit, Arc::new(SystemLister)) {
        Ok(found) => FolderWalk {
            paths: found.paths,
            unreadable: found.unreadable,
            unopenable: found.unopenable,
            failure: None,
        },
        Err(failure) => {
            let (interrupted, fault) = match failure {
                WalkFailure::Root(fault) => (false, fault),
                WalkFailure::Interrupted(fault) => (true, fault),
            };
            let (stalled, errno) = match fault {
                Fault::Stalled => (true, None),
                Fault::Io(errno) => (false, errno),
            };
            FolderWalk {
                paths: Vec::new(),
                unreadable: Vec::new(),
                unopenable: Vec::new(),
                failure: Some(WalkFault {
                    interrupted,
                    stalled,
                    errno,
                }),
            }
        }
    }
}

/// A file's size and last-modified time (`LocalFileStamp`).
pub struct FileStamp {
    pub size_bytes: i64,
    pub modified_at_ms: i64,
}

/// The stamp of the file at `path`, or `None` when it isn't a file, can't be
/// stat'ed, or the `stat` takes longer than `stall_limit_ms`.
pub async fn stamp_file(path: String, stall_limit_ms: u32) -> Option<FileStamp> {
    let limit = Duration::from_millis(stall_limit_ms as u64);
    files::stamp(Arc::new(SystemFiles), &path, limit).map(file_stamp)
}

/// [`stamp_file`] for each of `paths`, in order, in one call. A `stat` that
/// takes longer than `stall_limit_ms` ends the list, with `None` for its
/// path; the caller asks for the rest one by one.
pub async fn stamp_files(paths: Vec<String>, stall_limit_ms: u32) -> Vec<Option<FileStamp>> {
    let limit = Duration::from_millis(stall_limit_ms as u64);
    files::stamps(Arc::new(SystemFiles), paths, limit)
        .into_iter()
        .map(|stamp| stamp.map(file_stamp))
        .collect()
}

fn file_stamp(stamp: files::Stamp) -> FileStamp {
    FileStamp {
        size_bytes: stamp.size,
        modified_at_ms: stamp.modified_ms,
    }
}

/// Whether `path`, inside the selected folder `root`, is gone: the nearest
/// folder on the way up to `root` that can be listed answers without it.
pub async fn is_file_gone(path: String, root: String, stall_limit_ms: u32) -> bool {
    let limit = Duration::from_millis(stall_limit_ms as u64);
    files::is_gone(Arc::new(SystemFiles), &path, &root, limit)
}

/// The bytes of the file at `path`, or `None` when it can't be read in full
/// within `stall_limit_ms`.
pub async fn read_file(path: String, stall_limit_ms: u32) -> Option<Vec<u8>> {
    let limit = Duration::from_millis(stall_limit_ms as u64);
    files::read(Arc::new(SystemFiles), &path, limit)
}
