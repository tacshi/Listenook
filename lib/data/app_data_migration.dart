import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/app_identity.dart';

class AppMigrationException implements Exception {
  const AppMigrationException(this.code);
  final String code;
  @override
  String toString() => 'AppMigrationException($code)';
}

/// Runs before any repository, worker, monitor or credential store is opened.
/// The old installation remains a recovery source; only staging is disposable.
class AppDataMigration {
  AppDataMigration({
    required this.destination,
    required this.legacyRoot,
    required this.isLegacyRunning,
    this.windows = false,
    this.onProgress,
    Future<void> Function(File source, File target)? copyFile,
  }) : _copyFile = copyFile ?? _copyVerified;

  static const markerName = '.listenook-migration.json';
  final Directory destination;
  final Directory legacyRoot;
  final Future<bool> Function() isLegacyRunning;
  final bool windows;
  final void Function(double progress)? onProgress;
  final Future<void> Function(File, File) _copyFile;

  static Directory legacyDirectory(Directory support, {required bool windows}) {
    if (windows) {
      // path_provider: RoamingAppData / CompanyName / ProductName.
      return Directory(
        p.join(
          p.dirname(p.dirname(support.path)),
          'MeowSTT',
          'MeowSTT',
          'MeowSTT',
        ),
      );
    }
    return Directory(
      p.join(p.dirname(support.path), AppIdentity.legacyBundleId, 'MeowSTT'),
    );
  }

  static Future<bool> legacyProcessIsRunning() async {
    if (Platform.isMacOS) {
      return await const MethodChannel(
            AppIdentity.startupChannel,
          ).invokeMethod<bool>('isLegacyRunning') ??
          true;
    }
    if (Platform.isWindows) {
      final result = await Process.run('tasklist', [
        '/FI',
        'IMAGENAME eq MeowSTT.exe',
        '/FO',
        'CSV',
        '/NH',
      ]);
      if (result.exitCode != 0) {
        throw const AppMigrationException('migration_check_failed');
      }
      return result.stdout.toString().toLowerCase().contains('"meowstt.exe"');
    }
    return false;
  }

  static final _pending = <String, Future<void>>{};

  Future<void> run() {
    final key = p.canonicalize(destination.path);
    return _pending.putIfAbsent(key, () async {
      RandomAccessFile? lock;
      try {
        await destination.parent.create(recursive: true);
        lock = await File(
          '${destination.path}.migration.lock',
        ).open(mode: FileMode.append);
        await lock.lock(FileLock.blockingExclusive);
        await _run();
      } on FileSystemException {
        throw const AppMigrationException('migration_copy_failed');
      } finally {
        await lock?.close();
        _pending.remove(key);
      }
    });
  }

  Future<void> _run() async {
    final marker = File(p.join(destination.path, markerName));
    if (await marker.exists()) return;
    await destination.create(recursive: true);
    // Existing Listenook data wins. An empty directory created by path_provider
    // does not count as an initialized library.
    final existing = await destination.list(followLinks: false).toList();
    if (existing.any((e) => p.basename(e.path) != '.DS_Store')) {
      await _writeMarker(destination, migrated: false);
      return;
    }
    if (!await legacyRoot.exists()) {
      await _writeMarker(destination, migrated: false);
      return;
    }
    if (await isLegacyRunning()) {
      throw const AppMigrationException('migration_legacy_running');
    }
    final staging = Directory('${destination.path}.migration-staging');
    try {
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      final sources = <File>[];
      final directories = <String>[];
      await _collect(legacyRoot, sources, directories);
      for (final relative in directories) {
        await Directory(p.join(staging.path, relative)).create(recursive: true);
      }
      final encryptedCredentials = File(
        p.join(legacyRoot.parent.path, 'flutter_secure_storage.dat'),
      );
      if (windows && await encryptedCredentials.exists()) {
        sources.add(encryptedCredentials);
      }
      final stats = <String, FileStat>{};
      var total = 0;
      for (final source in sources) {
        final stat = await source.stat();
        stats[source.path] = stat;
        total += stat.size;
      }
      var copied = 0;
      onProgress?.call(0);
      for (final source in sources) {
        final relative = source.path == encryptedCredentials.path
            ? 'flutter_secure_storage.dat'
            : p.relative(source.path, from: legacyRoot.path);
        final target = File(p.join(staging.path, relative));
        await target.parent.create(recursive: true);
        await _copyFile(source, target);
        await target.setLastModified(stats[source.path]!.modified);
        if (_isMetadata(relative)) await _rewriteMetadata(target, relative);
        copied += stats[source.path]!.size;
        onProgress?.call(total == 0 ? 1 : copied / total);
      }
      if (await isLegacyRunning()) {
        throw const AppMigrationException('migration_legacy_running');
      }
      for (final source in sources) {
        final before = stats[source.path]!;
        final after = await source.stat();
        if (before.size != after.size || before.modified != after.modified) {
          throw const AppMigrationException('migration_source_changed');
        }
      }
      await _writeMarker(staging, migrated: true);
      // Never replace a directory another process populated while we copied.
      for (final entry in await destination.list(followLinks: false).toList()) {
        if (p.basename(entry.path) == '.DS_Store' && entry is File) {
          await entry.delete();
        } else {
          throw const AppMigrationException('migration_destination_changed');
        }
      }
      await destination.delete();
      await staging.rename(destination.path);
    } on AppMigrationException {
      rethrow;
    } on Object {
      // Keep partial staging for diagnosis/retry, and never fall through to an
      // empty library or include private paths in an error shown to the user.
      throw const AppMigrationException('migration_copy_failed');
    }
  }

  Future<void> _collect(
    Directory directory,
    List<File> files,
    List<String> directories,
  ) async {
    await for (final entity in directory.list(followLinks: false)) {
      final relative = p.relative(entity.path, from: legacyRoot.path);
      final parts = p.split(relative);
      if (parts.first == 'temporary' ||
          parts.first == 'updates' ||
          parts.any(
            (part) => part.endsWith('.part') || part.endsWith('.tmp'),
          ) ||
          p.basename(relative) == '.DS_Store') {
        continue;
      }
      if (entity is Link) {
        throw const AppMigrationException('migration_link_found');
      }
      if (entity is Directory) {
        directories.add(relative);
        await _collect(entity, files, directories);
      } else if (entity is File) {
        files.add(entity);
      }
    }
  }

  bool _isMetadata(String relative) =>
      (p.dirname(relative) == '.' && relative.endsWith('.json')) ||
      (p.split(relative).first == 'jobs' &&
          p.basename(relative) == 'manifest.json');

  String _relocate(String value) {
    final context = p.Context(style: windows ? p.Style.windows : p.Style.posix);
    if (!context.isAbsolute(value)) return value;
    if (!context.equals(legacyRoot.path, value) &&
        !context.isWithin(legacyRoot.path, value)) {
      return value;
    }
    return context.normalize(
      context.join(
        destination.path,
        context.relative(value, from: legacyRoot.path),
      ),
    );
  }

  void _pathField(Map<String, dynamic> map, String key) {
    if (map[key] case final String value) map[key] = _relocate(value);
  }

  void _fingerprint(Map<String, dynamic> map) {
    _pathField(map, 'path');
    if (map['identity'] case final String identity) {
      final relocated = _relocate(identity);
      map['identity'] = windows ? relocated.toLowerCase() : relocated;
    }
  }

  Future<void> _rewriteMetadata(File file, String relative) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException {
      // Retain already-corrupt records exactly; repositories isolate these.
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    if (p.basename(relative) == 'manifest.json') {
      _pathField(decoded, 'source_path');
      if (decoded['source_fingerprint'] case final Map<String, dynamic> value) {
        _fingerprint(value);
      }
      if (decoded['imported_subtitle_provenance']
          case final Map<String, dynamic> value) {
        _pathField(value, 'source_path');
      }
    } else if (relative == 'inbox_monitor.json') {
      if (decoded['config'] case final Map<String, dynamic> config) {
        _pathField(config, 'folder_path');
      }
      if (decoded['records'] case final Map<String, dynamic> records) {
        final relocated = <String, dynamic>{};
        for (final entry in records.entries) {
          final record = entry.value;
          if (record is Map<String, dynamic> &&
              record['fingerprint'] is Map<String, dynamic>) {
            _fingerprint(record['fingerprint'] as Map<String, dynamic>);
          }
          final key = _relocate(entry.key);
          relocated[windows ? key.toLowerCase() : key] = record;
        }
        decoded['records'] = relocated;
      }
    } else {
      return;
    }
    await file.writeAsString(jsonEncode(decoded), flush: true);
  }

  static Future<void> _copyVerified(File source, File target) async {
    await source.copy(target.path);
    final original = await sha256.bind(source.openRead()).first;
    final copied = await sha256.bind(target.openRead()).first;
    if (original != copied) {
      throw const AppMigrationException('migration_copy_failed');
    }
  }

  static Future<void> _writeMarker(
    Directory root, {
    required bool migrated,
  }) async {
    final target = File(p.join(root.path, markerName));
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'data_version': 1,
        'migrated': migrated,
        'legacy_login_notice_dismissed': !migrated,
      }),
      flush: true,
    );
    await temporary.rename(target.path);
  }
}
