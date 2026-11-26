import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');

/// A full Git object name, in either the SHA-1 or the SHA-256 object format.
/// An abbreviated hash, a tag or a branch is not enough: only a full commit
/// identifies the exact tree flatpak-builder will check out.
final RegExp _gitCommit = RegExp(r'^([0-9a-f]{40}|[0-9a-f]{64})$');

/// Flatpak architecture -> the architecture directory Flutter's Linux tool
/// uses for `build/linux/<arch>/release`, which is also the CMake binary dir
/// every plugin's generated CMake resolves its download paths against.
const Map<String, String> _flutterArchDirectories = <String, String>{
  'x86_64': 'x64',
  'aarch64': 'arm64',
};

/// pub's own cache layout inside the build. `flutter pub get --offline`
/// resolves packages from the first and validates them against the second, so
/// a generated source that lands anywhere else is staged but unusable.
const String _hostedRoot = '.pub-cache/hosted/pub.dev';
const String _hostedHashRoot = '.pub-cache/hosted-hashes/pub.dev';

typedef _HostedPackage = ({String version, String sha256});

/// One block-sequence mapping: the 1-based line it starts on, and its lines.
typedef _YamlMapping = ({int line, List<String> lines});

typedef _FetchContentDeclaration = ({
  String name,
  String url,
  String sha256,
});

String _read(String path) => File(path).readAsStringSync();

bool _isRemoteUrl(Object? value) {
  return value is String &&
      (value.startsWith('https://') || value.startsWith('http://'));
}

Iterable<Map<String, dynamic>> _maps(Object? value) sync* {
  if (value is! List<dynamic>) return;
  for (final Object? item in value) {
    if (item is Map<String, dynamic>) yield item;
  }
}

void _expectRemoteSourcesHashed(Object? value, String context) {
  for (final Map<String, dynamic> source in _maps(value)) {
    final Object? type = source['type'];
    final Object? url = source['url'];
    if (!_isRemoteUrl(url)) continue;

    // A `git` source is content-addressed by its commit, not by a digest of
    // the fetched bytes. A tag or a branch is mutable upstream, so without a
    // commit phase 1 could fetch different code tomorrow and phase 2 would
    // rebuild from it without noticing.
    if (type == 'git') {
      expect(
        source['commit'],
        isA<String>().having(
          (String value) => _gitCommit.hasMatch(value),
          'full commit hash',
          isTrue,
        ),
        reason:
            '$context remote git source is not pinned to a full commit: $url',
      );
      continue;
    }

    if (type != 'archive' && type != 'file') continue;

    final Object? digest = source['sha256'];
    expect(
      digest,
      isA<String>().having(
        (String value) => _sha256.hasMatch(value),
        'valid SHA-256',
        isTrue,
      ),
      reason: '$context remote $type source is not content-addressed: $url',
    );
  }
}

void _expectJsonSourcesHashed(Object? value, String context) {
  if (value is Map<String, dynamic>) {
    if (value.containsKey('sources')) {
      _expectRemoteSourcesHashed(value['sources'], context);
    }
    for (final Object? child in value.values) {
      _expectJsonSourcesHashed(child, context);
    }
    return;
  }

  if (value is List<dynamic>) {
    for (final Object? child in value) {
      _expectJsonSourcesHashed(child, context);
    }
  }
}

Map<String, _HostedPackage> _hostedPackagesFromLockfile(String contents) {
  final Map<String, _HostedPackage> result = <String, _HostedPackage>{};
  String? currentPackage;
  String? currentVersion;
  String? currentSha256;
  bool currentIsHosted = false;
  bool inPackages = false;

  void flush() {
    if (currentPackage != null &&
        currentIsHosted &&
        currentVersion != null &&
        currentSha256 != null) {
      result[currentPackage] = (
        version: currentVersion,
        sha256: currentSha256,
      );
    }
  }

  for (final String line in const LineSplitter().convert(contents)) {
    if (!inPackages) {
      if (line == 'packages:') inPackages = true;
      continue;
    }

    if (line.isNotEmpty && !line.startsWith(' ')) break;

    final RegExpMatch? packageMatch =
        RegExp(r'^  ([A-Za-z0-9_]+):$').firstMatch(line);
    if (packageMatch != null) {
      flush();
      currentPackage = packageMatch.group(1);
      currentVersion = null;
      currentSha256 = null;
      currentIsHosted = false;
      continue;
    }

    if (currentPackage == null) continue;

    final String trimmed = line.trim();
    if (trimmed == 'source: hosted') {
      currentIsHosted = true;
    } else if (trimmed.startsWith('version:')) {
      currentVersion = _unquote(trimmed.substring('version:'.length).trim());
    } else if (trimmed.startsWith('sha256:')) {
      currentSha256 = _unquote(trimmed.substring('sha256:'.length).trim());
    }
  }

  flush();
  return result;
}

String _unquote(String value) {
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

/// A scalar value with any trailing comment removed. YAML starts an inline
/// comment at a ` #`, so `type: archive # note` is still the archive type; not
/// stripping it would leave the value unrecognised and the source unaudited.
String _yamlValue(String raw) {
  final int comment = raw.indexOf(' #');
  return _unquote((comment == -1 ? raw : raw.substring(0, comment)).trim());
}

String? _yamlScalar(List<String> block, String key) {
  final String prefix = '$key:';
  for (final String line in block) {
    final String trimmed = line.trim();
    if (!trimmed.startsWith(prefix)) continue;
    return _yamlValue(trimmed.substring(prefix.length));
  }
  return null;
}

/// A guard that cannot fully interpret its input has to fail, not skip.
///
/// flatpak-flutter emits the manifest in block style and every check here
/// reads it that way. YAML's flow forms (`{a: b}`, `[a, b]`) and its anchors
/// and aliases express the same data in shapes these line-oriented checks
/// would walk straight past, so encountering one is itself the failure. That
/// keeps a serialization change from quietly turning a guard into a no-op.
void _expectBlockStyleManifest(String manifest) {
  final RegExp flow = RegExp(r'[\[{]');
  final RegExp anchorOrAlias = RegExp(r'(^|\s)[&*][A-Za-z0-9_-]+');

  final List<String> lines = const LineSplitter().convert(manifest);
  for (int index = 0; index < lines.length; index++) {
    final String trimmed = lines[index].trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

    final int comment = trimmed.indexOf(' #');
    final String content =
        comment == -1 ? trimmed : trimmed.substring(0, comment);
    if (flow.hasMatch(content) || anchorOrAlias.hasMatch(content)) {
      fail(
        'The generated manifest uses YAML flow style, an anchor or an alias '
        'near line ${index + 1}, which these guards do not interpret: '
        '${lines[index]}\n'
        'Regenerate it in block style, or teach the guards that form before '
        'trusting them.',
      );
    }
  }
}

/// Every block-sequence mapping in [manifest], with the leading `- ` folded
/// into the indentation so its first key reads like the rest.
///
/// YAML gives no significance to key order, so `- url: ...` followed by
/// `type: archive` is the same mapping as the other way round. The mapping has
/// to be gathered before any key is read from it, or a reordered source slips
/// past the guard entirely.
List<_YamlMapping> _yamlSequenceMappings(String manifest) {
  final List<String> lines = const LineSplitter().convert(manifest);
  final List<_YamlMapping> mappings = <_YamlMapping>[];

  for (int index = 0; index < lines.length; index++) {
    final String line = lines[index];
    if (!line.trimLeft().startsWith('- ')) continue;

    final int indent = line.length - line.trimLeft().length;
    final List<String> block = <String>[
      '${' ' * (indent + 2)}${line.trimLeft().substring(2)}',
    ];

    for (int peerIndex = index + 1; peerIndex < lines.length; peerIndex++) {
      final String peer = lines[peerIndex];
      if (peer.trim().isEmpty) continue;
      // A peer entry or an outdented key ends this mapping.
      if (peer.length - peer.trimLeft().length <= indent) break;
      block.add(peer);
    }

    mappings.add((line: index + 1, lines: block));
  }

  return mappings;
}

void _expectManifestRemoteSourcesHashed(String manifest) {
  _expectBlockStyleManifest(manifest);

  for (final _YamlMapping mapping in _yamlSequenceMappings(manifest)) {
    final String? type = _yamlScalar(mapping.lines, 'type');
    final String? url = _yamlScalar(mapping.lines, 'url');
    if (!_isRemoteUrl(url)) continue;

    if (type == 'git') {
      final String? commit = _yamlScalar(mapping.lines, 'commit');
      expect(
        commit != null && _gitCommit.hasMatch(commit),
        isTrue,
        reason: 'Remote git source near line ${mapping.line} is not pinned to '
            'a full commit: $url',
      );
      continue;
    }

    if (type != 'archive' && type != 'file') continue;

    final String? digest = _yamlScalar(mapping.lines, 'sha256');
    expect(
      digest != null && _sha256.hasMatch(digest),
      isTrue,
      reason: 'Remote $type source near line '
          '${mapping.line} is missing its own valid SHA-256: $url',
    );
  }
}

List<String> _onlyArches(Map<String, dynamic> source) {
  final Object? arches = source['only-arches'];
  if (arches is! List<dynamic>) return const <String>[];
  return arches.whereType<String>().toList();
}

Set<String> _declaredArches(Iterable<Map<String, dynamic>> sources) {
  return sources.expand(_onlyArches).toSet();
}

String _flutterReleaseDirectory(String arch) {
  final String? directory = _flutterArchDirectories[arch];
  expect(
    directory,
    isNotNull,
    reason: 'No Flutter build directory is known for Flatpak arch $arch',
  );
  return './build/linux/$directory/release';
}

/// Where CMake's `FetchContent` parks the archive it downloads for [name],
/// relative to the CMake binary dir. An already-present file with a matching
/// `URL_HASH` there is what makes the download step a no-op, which is the
/// whole point of predeclaring the archive as a Flatpak source.
String _fetchContentDownloadDir(String releaseDirectory, String name) {
  return '$releaseDirectory/_deps/$name-subbuild/$name-populate-prefix/src';
}

/// Reads the `FetchContent_Declare` the locked plugin actually builds with,
/// out of the committed patch applied to its `CMakeLists.txt`. Deriving the
/// name, URL and hash from there means the guard follows a plugin bump instead
/// of pinning a copy of it that can silently go stale.
_FetchContentDeclaration _fetchContentDeclarationFromPatch(String patch) {
  bool inDeclaration = false;
  String? name;
  String? url;
  String? sha256;

  for (final String line in const LineSplitter().convert(patch)) {
    // Drop the unified-diff marker so context and added lines read alike.
    final String trimmed = (line.isEmpty ? line : line.substring(1)).trim();

    if (trimmed == 'FetchContent_Declare(') {
      inDeclaration = true;
      name = null;
      url = null;
      sha256 = null;
      continue;
    }
    if (!inDeclaration) continue;
    if (trimmed == ')') {
      inDeclaration = false;
      continue;
    }

    if (trimmed.startsWith('URL_HASH SHA256=')) {
      sha256 = trimmed.substring('URL_HASH SHA256='.length).trim();
    } else if (trimmed.startsWith('URL ')) {
      url = trimmed.substring('URL '.length).trim();
    } else {
      name ??= trimmed;
    }

    if (name != null && url != null && sha256 != null) {
      return (name: name, url: url, sha256: sha256);
    }
  }

  fail('The patched plugin CMake declares no hashed FetchContent source');
}

/// Assert that a native archive the build fetches for itself is predeclared as
/// a Flatpak source *and* lands exactly where that build looks for it.
///
/// A hash alone is not enough: with the archive staged anywhere else, an
/// uncached `--disable-download` build still reaches upstream and fails.
void _expectPreFetchedNativeInput({
  required Iterable<Map<String, dynamic>> sources,
  required String url,
  required String sha256,
  required String Function(String arch) destination,
  required String filename,
  required Set<String> requiredArches,
  required String label,
  required String context,
}) {
  final List<Map<String, dynamic>> matches = sources
      .where((Map<String, dynamic> source) => source['url'] == url)
      .toList();
  expect(
    matches,
    isNotEmpty,
    reason: '$context predeclares no $label source for $url',
  );

  final Set<String> covered = <String>{};
  for (final Map<String, dynamic> source in matches) {
    expect(
      source['sha256'],
      sha256,
      reason: '$context $label source is not pinned to $sha256',
    );

    // With no `dest-filename` flatpak-builder keeps the URL's own basename.
    expect(
      source['dest-filename'] ?? url.split('/').last,
      filename,
      reason: '$context $label source does not land as $filename',
    );

    final List<String> arches = _onlyArches(source);
    expect(
      arches,
      isNotEmpty,
      reason: '$context $label source declares no only-arches, so its '
          'architecture-specific destination cannot be checked',
    );

    for (final String arch in arches) {
      expect(
        source['dest'],
        destination(arch),
        reason: '$context $label source for $arch is not staged where the '
            'build looks for it',
      );
      covered.add(arch);
    }
  }

  expect(
    covered,
    requiredArches,
    reason: '$context does not stage $label for every declared architecture',
  );
}

/// Flatpak parses its options with GLib, which accepts a value either joined
/// (`--share=network`) or as the following argument (`--share`, `network`).
/// Searching for the joined form alone can be stepped around by splitting the
/// grant across two sequence entries, so both forms have to be rejected.
bool _isNetworkGrant(String argument, String? next) {
  return argument.contains('--share=network') ||
      (argument == '--share' && next == 'network');
}

void _expectNoBuildNetworkGrant(String manifest) {
  _expectBlockStyleManifest(manifest);

  final List<String> lines = const LineSplitter().convert(manifest);
  bool inFinishArgs = false;

  // Only entries adjacent in the same block sequence can form a split option,
  // so any other line clears the pending argument.
  String? pending;
  int pendingLine = 0;

  for (int index = 0; index < lines.length; index++) {
    final String line = lines[index];
    final String trimmed = line.trim();

    // A blank line or a comment ends neither a block nor a sequence, so it
    // must not separate the two halves of a split option either.
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

    if (line == 'finish-args:') {
      inFinishArgs = true;
      pending = null;
      continue;
    }
    if (inFinishArgs && !line.startsWith(' ')) {
      inFinishArgs = false;
    }
    // The top-level runtime finish-args are where the grant belongs.
    if (inFinishArgs) {
      pending = null;
      continue;
    }

    if (!trimmed.startsWith('- ')) {
      if (trimmed.contains('--share=network')) {
        fail(
          'Build-time network grant near generated manifest line '
          '${index + 1}: $line',
        );
      }
      pending = null;
      continue;
    }

    final String argument = _yamlValue(trimmed.substring(2));
    if (_isNetworkGrant(argument, null)) {
      fail(
        'Build-time network grant near generated manifest line '
        '${index + 1}: $line',
      );
    }
    if (pending != null && _isNetworkGrant(pending, argument)) {
      fail(
        'Build-time network grant split across generated manifest lines '
        '$pendingLine and ${index + 1}: $pending $argument',
      );
    }

    pending = argument;
    pendingLine = index + 1;
  }
}

/// The same rule for a generated module, which has no finish-args of its own,
/// so any network grant it carries is a build-time one.
void _expectNoJsonNetworkGrant(Object? value, String context) {
  if (value is List<dynamic>) {
    final List<String> arguments = value.whereType<String>().toList();
    for (int index = 0; index < arguments.length; index++) {
      final String? next =
          index + 1 < arguments.length ? arguments[index + 1] : null;
      expect(
        _isNetworkGrant(arguments[index], next),
        isFalse,
        reason: '$context grants build-time network access',
      );
    }
    for (final Object? child in value) {
      _expectNoJsonNetworkGrant(child, context);
    }
    return;
  }

  if (value is Map<String, dynamic>) {
    for (final Object? child in value.values) {
      _expectNoJsonNetworkGrant(child, context);
    }
    return;
  }

  if (value is String) {
    expect(
      value.contains('--share=network'),
      isFalse,
      reason: '$context grants build-time network access',
    );
  }
}

String _linthraModule(String manifest) {
  const String marker = '  - name: linthra\n';
  final int start = manifest.indexOf(marker);
  expect(
    start,
    greaterThanOrEqualTo(0),
    reason: 'Generated manifest has no linthra module',
  );

  final int nextModule = manifest.indexOf('\n  - name:', start + marker.length);
  if (nextModule == -1) return manifest.substring(start);
  return manifest.substring(start, nextModule);
}

/// The `generated/...json` files a manifest module includes under [key].
///
/// Auditing a generated file by its path on disk proves nothing on its own: if
/// regeneration stops referencing it, the file lingers and every assertion
/// against it still passes while the real build stages nothing. Reading the
/// list out of the module keeps the audit pointed at what actually gets built.
List<String> _generatedIncludes(String module, String key) {
  final int start = module.indexOf('\n    $key:\n');
  if (start == -1) return const <String>[];

  final List<String> includes = <String>[];
  for (final String line
      in const LineSplitter().convert(module.substring(start + 1)).skip(1)) {
    if (line.trim().isEmpty) continue;
    if (line.length - line.trimLeft().length <= 4) break;
    final RegExpMatch? match = RegExp(
      r'^- (generated/\S+\.json)$',
    ).firstMatch(line.trim());
    if (match != null) includes.add(match.group(1)!);
  }
  return includes;
}

/// The exact expansion each `flatpak-builder` phase is invoked through.
const String _builderToken = r'"${BUILDER[@]}"';

List<String> _builderInvocations(String smoke) {
  return smoke
      .split(_builderToken)
      .skip(1)
      .map((String tail) => tail.split('\n\n').first)
      .toList();
}

/// Everything the smoke runs before it invokes the builder for the first time.
String _smokePreflight(String smoke) => smoke.split(_builderToken).first;

void main() {
  test('Flatpak build inputs stay complete and network-independent', () {
    final String template = _read('flatpak/flatpak-flutter.yml');
    final String manifest = _read('flatpak/io.github.thezupzup.linthra.yml');
    final String cmake = _read('linux/CMakeLists.txt');

    expect(template, contains('flutter pub get --enforce-lockfile'));
    expect(template, contains('flutter build linux --release --no-pub'));

    final String linthraModule = _linthraModule(manifest);
    final int setupIndex = linthraModule.indexOf('      - setup-flutter.sh');
    final int buildIndex = linthraModule.indexOf(
      '      - flutter build linux --release --no-pub',
    );
    expect(setupIndex, greaterThanOrEqualTo(0));
    expect(buildIndex, greaterThan(setupIndex));

    _expectNoBuildNetworkGrant(manifest);
    _expectManifestRemoteSourcesHashed(manifest);

    final List<File> generatedModules = Directory('flatpak/generated/modules')
        .listSync()
        .whereType<File>()
        .where((File file) => file.path.endsWith('.json'))
        .toList();
    expect(generatedModules, isNotEmpty);

    // The manifest decides what gets built. A generated module the linthra
    // module no longer includes is an orphan every assertion below would still
    // happily pass.
    expect(
      generatedModules.map((File file) => file.path).toSet(),
      _generatedIncludes(
        linthraModule,
        'modules',
      ).map((String include) => 'flatpak/$include').toSet(),
      reason: 'The generated modules on disk and the ones the linthra module '
          'includes have drifted apart',
    );

    final List<File> sdkModules = generatedModules
        .where((File file) => file.path.contains('flutter-sdk-'))
        .toList();
    expect(sdkModules, hasLength(1));

    for (final File module in generatedModules) {
      final String contents = module.readAsStringSync();
      expect(
        contents,
        isNot(contains('--share=network')),
        reason: '${module.path} grants build-time network access',
      );
      final Object? decoded = jsonDecode(contents);
      _expectNoJsonNetworkGrant(decoded, module.path);
      _expectJsonSourcesHashed(decoded, module.path);
    }

    final Map<String, dynamic> sdk =
        jsonDecode(sdkModules.single.readAsStringSync())
            as Map<String, dynamic>;
    final List<Map<String, dynamic>> setupSources = _maps(sdk['sources'])
        .where(
          (Map<String, dynamic> source) =>
              source['dest-filename'] == 'setup-flutter.sh',
        )
        .toList();
    expect(setupSources, hasLength(1));
    expect(
      setupSources.single['commands'],
      contains(r'flutter pub get --offline $@'),
    );

    // The SDK module checks Flutter out from Git rather than from a hashed
    // archive, so its commit is the only thing making that checkout
    // reproducible. `_expectJsonSourcesHashed` above already rejects an
    // unpinned remote Git source; this keeps the SDK's own checkout from
    // disappearing into a source type nothing audits.
    final List<Map<String, dynamic>> sdkGitSources = _maps(sdk['sources'])
        .where((Map<String, dynamic> source) => source['type'] == 'git')
        .toList();
    expect(sdkGitSources, hasLength(1));
    expect(sdkGitSources.single['dest'], 'flutter');
    expect(_isRemoteUrl(sdkGitSources.single['url']), isTrue);
    expect(
      sdkGitSources.single['commit'],
      matches(_gitCommit),
      reason: 'The generated Flutter SDK checkout is not pinned to a commit',
    );

    // Same rule for the pub sources: read the path out of the module rather
    // than off disk, so an audited-but-unreferenced file cannot pass while the
    // build stages no `.pub-cache` for `setup-flutter.sh` to resolve from.
    final List<String> generatedSources = _generatedIncludes(
      linthraModule,
      'sources',
    );
    final List<String> pubSourceIncludes = generatedSources
        .where((String path) => path.endsWith('/pubspec.json'))
        .toList();
    expect(
      pubSourceIncludes,
      hasLength(1),
      reason: 'The linthra module does not include exactly one generated pub '
          'source file',
    );
    // The Rust core's crates, the only other generated source: pinned
    // archives replacing crates.io, so the hook's cargo build fetches
    // nothing. Each crate Cargo.lock names has to be there, with the
    // checksum the lockfile holds.
    final List<String> cargoSourceIncludes = generatedSources
        .where((String path) => path.endsWith('/cargo.json'))
        .toList();
    expect(
      cargoSourceIncludes,
      hasLength(1),
      reason: 'The linthra module does not include exactly one generated '
          'cargo source file',
    );
    expect(
      generatedSources,
      hasLength(pubSourceIncludes.length + cargoSourceIncludes.length),
      reason: 'The linthra module includes a generated source nothing audits',
    );
    final String cargoSourcesPath = 'flatpak/${cargoSourceIncludes.single}';
    final Object? cargoSources = jsonDecode(_read(cargoSourcesPath));
    _expectRemoteSourcesHashed(cargoSources, cargoSourcesPath);
    final Map<String, String> crateHashes = <String, String>{
      for (final Map<String, dynamic> source in _maps(cargoSources))
        if (source['type'] == 'archive')
          (source['dest'] as String).split('/').last:
              source['sha256'] as String,
    };
    final Iterable<RegExpMatch> lockedCrates = RegExp(
      r'name = "([^"]+)"\nversion = "([^"]+)"\nsource = "registry\+[^"]+"\nchecksum = "([0-9a-f]{64})"',
    ).allMatches(_read('native/linthra_core/Cargo.lock'));
    expect(lockedCrates, isNotEmpty);
    for (final RegExpMatch crate in lockedCrates) {
      final String name = '${crate.group(1)}-${crate.group(2)}';
      expect(
        crateHashes[name],
        crate.group(3),
        reason: '$name is not pinned in $cargoSourcesPath with Cargo.lock\'s '
            'checksum: run ./scripts/regenerate_flatpak_sources.sh',
      );
    }

    final String pubSourcesPath = 'flatpak/${pubSourceIncludes.single}';
    final String pubSourcesText = _read(pubSourcesPath);
    final Object? pubSources = jsonDecode(pubSourcesText);
    _expectRemoteSourcesHashed(pubSources, pubSourcesPath);

    final List<Map<String, dynamic>> pubSourceMaps = _maps(pubSources).toList();
    final Map<String, _HostedPackage> hosted =
        _hostedPackagesFromLockfile(_read('pubspec.lock'));
    expect(hosted, isNotEmpty);

    for (final MapEntry<String, _HostedPackage> package in hosted.entries) {
      final String basename = '${package.key}-${package.value.version}';
      final String destination = '$_hostedRoot/$basename';
      final String hashFilename = '$basename.sha256';

      final List<Map<String, dynamic>> archives = pubSourceMaps
          .where(
            (Map<String, dynamic> source) =>
                source['type'] == 'archive' && source['dest'] == destination,
          )
          .toList();
      expect(
        archives,
        hasLength(1),
        reason: '$basename is missing from the generated Flatpak pub cache',
      );
      expect(
        archives.single['sha256'],
        package.value.sha256,
        reason: '$basename archive SHA-256 drifted from pubspec.lock',
      );

      // The hash has to be an inline source under pub's hosted-hashes dir:
      // that is where `flutter pub get --offline` looks to validate the
      // cached package. A correct hash staged anywhere else is dead weight.
      final List<Map<String, dynamic>> hashEntries = pubSourceMaps
          .where(
            (Map<String, dynamic> source) =>
                source['type'] == 'inline' &&
                source['dest'] == _hostedHashRoot &&
                source['dest-filename'] == hashFilename,
          )
          .toList();
      expect(
        hashEntries,
        hasLength(1),
        reason: '$basename has no generated hosted-hash entry under '
            '$_hostedHashRoot',
      );
      expect(
        hashEntries.single['contents'],
        package.value.sha256,
        reason: '$basename hosted-hash contents drifted from pubspec.lock',
      );
    }

    // Native plugin inputs. Both plugins fetch these themselves from CMake, so
    // a hashed source that lands in the wrong place leaves the uncached,
    // download-disabled build reaching upstream anyway.
    // Derived from the Flutter SDK module, which is what says the build is
    // provisioned for these architectures, not from the native inputs being
    // audited. A set built from those same inputs would shrink whenever both
    // architectures' entries disappeared together, and the coverage check
    // would then pass over exactly the gap it exists to catch.
    final Set<String> nativeArches = _declaredArches(_maps(sdk['sources']));
    expect(
      nativeArches,
      isNotEmpty,
      reason: 'The generated Flutter SDK module declares no architectures',
    );

    // sqlite3_flutter_libs: take the SQLite archive the locked plugin build
    // actually asks for from the committed patch to its CMakeLists.txt, then
    // require that exact archive to be staged in FetchContent's own download
    // directory for every architecture the generated sources cover.
    final List<Map<String, dynamic>> sqlitePatches = pubSourceMaps
        .where(
          (Map<String, dynamic> source) =>
              source['type'] == 'patch' &&
              '${source['dest']}'.contains('/sqlite3_flutter_libs-'),
        )
        .toList();
    expect(
      sqlitePatches,
      hasLength(1),
      reason: 'sqlite3_flutter_libs has no generated CMake patch',
    );

    final _FetchContentDeclaration sqlite = _fetchContentDeclarationFromPatch(
      _read('flatpak/${sqlitePatches.single['path']}'),
    );
    expect(
      sqlite.url.split('/').last,
      matches(RegExp(r'^sqlite-autoconf-\d+\.tar\.gz$')),
      reason: 'The locked plugin no longer fetches a SQLite amalgamation',
    );
    expect(
      cmake,
      contains('FETCHCONTENT_SOURCE_DIR_${sqlite.name.toUpperCase()}'),
    );

    _expectPreFetchedNativeInput(
      sources: pubSourceMaps,
      url: sqlite.url,
      sha256: sqlite.sha256,
      destination: (String arch) =>
          _fetchContentDownloadDir(_flutterReleaseDirectory(arch), sqlite.name),
      filename: sqlite.url.split('/').last,
      requiredArches: nativeArches,
      label: 'SQLite',
      context: pubSourcesPath,
    );

    // media_kit_libs_linux: the allocator fetch is switched off in CMake, and
    // the archive it would otherwise download is predeclared next to the build
    // directory it expects. Hold that destination to the same rule so the
    // switch and the staged input cannot drift apart unnoticed.
    expect(cmake, contains('MIMALLOC_USE_STATIC_LIBS OFF'));

    final List<Map<String, dynamic>> mimallocSources = pubSourceMaps
        .where(
          (Map<String, dynamic> source) => RegExp(
            r'^mimalloc-[0-9][0-9.]*\.tar\.gz$',
          ).hasMatch('${source['dest-filename']}'),
        )
        .toList();
    expect(
      mimallocSources,
      isNotEmpty,
      reason: "media_kit's mimalloc input is no longer predeclared",
    );
    final Set<String> mimallocUrls = mimallocSources
        .map((Map<String, dynamic> source) => '${source['url']}')
        .toSet();
    final Set<String> mimallocFilenames = mimallocSources
        .map((Map<String, dynamic> source) => '${source['dest-filename']}')
        .toSet();
    expect(mimallocUrls, hasLength(1));
    expect(mimallocFilenames, hasLength(1));

    _expectPreFetchedNativeInput(
      sources: pubSourceMaps,
      url: mimallocUrls.single,
      sha256: '${mimallocSources.first['sha256']}',
      destination: _flutterReleaseDirectory,
      filename: mimallocFilenames.single,
      requiredArches: nativeArches,
      label: 'mimalloc',
      context: pubSourcesPath,
    );

    final String smoke = _read('scripts/flatpak_offline_build_smoke.sh');

    // The app module stages the whole checkout with `type: dir, path: ..`, so
    // a host build tree reaches the sandbox as *source*. Neither
    // --disable-cache (module build results) nor --disable-download (declared
    // source fetches) keeps it out, so the smoke has to refuse before it
    // fetches anything rather than report a PASS that proves less.
    final String preflight = _smokePreflight(smoke);
    final RegExpMatch? guardedArtifacts = RegExp(
      r'for\s+artifact\s+in\s+([^;\n]+);\s*do',
    ).firstMatch(preflight);
    expect(
      guardedArtifacts,
      isNotNull,
      reason: 'The smoke does not check for host build artifacts before '
          'invoking flatpak-builder',
    );
    expect(
      guardedArtifacts!.group(1)!.trim().split(RegExp(r'\s+')).toSet(),
      <String>{'build', '.dart_tool', '.pub-cache'},
      reason: 'The smoke no longer refuses every host artifact tree that the '
          'staged source directory could smuggle into the build',
    );
    expect(preflight, contains('host build artifacts'));

    final List<String> invocations = _builderInvocations(smoke);
    expect(invocations, hasLength(2));
    expect(invocations[0], contains('--download-only'));
    expect(invocations[0], isNot(contains('--disable-cache')));
    expect(invocations[0], isNot(contains('--disable-download')));
    expect(invocations[1], isNot(contains('--download-only')));
    expect(invocations[1], contains('--disable-cache'));
    expect(invocations[1], contains('--disable-download'));
  });

  test('manifest hash belongs to the same source mapping', () {
    const String manifest = '''
sources:
  - type: archive
    url: https://example.invalid/first.tar.gz
  - type: archive
    url: https://example.invalid/second.tar.gz
    sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
''';

    expect(
      () => _expectManifestRemoteSourcesHashed(manifest),
      throwsA(anything),
    );

    // YAML gives no significance to key order, so a mapping that lists `url`
    // before `type` is the same source and has to be recognised as one.
    expect(
      () => _expectManifestRemoteSourcesHashed('''
sources:
  - url: https://example.invalid/first.tar.gz
    type: archive
'''),
      throwsA(anything),
    );
    expect(
      () => _expectManifestRemoteSourcesHashed('''
sources:
  - url: https://github.com/flutter/flutter.git
    type: git
    tag: '3.44.7'
'''),
      throwsA(anything),
    );

    // A trailing comment must not hide the type and leave the source
    // unaudited.
    expect(
      () => _expectManifestRemoteSourcesHashed('''
sources:
  - type: archive # pinned upstream
    url: https://example.invalid/first.tar.gz
'''),
      throwsA(anything),
    );

    // Flow style says the same thing in a shape these checks do not read, so
    // it is refused rather than skipped.
    expect(
      () => _expectManifestRemoteSourcesHashed('''
sources:
  - {type: archive, url: 'https://example.invalid/first.tar.gz'}
'''),
      throwsA(anything),
    );
    expect(
      () => _expectManifestRemoteSourcesHashed('''
sources: &shared
  - type: archive
    url: https://example.invalid/first.tar.gz
    sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
'''),
      throwsA(anything),
    );
  });

  test('remote file sources require their own SHA-256', () {
    expect(
      () => _expectRemoteSourcesHashed(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'file',
            'url': 'https://example.invalid/sqlite.tar.gz',
          },
        ],
        'fixture',
      ),
      throwsA(anything),
    );
  });

  test('remote git sources require a pinned commit', () {
    const String url = 'https://github.com/flutter/flutter.git';

    // A URL and a tag, but no commit: the tag can move upstream.
    expect(
      () => _expectRemoteSourcesHashed(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'git',
            'url': url,
            'tag': '3.44.7',
            'dest': 'flutter',
          },
        ],
        'fixture',
      ),
      throwsA(anything),
    );

    // An abbreviated commit is not a pin either.
    expect(
      () => _expectRemoteSourcesHashed(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'git',
            'url': url,
            'commit': '84fc5cbb22',
          },
        ],
        'fixture',
      ),
      throwsA(anything),
    );

    // Control: a full commit hash is accepted.
    _expectRemoteSourcesHashed(
      <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'git',
          'url': url,
          'tag': '3.44.7',
          'commit': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        },
      ],
      'fixture',
    );

    // The same rule holds for a Git source written into the manifest itself.
    expect(
      () => _expectManifestRemoteSourcesHashed(
        'sources:\n  - type: git\n    url: $url\n    tag: 3.44.7\n',
      ),
      throwsA(anything),
    );
  });

  test('a hashed native input with the wrong destination is rejected', () {
    const String url =
        'https://example.invalid/2026/sqlite-autoconf-3520000.tar.gz';
    const String filename = 'sqlite-autoconf-3520000.tar.gz';
    const String sha256 =
        '1111111111111111111111111111111111111111111111111111111111111111';

    String destination(String arch) =>
        _fetchContentDownloadDir(_flutterReleaseDirectory(arch), 'sqlite3');

    List<Map<String, dynamic>> sources(
      Map<String, dynamic> overrides, {
      List<String> arches = const <String>['x86_64'],
    }) {
      return <Map<String, dynamic>>[
        for (final String arch in arches)
          <String, dynamic>{
            'type': 'file',
            'only-arches': <String>[arch],
            'url': url,
            'sha256': sha256,
            'dest': destination(arch),
            ...overrides,
          },
      ];
    }

    void check(
      List<Map<String, dynamic>> candidates, {
      Set<String> requiredArches = const <String>{'x86_64'},
    }) {
      _expectPreFetchedNativeInput(
        sources: candidates,
        url: url,
        sha256: sha256,
        destination: destination,
        filename: filename,
        requiredArches: requiredArches,
        label: 'SQLite',
        context: 'fixture',
      );
    }

    // Control: the mapping the current build seam needs is accepted.
    check(sources(<String, dynamic>{}));

    // Correctly hashed, but staged off the FetchContent download path.
    expect(
      () => check(
        sources(<String, dynamic>{'dest': './build/linux/x64/release'}),
      ),
      throwsA(anything),
    );

    // Correctly hashed, but with no destination at all.
    expect(
      () => check(sources(<String, dynamic>{'dest': null})),
      throwsA(anything),
    );

    // Correctly hashed and staged, but only for one of the declared arches.
    expect(
      () => check(
        sources(<String, dynamic>{}),
        requiredArches: <String>{'x86_64', 'aarch64'},
      ),
      throwsA(anything),
    );
  });

  test('network grant outside runtime finish args is rejected', () {
    const String manifest = '''
finish-args:
  - --share=network
modules:
  - name: native
    build-options:
      build-args:
        - --share=network
''';

    expect(() => _expectNoBuildNetworkGrant(manifest), throwsA(anything));

    // GLib option parsing also takes a value as the following argument, so the
    // same grant can be written without either entry carrying the joined form.
    const String split = '''
finish-args:
  - --share=network
modules:
  - name: native
    build-options:
      build-args:
        - --share
        - network
''';

    expect(() => _expectNoBuildNetworkGrant(split), throwsA(anything));
    expect(
      () => _expectNoJsonNetworkGrant(<String, dynamic>{
        'build-options': <String, dynamic>{
          'build-args': <String>['--share', 'network'],
        },
      }, 'fixture'),
      throwsA(anything),
    );

    // Neither a blank line nor a comment ends a block sequence, so they cannot
    // be used to hold the two halves of the grant apart.
    expect(
      () => _expectNoBuildNetworkGrant('''
modules:
  - name: native
    build-options:
      build-args:
        - --share

        # keep the sandbox permissive
        - network
'''),
      throwsA(anything),
    );

    // A trailing comment on the value must not hide it either.
    expect(
      () => _expectNoBuildNetworkGrant('''
modules:
  - name: native
    build-options:
      build-args:
        - --share
        - network # needed for the fetch
'''),
      throwsA(anything),
    );

    // A flow sequence is the same grant in a form these checks do not read.
    expect(
      () => _expectNoBuildNetworkGrant('''
modules:
  - name: native
    build-options:
      build-args: [--share, network]
'''),
      throwsA(anything),
    );

    // Control: a split option that is not the network grant stays allowed, and
    // so does the grant in the top-level runtime finish-args.
    _expectNoBuildNetworkGrant('''
finish-args:
  - --share
  - network
modules:
  - name: native
    build-options:
      build-args:
        - --share
        - ipc
''');
    _expectNoJsonNetworkGrant(<String, dynamic>{
      'build-options': <String, dynamic>{
        'build-args': <String>['--share', 'ipc'],
      },
    }, 'fixture');
  });
}
