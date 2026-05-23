import 'package:linthra/core/sources/local/saf_document_lister.dart';

/// A [SafDocumentLister] that returns canned documents, reports SAF traversal
/// unavailable, or throws an arbitrary error — so content-URI scanning can be
/// driven without a device or a platform channel.
class FakeSafDocumentLister implements SafDocumentLister {
  FakeSafDocumentLister({
    this.documents = const <SafAudioDocument>[],
    this.unsupported = false,
    this.error,
  });

  final List<SafAudioDocument> documents;
  final bool unsupported;
  final Object? error;
  String? requestedTreeUri;

  @override
  Future<List<SafAudioDocument>> listAudioDocuments(String treeUri) async {
    requestedTreeUri = treeUri;
    if (unsupported) {
      throw const SafUnsupportedException();
    }
    final Object? thrown = error;
    if (thrown != null) {
      throw thrown;
    }
    return documents;
  }
}
