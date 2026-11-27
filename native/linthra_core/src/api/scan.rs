//! The local scan, for Dart: `NativeAudioFileScanner`
//! (lib/core/sources/local/native_audio_file_scanner.dart) calls these.

use std::sync::Arc;
use std::time::Duration;

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

/// Walks `folder` the way `IoAudioFileScanner.listFiles` does, waiting at
/// most `stall_limit_ms` for each next entry.
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
