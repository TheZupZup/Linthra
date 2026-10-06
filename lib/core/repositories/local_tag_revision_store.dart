/// Which revision of tag reading each local music folder was last read in
/// full with (see `LocalTagRevision`), keyed by the folder as
/// `LocalMusicRoots.canonicalize` spells it.
///
/// A folder read by another revision, or never recorded, is read in full once
/// more, so a change to how tags are read reaches files that haven't changed
/// on disk since they were indexed (#783).
///
/// Privacy: the folder paths the user picked and small numbers, kept on the
/// device like the folder selection itself.
abstract interface class LocalTagRevisionStore {
  Future<Map<String, int>> load();
  Future<void> save(Map<String, int> revisions);
}
