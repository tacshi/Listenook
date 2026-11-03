import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/app_identity.dart';
import '../core/container_paths.dart';
import '../core/contracts.dart';
import 'app_data_migration.dart';
import 'migrating_secure_value.dart';
import '../core/models.dart';
import '../core/podcast_models.dart';

class AppPaths {
  AppPaths._(this.root, {this.pathCodec = const ContainerPathCodec.none()});

  factory AppPaths.forTesting(
    String rootPath, {
    ContainerPathCodec pathCodec = const ContainerPathCodec.none(),
  }) => AppPaths._(Directory(rootPath), pathCodec: pathCodec);

  final Directory root;

  /// Keeps stored paths valid when iOS moves the app container.
  final ContainerPathCodec pathCodec;

  Directory get jobs => Directory(p.join(root.path, 'jobs'));
  Directory get temporary => Directory(p.join(root.path, 'temporary'));
  Directory get models => Directory(p.join(root.path, 'models'));
  File get settings => File(p.join(root.path, 'settings.json'));
  File get libraryCatalog => File(p.join(root.path, 'library_catalog.json'));
  File get inboxMonitor => File(p.join(root.path, 'inbox_monitor.json'));
  File get podcastCatalog => File(p.join(root.path, 'podcast_catalog.json'));
  File get podcastPlayback => File(p.join(root.path, 'podcast_playback.json'));
  File get videoPlayback => File(p.join(root.path, 'video_playback.json'));
  Directory get podcasts => Directory(p.join(root.path, 'podcasts'));

  /// iOS: copies of imported media, one folder per import.
  Directory get media => Directory(p.join(root.path, 'media'));

  static Future<AppPaths> create({
    void Function(double)? onMigrationProgress,
  }) async {
    final support = await getApplicationSupportDirectory();
    // MeowSTT never shipped on iOS, so there is nothing to bring over.
    if (!Platform.isIOS) {
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
    }
    final paths = Platform.isIOS
        ? AppPaths._(
            support,
            // Application Support is <container>/Library/Application Support.
            pathCodec: ContainerPathCodec(p.dirname(p.dirname(support.path))),
          )
        : AppPaths._(support);
    await paths.root.create(recursive: true);
    await paths.jobs.create(recursive: true);
    await paths.temporary.create(recursive: true);
    await paths.models.create(recursive: true);
    await paths.podcasts.create(recursive: true);
    return paths;
  }

  Future<String> _read(File file) async =>
      pathCodec.decode(await file.readAsString());

  Future<void> _write(File file, String contents) =>
      _atomicFileWriter.write(file, pathCodec.encode(contents));
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

class JsonSettingsRepository implements SettingsRepository {
  JsonSettingsRepository(this.paths);
  final AppPaths paths;

  @override
  Future<AppSettings> load() async {
    if (!await paths.settings.exists()) return const AppSettings();
    try {
      final data = jsonDecode(await paths._read(paths.settings));
      return AppSettings.fromJson((data as Map).cast<String, dynamic>());
    } on Object {
      return const AppSettings();
    }
  }

  @override
  Future<void> save(AppSettings settings) =>
      paths._write(paths.settings, jsonEncode(settings.toJson()));
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
        final json = jsonDecode(await paths._read(file));
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
    return paths._write(
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
      final data = jsonDecode(await paths._read(paths.libraryCatalog));
      return LibraryCatalog.fromJson((data as Map).cast<String, dynamic>());
    } on Object {
      return const LibraryCatalog();
    }
  }

  @override
  Future<void> save(LibraryCatalog catalog) =>
      paths._write(paths.libraryCatalog, jsonEncode(catalog.toJson()));
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
      final data = jsonDecode(await paths._read(paths.inboxMonitor));
      return InboxMonitorStorage.fromJson(
        (data as Map).cast<String, dynamic>(),
      );
    } on Object {
      return const InboxMonitorStorage();
    }
  }

  @override
  Future<void> save(InboxMonitorStorage storage) =>
      paths._write(paths.inboxMonitor, jsonEncode(storage.toJson()));
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
      final data = jsonDecode(await paths._read(paths.podcastCatalog));
      return PodcastLibraryState.fromJson(
        (data as Map).cast<String, dynamic>(),
      );
    } on Object {
      return const PodcastLibraryState();
    }
  }

  @override
  Future<void> save(PodcastLibraryState state) =>
      paths._write(paths.podcastCatalog, jsonEncode(state.toJson()));

  @override
  Future<Map<String, PodcastListenProgress>> loadPlaybackProgress() async {
    if (!await paths.podcastPlayback.exists()) return const {};
    try {
      final data = jsonDecode(await paths._read(paths.podcastPlayback));
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
    return paths._write(
      paths.podcastPlayback,
      jsonEncode({'version': 1, 'entries': entries}),
    );
  }
}

/// Where the standalone video player left a file: its subtitle choice and
/// position. Kept apart from jobs so watching never touches the Library.
class VideoPlaybackEntry {
  const VideoPlaybackEntry({
    required this.positionMs,
    required this.updatedAt,
    this.subtitleId,
  });

  final int positionMs;
  final String? subtitleId;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'position_ms': positionMs,
    if (subtitleId case final value?) 'subtitle_id': value,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  static VideoPlaybackEntry? fromJson(Map<String, dynamic> json) {
    final updatedAt = DateTime.tryParse(json['updated_at'] as String? ?? '');
    if (updatedAt == null) return null;
    return VideoPlaybackEntry(
      positionMs: (json['position_ms'] as num?)?.toInt() ?? 0,
      subtitleId: json['subtitle_id'] as String?,
      updatedAt: updatedAt,
    );
  }
}

abstract interface class VideoPlaybackRepository {
  Future<VideoPlaybackEntry?> load(String mediaPath);

  Future<void> save(String mediaPath, VideoPlaybackEntry entry);
}

class JsonVideoPlaybackRepository implements VideoPlaybackRepository {
  JsonVideoPlaybackRepository(this.paths);

  static const maxEntries = 200;

  final AppPaths paths;
  Map<String, VideoPlaybackEntry>? _entries;

  @override
  Future<VideoPlaybackEntry?> load(String mediaPath) async =>
      (await _load())[_key(mediaPath)];

  @override
  Future<void> save(String mediaPath, VideoPlaybackEntry entry) async {
    final entries = await _load();
    entries.remove(_key(mediaPath));
    entries[_key(mediaPath)] = entry;
    while (entries.length > maxEntries) {
      entries.remove(entries.keys.first);
    }
    await paths._write(
      paths.videoPlayback,
      jsonEncode({
        'version': 1,
        'entries': [
          for (final item in entries.entries)
            {'path': item.key, ...item.value.toJson()},
        ],
      }),
    );
  }

  Future<Map<String, VideoPlaybackEntry>> _load() async {
    final cached = _entries;
    if (cached != null) return cached;
    final entries = <String, VideoPlaybackEntry>{};
    try {
      final data = jsonDecode(await paths._read(paths.videoPlayback));
      final items = data is Map ? data['entries'] : null;
      if (items is List) {
        final sorted =
            [
              for (final item in items)
                if (item is Map && item['path'] is String)
                  (
                    item['path'] as String,
                    VideoPlaybackEntry.fromJson(item.cast<String, dynamic>()),
                  ),
            ]..sort((left, right) {
              final leftTime = left.$2?.updatedAt;
              final rightTime = right.$2?.updatedAt;
              if (leftTime == null || rightTime == null) return 0;
              return leftTime.compareTo(rightTime);
            });
        for (final (path, entry) in sorted) {
          if (entry != null) entries[path] = entry;
        }
      }
    } on Object {
      // A missing or damaged file only loses resume positions.
    }
    return _entries = entries;
  }

  String _key(String mediaPath) => p.normalize(p.absolute(mediaPath));
}

final _atomicFileWriter = _AtomicFileWriter();

/// Completes once every repository file write started so far has finished.
@visibleForTesting
Future<void> pendingFileWrites() => _atomicFileWriter.idle();

class _AtomicFileWriter {
  final Map<String, Future<void>> _pendingWrites = {};
  final Map<String, _QueuedWrite> _queuedWrites = {};

  Future<void> write(File target, String contents) {
    final key = p.normalize(p.absolute(target.path));
    // A write still waiting for an earlier one to finish takes the newest
    // contents instead of queueing another full rewrite of the same file.
    final queued = _queuedWrites[key];
    if (queued != null) {
      queued.contents = contents;
      return queued.completer.future;
    }
    final next = _QueuedWrite(contents);
    final previous = _pendingWrites[key];
    if (previous != null) _queuedWrites[key] = next;
    final operation = _writeAfter(previous, key, target, next);
    _pendingWrites[key] = operation;
    operation.whenComplete(() {
      if (identical(_pendingWrites[key], operation)) {
        _pendingWrites.remove(key);
      }
    });
    return next.completer.future;
  }

  Future<void> idle() async {
    while (_pendingWrites.isNotEmpty) {
      await Future.wait(_pendingWrites.values.toList());
    }
  }

  /// Never completes with an error: the outcome goes to [next]'s completer,
  /// so a failed write does not prevent a later state from being persisted.
  Future<void> _writeAfter(
    Future<void>? previous,
    String key,
    File target,
    _QueuedWrite next,
  ) async {
    if (previous != null) await previous;
    if (identical(_queuedWrites[key], next)) _queuedWrites.remove(key);
    try {
      await target.parent.create(recursive: true);
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(next.contents, flush: true);
      // rename replaces an existing target in one step, so readers never see
      // the file missing.
      await temporary.rename(target.path);
      next.completer.complete();
    } on Object catch (error, stackTrace) {
      next.completer.completeError(error, stackTrace);
    }
  }
}

class _QueuedWrite {
  _QueuedWrite(this.contents);

  String contents;
  final completer = Completer<void>();
}
