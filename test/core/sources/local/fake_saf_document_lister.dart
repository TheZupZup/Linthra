import 'package:linthra/core/sources/local/saf_document_lister.dart';

/// A [SafDocumentLister] that returns a canned [SafScanResult], reports SAF
/// traversal unavailable, or throws an arbitrary error — so content-URI
/// scanning can be driven without a device or a platform channel.
///
/// [documents] are the audio documents the native walk would return; pass
/// [filesVisited]/[readFailures] to model the diagnostic counts (visited
/// defaults to the document count, the common all-audio case).
///
/// [documents] and [readFailures] can be changed between scans, so one test
/// can index a tree and then rescan it after part of it stopped answering.
class FakeSafDocumentLister implements SafDocumentLister {
  FakeSafDocumentLister({
    this.documents = const <SafAudioDocument>[],
    int? filesVisited,
    this.foldersVisited = 0,
    this.readFailures = 0,
    this.unsupported = false,
    this.error,
  }) : _filesVisited = filesVisited;

  List<SafAudioDocument> documents;
  final int? _filesVisited;
  final int foldersVisited;
  int readFailures;
  final bool unsupported;
  final Object? error;
  String? requestedTreeUri;
  int cancellations = 0;

  int get filesVisited => _filesVisited ?? documents.length;

  @override
  Future<SafScanResult> listAudioDocuments(String treeUri) async {
    requestedTreeUri = treeUri;
    if (unsupported) {
      throw const SafUnsupportedException();
    }
    final Object? thrown = error;
    if (thrown != null) {
      throw thrown;
    }
    return SafScanResult(
      documents: documents,
      filesVisited: filesVisited,
      foldersVisited: foldersVisited,
      readFailures: readFailures,
    );
  }

  @override
  Future<void> cancelScan() async {
    cancellations++;
  }
}
