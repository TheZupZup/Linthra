// Only refusals in a row stop "Download all", not refusals in total.
//
// The cache refuses a track larger than everything it could free just as it
// refuses one when it is full, so the batch gives up only after three
// refusals in a row: a smaller song after an oversized one may still fit.
// The streak has to start over at every song that isn't a refusal, whether it
// downloaded, was held for the network, or failed some other way. Counting
// refusals in total instead would stop an album of a few hi-res tracks mixed
// with small ones partway, with room left for the rest.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/bulk_download_summary.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/services/bulk_downloader.dart';

import '../../features/downloads/fake_download_repository.dart';

Track _remote(String id) =>
    Track(id: id, title: 'Song $id', uri: 'jellyfin:$id', albumName: 'Album');

final List<Track> _six = <Track>[
  for (int i = 1; i <= 6; i++) _remote('$i'),
];

/// A [FakeDownloadRepository] whose request for each of [throwingUris] fails
/// outright with an error that isn't a cache refusal, the way a record store
/// that can't be read fails a request.
class _ThrowingRepository extends FakeDownloadRepository {
  _ThrowingRepository({super.tooLargeUris, required this.throwingUris});

  final Set<String> throwingUris;

  @override
  Future<DownloadRequestOutcome> requestDownload(Track track) async {
    if (throwingUris.contains(track.uri)) {
      requested.add(track.uri);
      await Future<void>.delayed(Duration.zero);
      throw StateError('The download records could not be read.');
    }
    return super.requestDownload(track);
  }
}

void main() {
  test('refusals broken up by a download never add up to a stop', () async {
    // Two refused, one fits, two refused, one fits: never three in a row.
    final FakeDownloadRepository repository = FakeDownloadRepository(
      tooLargeUris: <String>{
        'jellyfin:1',
        'jellyfin:2',
        'jellyfin:4',
        'jellyfin:5',
      },
    );

    final BulkDownloadSummary summary =
        await const BulkDownloader(maxOutstanding: 1).run(
      repository: repository,
      label: 'Album',
      tracks: _six,
    );

    expect(repository.requested, <String>[
      for (final Track t in _six) t.uri,
    ]);
    expect(summary.outOfSpace, isFalse);
    expect(summary.cacheRefused, 4);
    expect(summary.downloaded, 2);
    expect(summary.completed, 6);
  });

  test('a song that fails another way starts the streak over too', () async {
    // Two refused, one that fails outright, two refused, one that fits.
    final _ThrowingRepository repository = _ThrowingRepository(
      tooLargeUris: <String>{
        'jellyfin:1',
        'jellyfin:2',
        'jellyfin:4',
        'jellyfin:5',
      },
      throwingUris: <String>{'jellyfin:3'},
    );

    final BulkDownloadSummary summary =
        await const BulkDownloader(maxOutstanding: 1).run(
      repository: repository,
      label: 'Album',
      tracks: _six,
    );

    expect(repository.requested, <String>[
      for (final Track t in _six) t.uri,
    ]);
    expect(summary.outOfSpace, isFalse);
    expect(summary.cacheRefused, 4);
    expect(summary.downloaded, 1);
  });

  test('a song held for the network starts the streak over too', () async {
    final FakeDownloadRepository repository = FakeDownloadRepository(
      tooLargeUris: <String>{
        'jellyfin:1',
        'jellyfin:2',
        'jellyfin:4',
        'jellyfin:5',
      },
      outcomes: <String, DownloadRequestOutcome>{
        'jellyfin:3': DownloadRequestOutcome.waitingForWifi,
      },
    );

    final BulkDownloadSummary summary =
        await const BulkDownloader(maxOutstanding: 1).run(
      repository: repository,
      label: 'Album',
      tracks: _six,
    );

    expect(repository.requested, hasLength(6));
    expect(summary.outOfSpace, isFalse);
    expect(summary.waitingForNetwork, 1);
    expect(summary.cacheRefused, 4);
  });
}
