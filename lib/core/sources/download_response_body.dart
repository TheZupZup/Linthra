import 'package:http/http.dart' as http;

import '../services/remote_track_downloader.dart';
import 'audio_file_extension.dart';

/// The body of a checked download [response], handed back while it is still
/// arriving so the offline cache can write it to disk a chunk at a time
/// instead of holding the whole file in memory (#745).
///
/// Shared by the remote downloaders (Jellyfin, Subsonic, Plex). The body waits
/// at most [stallTimeout] for each chunk, and any error it raises is replaced
/// with a [StateError] carrying [failure]: a `ClientException`,
/// `SocketException` or `TimeoutException` can embed the tokenized URL in its
/// message, and the body is read outside the downloader, past the point where
/// it can catch them itself.
RemoteTrackData downloadResponseBody(
  http.StreamedResponse response, {
  required String failure,
  required Duration stallTimeout,
}) {
  final int? length = response.contentLength;
  return RemoteTrackData.streamed(
    body: response.stream.timeout(stallTimeout).handleError(
          (Object _) => throw StateError(failure),
        ),
    length: length != null && length > 0 ? length : null,
    fileExtension:
        AudioFileExtension.forContentType(response.headers['content-type']),
  );
}
