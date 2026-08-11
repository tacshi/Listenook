import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/contracts.dart';
import '../core/models.dart';

class AppPaths {
  AppPaths._(this.root);

  factory AppPaths.forTesting(String rootPath) =>
      AppPaths._(Directory(rootPath));

  final Directory root;

  Directory get jobs => Directory(p.join(root.path, 'jobs'));
  Directory get temporary => Directory(p.join(root.path, 'temporary'));
  File get settings => File(p.join(root.path, 'settings.json'));

  static Future<AppPaths> create() async {
    final support = await getApplicationSupportDirectory();
    final paths = AppPaths._(Directory(p.join(support.path, 'MeowSTT')));
    await paths.root.create(recursive: true);
    await paths.jobs.create(recursive: true);
    await paths.temporary.create(recursive: true);
    return paths;
  }
}

class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({
    FlutterSecureStorage? storage,
    String storageKey = _defaultKey,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _storageKey = storageKey;

  static const _service = 'app.meowstt.desktop';
  static const _defaultKey = 'app.meowstt.desktop.soniox_api_key';
  static const _options = MacOsOptions(
    accountName: _service,
    accessibility: KeychainAccessibility.first_unlock,
    usesDataProtectionKeychain: false,
  );
  static const _legacyOptions = MacOsOptions(
    accessibility: KeychainAccessibility.first_unlock,
    usesDataProtectionKeychain: false,
  );
  final FlutterSecureStorage _storage;
  final String _storageKey;

  @override
  Future<String?> readApiKey() async {
    var stored = await _storage.read(key: _storageKey, mOptions: _options);
    if (Platform.isMacOS && (stored == null || stored.trim().isEmpty)) {
      final legacy = await _storage.read(
        key: _storageKey,
        mOptions: _legacyOptions,
      );
      if (legacy != null && legacy.trim().isNotEmpty) {
        stored = legacy.trim();
        await _storage.write(
          key: _storageKey,
          value: stored,
          mOptions: _options,
        );
        await _storage.delete(key: _storageKey, mOptions: _legacyOptions);
      }
    }
    if (stored != null && stored.trim().isNotEmpty) return stored.trim();
    final fallback = Platform.environment['SONIOX_API_KEY']?.trim();
    return fallback == null || fallback.isEmpty ? null : fallback;
  }

  @override
  Future<void> writeApiKey(String key) =>
      _storage.write(key: _storageKey, value: key.trim(), mOptions: _options);

  @override
  Future<void> deleteApiKey() =>
      _storage.delete(key: _storageKey, mOptions: _options);
}

class SecureTranslationCredentialStore implements TranslationCredentialStore {
  SecureTranslationCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _service = 'app.meowstt.desktop';
  static const _storageKey =
      'app.meowstt.desktop.openai_compatible_translation_api_key';
  static const _options = MacOsOptions(
    accountName: _service,
    accessibility: KeychainAccessibility.first_unlock,
    usesDataProtectionKeychain: false,
  );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readApiKey() async {
    final value = await _storage.read(key: _storageKey, mOptions: _options);
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  @override
  Future<void> writeApiKey(String key) =>
      _storage.write(key: _storageKey, value: key.trim(), mOptions: _options);

  @override
  Future<void> deleteApiKey() =>
      _storage.delete(key: _storageKey, mOptions: _options);
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
  Future<void> save(TranscriptionJob job) async {
    final directory = Directory(p.join(paths.jobs.path, _safeId(job.id)));
    await directory.create(recursive: true);
    await _atomicFileWriter.write(
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

final _atomicFileWriter = _AtomicFileWriter();

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
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }
}
