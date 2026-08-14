import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/contracts.dart';
import '../core/models.dart';

String monitoredPathIdentity(String path, {bool? windows}) {
  final canonical = p.canonicalize(p.absolute(path));
  return (windows ?? Platform.isWindows) ? canonical.toLowerCase() : canonical;
}

Future<SourceFingerprint?> fingerprintMonitoredFile(String path) async {
  final file = File(path);
  try {
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) return null;
    final absolute = p.absolute(path);
    return SourceFingerprint(
      identity: monitoredPathIdentity(absolute),
      path: absolute,
      sizeBytes: stat.size,
      modifiedAt: stat.modified.toUtc(),
    );
  } on FileSystemException {
    return null;
  }
}

class LocalInboxFolderMonitor implements InboxFolderMonitor {
  LocalInboxFolderMonitor({
    this.quietPeriod = const Duration(seconds: 2),
    this.eventDebounce = const Duration(milliseconds: 500),
    this.reconcileInterval = const Duration(minutes: 5),
    this.retryDelay = const Duration(seconds: 15),
  });

  final Duration quietPeriod;
  final Duration eventDebounce;
  final Duration reconcileInterval;
  final Duration retryDelay;

  InboxMonitorConfig _config = const InboxMonitorConfig();
  MonitoredFileCallback? _onCandidate;
  MonitoredFilesSnapshotCallback? _onSnapshot;
  InboxMonitorStatusCallback? _onStatus;
  StreamSubscription<FileSystemEvent>? _subscription;
  Timer? _eventTimer;
  Timer? _reconcileTimer;
  Timer? _retryTimer;
  final Map<String, Timer> _settleTimers = {};
  bool _scanInFlight = false;
  bool _scanAgain = false;
  bool _disposed = false;
  int _generation = 0;

  @override
  Future<void> start(
    InboxMonitorConfig config, {
    required MonitoredFileCallback onCandidate,
    required MonitoredFilesSnapshotCallback onSnapshot,
    required InboxMonitorStatusCallback onStatus,
  }) async {
    await stop();
    if (_disposed) return;
    _generation++;
    _config = config;
    _onCandidate = onCandidate;
    _onSnapshot = onSnapshot;
    _onStatus = onStatus;
    if (!config.isConfigured) {
      _emit(InboxMonitorStatus.unconfigured);
      return;
    }
    if (config.paused) {
      _emit(InboxMonitorStatus.paused);
      return;
    }
    await _connectAndScan(_generation);
  }

  Future<void> _connectAndScan(int generation) async {
    if (generation != _generation || _disposed || _config.paused) return;
    final directory = Directory(_config.folderPath);
    if (!await directory.exists()) {
      _emit(InboxMonitorStatus.unavailable, 'folder_unavailable');
      _scheduleRetry(generation);
      return;
    }
    _emit(InboxMonitorStatus.scanning);
    try {
      _subscription = directory
          .watch(recursive: true)
          .listen(
            (_) => _queueScan(),
            onError: (Object _) => _watchFailed(generation),
            onDone: () => _watchFailed(generation),
            cancelOnError: false,
          );
      _reconcileTimer = Timer.periodic(
        reconcileInterval,
        (_) => unawaited(scanNow()),
      );
      await scanNow();
      if (generation == _generation && !_config.paused) {
        _emit(InboxMonitorStatus.active);
      }
    } on FileSystemException {
      await _subscription?.cancel();
      _subscription = null;
      _emit(InboxMonitorStatus.unavailable, 'folder_unavailable');
      _scheduleRetry(generation);
    } on Object {
      await _subscription?.cancel();
      _subscription = null;
      _emit(InboxMonitorStatus.error, 'monitor_error');
      _scheduleRetry(generation);
    }
  }

  void _watchFailed(int generation) {
    if (generation != _generation || _disposed || _config.paused) return;
    _subscription = null;
    _reconcileTimer?.cancel();
    _emit(InboxMonitorStatus.unavailable, 'folder_unavailable');
    _scheduleRetry(generation);
  }

  void _scheduleRetry(int generation) {
    _retryTimer?.cancel();
    _retryTimer = Timer(retryDelay, () {
      if (generation != _generation || _disposed || _config.paused) return;
      unawaited(_connectAndScan(generation));
    });
  }

  void _queueScan() {
    _eventTimer?.cancel();
    _eventTimer = Timer(eventDebounce, () => unawaited(scanNow()));
  }

  @override
  Future<void> scanNow() async {
    if (_disposed || !_config.isConfigured || _config.paused) return;
    if (_scanInFlight) {
      _scanAgain = true;
      return;
    }
    _scanInFlight = true;
    final generation = _generation;
    try {
      final directory = Directory(_config.folderPath);
      if (!await directory.exists()) {
        _emit(InboxMonitorStatus.unavailable, 'folder_unavailable');
        _scheduleRetry(generation);
        return;
      }
      final identities = <String>{};
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (generation != _generation || _config.paused) return;
        if (entity is! File || !_accepts(entity.path)) continue;
        final fingerprint = await fingerprintMonitoredFile(entity.path);
        if (fingerprint != null) {
          identities.add(fingerprint.identity);
          _settle(fingerprint, generation);
        }
      }
      if (generation == _generation && !_config.paused) {
        await _onSnapshot?.call(Set.unmodifiable(identities));
      }
    } on FileSystemException {
      _emit(InboxMonitorStatus.unavailable, 'folder_unavailable');
      _scheduleRetry(generation);
    } on Object {
      _emit(InboxMonitorStatus.error, 'monitor_error');
      _scheduleRetry(generation);
    } finally {
      _scanInFlight = false;
      if (_scanAgain) {
        _scanAgain = false;
        unawaited(scanNow());
      }
    }
  }

  bool _accepts(String path) {
    final relative = p.relative(path, from: _config.folderPath);
    if (p.split(relative).any((part) => part.startsWith('.'))) return false;
    final extension = p.extension(path).toLowerCase().replaceFirst('.', '');
    return _config.extensions.contains(extension);
  }

  void _settle(SourceFingerprint fingerprint, int generation) {
    _settleTimers.remove(fingerprint.identity)?.cancel();
    _settleTimers[fingerprint.identity] = Timer(quietPeriod, () async {
      _settleTimers.remove(fingerprint.identity);
      if (generation != _generation || _disposed || _config.paused) return;
      final current = await fingerprintMonitoredFile(fingerprint.path);
      if (current == null || !_accepts(current.path)) return;
      if (!current.sameVersion(fingerprint)) {
        _settle(current, generation);
        return;
      }
      await _onCandidate?.call(current);
    });
  }

  void _emit(InboxMonitorStatus status, [String? error]) {
    _onStatus?.call(status, error);
  }

  @override
  Future<void> stop() async {
    _generation++;
    _eventTimer?.cancel();
    _eventTimer = null;
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    for (final timer in _settleTimers.values) {
      timer.cancel();
    }
    _settleTimers.clear();
    await _subscription?.cancel();
    _subscription = null;
    _scanInFlight = false;
    _scanAgain = false;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    _onCandidate = null;
    _onSnapshot = null;
    _onStatus = null;
  }
}
