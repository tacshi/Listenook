import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/app_identity.dart';
import '../core/contracts.dart';
import 'app_data_migration.dart';
import 'migrating_secure_value.dart';
import '../core/models.dart';
import '../core/podcast_models.dart';

class AppPaths {
  AppPaths._(this.root);

  factory AppPaths.forTesting(String rootPath) =>
      AppPaths._(Directory(rootPath));

  final Directory root;

  Directory get jobs => Directory(p.join(root.path, 'jobs'));
  Directory get temporary => Directory(p.join(root.path, 'temporary'));
  Directory get models => Directory(p.join(root.path, 'models'));
  File get settings => File(p.join(root.path, 'settings.json'));
  File get libraryCatalog => File(p.join(root.path, 'library_catalog.json'));
  File get inboxMonitor => File(p.join(root.path, 'inbox_monitor.json'));
  File get podcastCatalog => File(p.join(root.path, 'podcast_catalog.json'));
  File get podcastPlayback => File(p.join(root.path, 'podcast_playback.json'));
  Directory get podcasts => Directory(p.join(root.path, 'podcasts'));

  static Future<AppPaths> create({
    void Function(double)? onMigrationProgress,
  }) async {
    final support = await getApplicationSupportDirectory();
    await AppDataMigration(
      destination: support,
      legacyRoot: AppDataMigration.legacyDirectory(
        support,
        windows: Platform.isWindows,
      ),
      isLegacyRunning: AppDataMigration.legacyProcessIsRunning,
      windows: Platform.isWindows,
      onProgress: onMigrationProgress,
    ).run();
    final paths = AppPaths._(support);
    await paths.root.create(recursive: true);
    await paths.jobs.create(recursive: true);
    await paths.temporary.create(recursive: true);
    await paths.models.create(recursive: true);
    await paths.podcasts.create(recursive: true);
    return paths;
  }
}

class SecureCredentialStore
    implements CredentialStore, CredentialAvailabilityStore {
  SecureCredentialStore({
    FlutterSecureStorage? storage,
    String storageKey = '${AppIdentity.bundleId}.soniox_api_key',
    String environmentVariable = 'SONIOX_API_KEY',
  }) : _value = MigratingSecureValue(
         storage: storage ?? const FlutterSecureStorage(),
         key: storageKey,
       ),
       _environmentVariable = environmentVariable;

  final MigratingSecureValue _value;
  final String _environmentVariable;

  Future<void> migrateLegacy() => _value.migrate();

  @override
  Future<bool> hasApiKey() async =>
      await _value.contains() ||
      (Platform.environment[_environmentVariable]?.trim().isNotEmpty ?? false);

  @override
  Future<String?> readApiKey() async {
    final stored = await _value.read();
    if (stored != null) return stored;
    final fallback = Platform.environment[_environmentVariable]?.trim();
    return fallback == null || fallback.isEmpty ? null : fallback;
  }

  @override
  Future<void> writeApiKey(String key) => _value.write(key);

  @override
  Future<void> deleteApiKey() => _value.delete();
}

class SecureLlmCredentialStore
    implements TranslationCredentialStore, CredentialAvailabilityStore {
  SecureLlmCredentialStore({FlutterSecureStorage? storage})
    : _value = MigratingSecureValue(
        storage: storage ?? const FlutterSecureStorage(),
        key: '${AppIdentity.bundleId}.openai_compatible_translation_api_key',
      );

  final MigratingSecureValue _value;
  Future<void> migrateLegacy() => _value.migrate();

  @override
  Future<bool> hasApiKey() => _value.contains();

  @override
  Future<String?> readApiKey() => _value.read();

  @override
  Future<void> writeApiKey(String key) => _value.write(key);

  @override
  Future<void> deleteApiKey() => _value.delete();
}

@Deprecated('Use SecureLlmCredentialStore.')
class SecureTranslationCredentialStore extends SecureLlmCredentialStore {
  SecureTranslationCredentialStore({super.storage});
}

class JsonSettingsRepository implements SettingsRepository {
  JsonSettingsRepository(this.paths);
  final AppPaths paths;

  @override
  Future<AppSettings> load() async {
    if (!await paths.settings.exists()) return const AppSettings();
    try {
      final data = jsonDecode(await paths.settings.readAsString());
      return AppSettings.fromJson((data as Map).cast<String, dynamic>());
    } on Object {
      return const AppSettings();
    }
  }

  @override
  Future<void> save(AppSettings settings) =>
      _atomicFileWriter.write(paths.settings, jsonEncode(settings.toJson()));
}

class LocalJobRepository implements JobRepository {
  LocalJobRepository(this.paths);
  final AppPaths paths;

  @override
  Future<List<TranscriptionJob>> loadAll() async {
    final result = <TranscriptionJob>[];
    if (!await paths.jobs.exists()) return result;
    await for (final entity in paths.jobs.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final file = File(p.join(entity.path, 'manifest.json'));
      if (!await file.exists()) continue;
      try {
        final json = jsonDecode(await file.readAsString());
        result.add(
          TranscriptionJob.fromJson((json as Map).cast<String, dynamic>()),
        );
      } on Object {
        // A corrupt manifest is isolated to its job directory. Keep loading the
        // remainder of the library and leave the file available for recovery.
      }
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  @override
  Future<void> save(TranscriptionJob job) {
    final directory = Directory(p.join(paths.jobs.path, _safeId(job.id)));
    return _atomicFileWriter.write(
      File(p.join(directory.path, 'manifest.json')),
      job.toJsonString(),
    );
  }

  @override
  Future<void> delete(String id) async {
    final directory = Directory(p.join(paths.jobs.path, _safeId(id)));
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  String _safeId(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
      throw ArgumentError.value(value, 'id', 'Invalid job identifier');
    }
    return value;
  }
}

class JsonLibraryCatalogRepository implements LibraryCatalogRepository {
  JsonLibraryCatalogRepository(this.paths);

  final AppPaths paths;

  @override
  Future<LibraryCatalog> load() async {
    if (!await paths.libraryCatalog.exists()) return const LibraryCatalog();
    try {
      final data = jsonDecode(await paths.libraryCatalog.readAsString());
      return LibraryCatalog.fromJson((data as Map).cast<String, dynamic>());
    } on Object {
      return const LibraryCatalog();
    }
  }

  @override
  Future<void> save(LibraryCatalog catalog) => _atomicFileWriter.write(
    paths.libraryCatalog,
    jsonEncode(catalog.toJson()),
  );
}

class JsonInboxMonitorRepository implements InboxMonitorRepository {
  JsonInboxMonitorRepository(this.paths);

  final AppPaths paths;

  @override
  Future<InboxMonitorStorage> load() async {
    if (!await paths.inboxMonitor.exists()) {
      return const InboxMonitorStorage();
    }
    try {
      final data = jsonDecode(await paths.inboxMonitor.readAsString());
      return InboxMonitorStorage.fromJson(
        (data as Map).cast<String, dynamic>(),
      );
    } on Object {
      return const InboxMonitorStorage();
    }
  }

  @override
  Future<void> save(InboxMonitorStorage storage) =>
      _atomicFileWriter.write(paths.inboxMonitor, jsonEncode(storage.toJson()));
}

class JsonPodcastRepository implements PodcastRepository {
  JsonPodcastRepository(this.paths);

  final AppPaths paths;

  @override
  Future<PodcastLibraryState> load() async {
    if (!await paths.podcastCatalog.exists()) {
      return const PodcastLibraryState();
    }
    try {
      final data = jsonDecode(await paths.podcastCatalog.readAsString());
      return PodcastLibraryState.fromJson(
        (data as Map).cast<String, dynamic>(),
      );
    } on Object {
      return const PodcastLibraryState();
    }
  }

  @override
  Future<void> save(PodcastLibraryState state) =>
      _atomicFileWriter.write(paths.podcastCatalog, jsonEncode(state.toJson()));

  @override
  Future<Map<String, PodcastListenProgress>> loadPlaybackProgress() async {
    if (!await paths.podcastPlayback.exists()) return const {};
    try {
      final data = jsonDecode(await paths.podcastPlayback.readAsString());
      if (data is! Map) return const {};
      final entries = data['entries'];
      if (entries is! List) return const {};
      return {
        for (final item in entries)
          if (item is Map)
            if (item['episode_id'] is String &&
                (item['episode_id'] as String).isNotEmpty)
              item['episode_id'] as String: PodcastListenProgress.fromJson(
                item.cast<String, dynamic>(),
              ),
      };
    } on Object {
      return const {};
    }
  }

  @override
  Future<void> savePlaybackProgress(
    Map<String, PodcastListenProgress> progress,
  ) {
    final entries = [
      for (final entry in progress.entries)
        {'episode_id': entry.key, ...entry.value.toJson()},
    ];
    return _atomicFileWriter.write(
      paths.podcastPlayback,
      jsonEncode({'version': 1, 'entries': entries}),
    );
  }
}

final _atomicFileWriter = _AtomicFileWriter();

/// Completes once every repository file write started so far has finished.
@visibleForTesting
Future<void> pendingFileWrites() => _atomicFileWriter.idle();

class _AtomicFileWriter {
  final Map<String, Future<void>> _pendingWrites = {};

  Future<void> write(File target, String contents) {
    final key = p.normalize(p.absolute(target.path));
    final operation = _writeAfter(_pendingWrites[key], target, contents);
    _pendingWrites[key] = operation;
    return operation.whenComplete(() {
      if (identical(_pendingWrites[key], operation)) {
        _pendingWrites.remove(key);
      }
    });
  }

  Future<void> idle() async {
    while (_pendingWrites.isNotEmpty) {
      try {
        await Future.wait(_pendingWrites.values.toList());
      } on Object {
        // Callers of write() own its errors.
      }
    }
  }

  Future<void> _writeAfter(
    Future<void>? previous,
    File target,
    String contents,
  ) async {
    if (previous != null) {
      try {
        await previous;
      } on Object {
        // A failed write must not prevent a later state from being persisted.
      }
    }
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(contents, flush: true);
    // rename replaces an existing target in one step, so readers never see
    // the file missing.
    await temporary.rename(target.path);
  }
}
