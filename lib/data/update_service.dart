import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/update_models.dart';
import '../core/app_identity.dart';
import 'update_installer.dart';

enum UpdatePhase {
  idle,
  checking,
  upToDate,
  downloading,
  verifying,
  readyToRestart,
  installing,
  failed,
}

class UpdateService extends ChangeNotifier {
  UpdateService({
    http.Client? client,
    UpdateInstaller? installer,
    Uri? manifestUri,
    Future<AppVersion?> Function()? readCurrentVersion,
    Future<Directory> Function()? updatesDirectory,
    String? platformKey,
    bool? automaticEnabled,
    this.initialDelay = const Duration(seconds: 8),
    this.checkInterval = const Duration(hours: 6),
    this.retryInterval = const Duration(minutes: 15),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _installer = installer ?? UpdateInstaller.forCurrentPlatform(),
       _manifestUri = manifestUri ?? Uri.parse(defaultManifestUrl),
       _readCurrentVersion = readCurrentVersion ?? _packageVersion,
       _updatesDirectory = updatesDirectory ?? _defaultUpdatesDirectory,
       _platformKey = platformKey ?? currentUpdatePlatformKey,
       _automaticEnabled = automaticEnabled ?? kReleaseMode;

  static const releaseRepoUrl = 'https://github.com/${AppIdentity.releaseRepository}';
  static const defaultManifestUrl =
      'https://raw.githubusercontent.com/${AppIdentity.releaseRepository}/main/${AppIdentity.manifestName}';

  final http.Client _client;
  final bool _ownsClient;
  final UpdateInstaller _installer;
  final Uri _manifestUri;
  final Future<AppVersion?> Function() _readCurrentVersion;
  final Future<Directory> Function() _updatesDirectory;
  final String? _platformKey;
  final bool _automaticEnabled;
  final Duration initialDelay;
  final Duration checkInterval;
  final Duration retryInterval;

  UpdatePhase _phase = UpdatePhase.idle;
  AppVersion? _currentVersion;
  AppRelease? _release;
  File? _downloadedFile;
  Object? _error;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  bool _initialized = false;
  bool _started = false;
  bool _shutdown = false;
  Timer? _timer;
  Future<void>? _activeOperation;
  Duration? _scheduledDelay;

  UpdatePhase get phase => _phase;
  AppVersion? get currentVersion => _currentVersion;
  AppRelease? get release => _release;
  Object? get error => _error;
  int get receivedBytes => _receivedBytes;
  int get totalBytes => _totalBytes;
  bool get readyToRestart =>
      _downloadedFile != null &&
      (_phase == UpdatePhase.readyToRestart ||
          _phase == UpdatePhase.installing);
  bool get supported => _platformKey != null;
  double? get progress => _totalBytes <= 0
      ? null
      : (_receivedBytes / _totalBytes).clamp(0, 1).toDouble();

  @visibleForTesting
  Duration? get scheduledDelay => _scheduledDelay;

  Future<void> initialize() async {
    if (_initialized) return;
    _currentVersion = await _readCurrentVersion();
    await _purgePartialDownloads();
    _initialized = true;
    notifyListeners();
  }

  Future<void> start() async {
    await initialize();
    if (_shutdown || _started || !_automaticEnabled || _platformKey == null) {
      return;
    }
    _started = true;
    _schedule(initialDelay);
  }

  void _schedule(Duration delay) {
    if (_shutdown) return;
    _timer?.cancel();
    _scheduledDelay = delay;
    _timer = Timer(delay, () => unawaited(_runScheduledCheck()));
  }

  Future<void> _runScheduledCheck() async {
    var succeeded = false;
    try {
      await checkAndDownloadNow();
      succeeded = true;
    } on Object catch (error) {
      debugPrint('UpdateService: automatic update failed ($error)');
    }
    if (!_started || readyToRestart) return;
    _schedule(succeeded ? checkInterval : retryInterval);
  }

  Future<void> checkAndDownloadNow() {
    if (_shutdown) return Future.value();
    final active = _activeOperation;
    if (active != null) return active;
    final operation = _checkAndDownload();
    _activeOperation = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_activeOperation, operation)) _activeOperation = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_activeOperation, operation)) _activeOperation = null;
        },
      ),
    );
    return operation;
  }

  Future<void> _checkAndDownload() async {
    await initialize();
    final current = _currentVersion;
    final platformKey = _platformKey;
    if (current == null || platformKey == null) return;
    _error = null;
    _phase = UpdatePhase.checking;
    notifyListeners();
    try {
      final manifest = await _fetchManifest();
      final release = manifest.forPlatform(platformKey);
      if (release == null || release.version <= current) {
        await _purgeDownloadedPackages();
        _release = null;
        _downloadedFile = null;
        _phase = UpdatePhase.upToDate;
        notifyListeners();
        return;
      }
      _release = release;
      final directory = await _updatesDirectory();
      if (!await directory.exists()) await directory.create(recursive: true);
      final target = File(p.join(directory.path, release.asset.fileName));
      await _purgeDownloadedPackages(keepFileName: release.asset.fileName);
      if (await target.exists()) {
        _phase = UpdatePhase.verifying;
        notifyListeners();
        if (await _isValid(target, release.asset, deleteInvalid: true)) {
          _downloadedFile = target;
          _receivedBytes = release.asset.size;
          _totalBytes = release.asset.size;
          _phase = UpdatePhase.readyToRestart;
          notifyListeners();
          return;
        }
      }
      final file = await _download(release.asset, target);
      _phase = UpdatePhase.verifying;
      notifyListeners();
      if (!await _isValid(file, release.asset, deleteInvalid: true)) {
        throw const UpdateInstallException(
          'The downloaded update failed verification.',
        );
      }
      _downloadedFile = file;
      _phase = UpdatePhase.readyToRestart;
      notifyListeners();
    } on Object catch (error) {
      _error = error;
      _phase = UpdatePhase.failed;
      notifyListeners();
      rethrow;
    }
  }

  Future<UpdateManifest> _fetchManifest() async {
    final bucket = DateTime.now().millisecondsSinceEpoch ~/ 300000;
    final uri = _manifestUri.replace(
      queryParameters: {..._manifestUri.queryParameters, '_': '$bucket'},
    );
    late http.Response response;
    try {
      response = await _client.get(uri).timeout(const Duration(seconds: 20));
    } on Object catch (error) {
      throw UpdateManifestException(
        'Could not reach the update server: $error',
      );
    }
    if (response.statusCode != HttpStatus.ok) {
      throw UpdateManifestException(
        'The update server returned HTTP ${response.statusCode}.',
      );
    }
    try {
      return UpdateManifest.parse(jsonDecode(response.body));
    } on FormatException {
      throw const UpdateManifestException('The update manifest is not JSON.');
    }
  }

  Future<File> _download(UpdateAsset asset, File target) async {
    final partial = File('${target.path}.part');
    if (await partial.exists()) await partial.delete();
    _phase = UpdatePhase.downloading;
    _receivedBytes = 0;
    _totalBytes = asset.size;
    notifyListeners();
    IOSink? sink;
    try {
      final request = http.Request('GET', asset.url);
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw UpdateInstallException(
          'The update download returned HTTP ${response.statusCode}.',
        );
      }
      sink = partial.openWrite();
      await for (final chunk in response.stream) {
        sink.add(chunk);
        _receivedBytes += chunk.length;
        notifyListeners();
      }
      await sink.close();
      sink = null;
      if (await target.exists()) await target.delete();
      return await partial.rename(target.path);
    } on Object catch (error) {
      await sink?.close();
      if (await partial.exists()) await partial.delete();
      if (error is UpdateInstallException) {
        rethrow;
      }
      throw UpdateInstallException('Could not download the update: $error');
    }
  }

  Future<bool> _isValid(
    File file,
    UpdateAsset asset, {
    required bool deleteInvalid,
  }) async {
    var valid = await file.length() == asset.size;
    if (valid) {
      final digest = await sha256.bind(file.openRead()).first;
      valid = digest.toString() == asset.sha256;
    }
    if (!valid && deleteInvalid && await file.exists()) await file.delete();
    return valid;
  }

  Future<void> installReadyUpdate() async {
    final file = _downloadedFile;
    final asset = _release?.asset;
    if (file == null || asset == null || _phase == UpdatePhase.installing) {
      return;
    }
    _error = null;
    _phase = UpdatePhase.installing;
    notifyListeners();
    try {
      await _installer.launch(file, asset);
    } on Object catch (error) {
      _error = error;
      _phase = UpdatePhase.readyToRestart;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _purgePartialDownloads() async {
    try {
      final directory = await _updatesDirectory();
      if (!await directory.exists()) return;
      await for (final entry in directory.list()) {
        if (entry is File && entry.path.endsWith('.part')) await entry.delete();
      }
    } on Object catch (error) {
      debugPrint('UpdateService: could not clean update cache ($error)');
    }
  }

  Future<void> _purgeDownloadedPackages({String? keepFileName}) async {
    try {
      final directory = await _updatesDirectory();
      if (!await directory.exists()) return;
      await for (final entry in directory.list()) {
        if (entry is File) {
          final name = p.basename(entry.path);
          final isPackage = name.endsWith('.zip') || name.endsWith('.exe');
          if (isPackage && name != keepFileName) await entry.delete();
          if (keepFileName == null && name == 'install-update.sh') {
            await entry.delete();
          }
        } else if (keepFileName == null &&
            entry is Directory &&
            p.basename(entry.path) == 'staging') {
          await entry.delete(recursive: true);
        }
      }
    } on Object catch (error) {
      debugPrint('UpdateService: could not purge old updates ($error)');
    }
  }

  static Future<Directory> _defaultUpdatesDirectory() async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'updates'),
  );

  static Future<AppVersion?> _packageVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return AppVersion.tryParse(
        info.version,
        build: int.tryParse(info.buildNumber) ?? 0,
      );
    } on Object catch (error) {
      debugPrint('UpdateService: could not read app version ($error)');
      return null;
    }
  }

  /// Stops release-only background work before the desktop engine is torn
  /// down. This service is supplied through Provider.value, so the widget tree
  /// does not dispose it automatically.
  void shutdown() {
    if (_shutdown) return;
    _shutdown = true;
    _started = false;
    _timer?.cancel();
    _timer = null;
    _scheduledDelay = null;
    if (_ownsClient) _client.close();
  }

  @override
  void dispose() {
    shutdown();
    super.dispose();
  }
}
