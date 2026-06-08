import 'package:linthra/core/sources/local/saf_document_lister.dart';

/// A [SafDocumentLister] that returns a canned [SafScanResult], reports SAF
/// traversal unavailable, or throws an arbitrary error — so content-URI
/// scanning can be driven without a device or a platform channel.
///
/// [documents] are the audio documents the native walk would return; pass
/// [filesVisited]/[readFailures] to model the diagnostic counts (visited
/// defaults to the document count, the common all-audio case).
class FakeSafDocumentLister implements SafDocumentLister {
  FakeSafDocumentLister({
    this.documents = const <SafAudioDocument>[],
    int? filesVisited,
    this.readFailures = 0,
    this.unsupported = false,
    this.error,
  }) : filesVisited = filesVisited ?? documents.length;

  final List<SafAudioDocument> documents;
  final int filesVisited;
  final int readFailures;
  final bool unsupported;
  final Object? error;
  String? requestedTreeUri;

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
      readFailures: readFailures,
    );
  }
}
