import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:listenook/core/app_identity.dart';

const releaseRepository = AppIdentity.releaseRepository;

Future<void> main(List<String> arguments) async {
  final options = _parseOptions(arguments);
  final version = options['version'];
  final buildText = options['build'];
  final build = int.tryParse(buildText ?? '');
  if (version == null || build == null) {
    stderr.writeln(
      'usage: dart run tool/make_update_manifest.dart '
      '--version x.y.z --build n --dir artifacts [--previous latest.json] '
      '--out latest.json',
    );
    exitCode = 64;
    return;
  }
  final directory = Directory(options['dir'] ?? 'dist/release');
  if (!directory.existsSync()) {
    stderr.writeln('artifact directory not found: ${directory.path}');
    exitCode = 66;
    return;
  }
  final previous = _readPrevious(options['previous']);
  final manifest = await buildUpdateManifest(
    version: version,
    build: build,
    artifactDirectory: directory,
    previousManifest: previous,
  );
  final encoded = '${const JsonEncoder.withIndent('  ').convert(manifest)}\n';
  final output = options['out'];
  if (output == null) {
    stdout.write(encoded);
  } else {
    final file = File(output);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(encoded);
    stdout.writeln('wrote ${file.path}');
  }
}

Future<Map<String, Object?>> buildUpdateManifest({
  required String version,
  required int build,
  required Directory artifactDirectory,
  Object? previousManifest,
  DateTime? releasedAt,
}) async {
  final releasedAtText = (releasedAt ?? DateTime.now())
      .toUtc()
      .toIso8601String();
  final notesUrl =
      'https://github.com/$releaseRepository/releases/tag/v$version';
  final metadata = <String, Object?>{
    'version': version,
    'build': build,
    'releasedAt': releasedAtText,
    'notesUrl': notesUrl,
  };
  final platforms = _previousPlatforms(previousManifest)
    ..removeWhere(
      (_, value) =>
          value is! Map ||
          !(value['fileName'] is String &&
              (value['fileName'] as String).startsWith('Listenook-')),
    );
  for (final target in updateTargets) {
    final artifact = _findArtifact(artifactDirectory, target.fileSuffix);
    if (artifact == null) {
      stderr.writeln(
        'note: no ${target.platformKey} artifact; retaining its previous entry',
      );
      continue;
    }
    final digest = await sha256.bind(artifact.openRead()).first;
    platforms[target.platformKey] = <String, Object?>{
      ...metadata,
      'kind': target.installKind,
      'fileName': p.basename(artifact.path),
      'size': await artifact.length(),
      'sha256': digest.toString(),
      'url':
          'https://github.com/$releaseRepository/releases/download/v$version/'
          '${Uri.encodeComponent(p.basename(artifact.path))}',
      if (target.silentArgs != null) 'silentArgs': target.silentArgs,
      if (target.minOsVersion != null) 'minOsVersion': target.minOsVersion,
    };
  }
  return <String, Object?>{'schema': 1, ...metadata, 'platforms': platforms};
}

class UpdateTarget {
  const UpdateTarget(
    this.platformKey,
    this.fileSuffix,
    this.installKind, {
    this.silentArgs,
    this.minOsVersion,
  });

  final String platformKey;
  final String fileSuffix;
  final String installKind;
  final List<String>? silentArgs;
  final String? minOsVersion;
}

const updateTargets = <UpdateTarget>[
  UpdateTarget(
    'macos-arm64',
    '-macos-arm64-release.zip',
    'appZip',
    minOsVersion: '12.0',
  ),
  UpdateTarget(
    'macos-x64',
    '-macos-x64-release.zip',
    'appZip',
    minOsVersion: '12.0',
  ),
  UpdateTarget(
    'windows-x64',
    '-windows-x64-release-setup.exe',
    'innoSetup',
    silentArgs: <String>[
      '/SILENT',
      '/NOCANCEL',
      '/NORESTART',
      '/CLOSEAPPLICATIONS',
      '/relaunch=1',
    ],
  ),
];

File? _findArtifact(Directory directory, String suffix) {
  final matches = directory
      .listSync()
      .whereType<File>()
      .where(
        (file) =>
            p.basename(file.path).startsWith('Listenook-') &&
            p.basename(file.path).endsWith(suffix),
      )
      .toList();
  if (matches.length > 1) {
    throw StateError(
      'multiple artifacts match $suffix: '
      '${matches.map((file) => p.basename(file.path)).join(', ')}',
    );
  }
  return matches.singleOrNull;
}

Object? _readPrevious(String? path) {
  if (path == null) return null;
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('previous manifest not found: $path');
  }
  return jsonDecode(file.readAsStringSync());
}

Map<String, Object?> _previousPlatforms(Object? previous) {
  if (previous == null) return <String, Object?>{};
  if (previous is! Map || previous['platforms'] is! Map) {
    throw ArgumentError.value(previous, 'previousManifest');
  }
  return <String, Object?>{
    for (final entry in (previous['platforms'] as Map).entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

Map<String, String> _parseOptions(List<String> arguments) {
  final options = <String, String>{};
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (!argument.startsWith('--')) continue;
    final separator = argument.indexOf('=');
    if (separator > 2) {
      options[argument.substring(2, separator)] = argument.substring(
        separator + 1,
      );
    } else if (index + 1 < arguments.length) {
      options[argument.substring(2)] = arguments[++index];
    }
  }
  return options;
}
