import 'package:flutter/foundation.dart';

import '../core/local_speech.dart';

/// Install state and downloads of local speech models.
///
/// Download progress notifies only this controller's listeners, so screens
/// that watch the app controller do not rebuild on every progress tick.
/// [onStatusesChanged] runs after installs, deletions and integrity checks.
class LocalModelsController extends ChangeNotifier {
  LocalModelsController(this._manager, {this.onStatusesChanged});

  final LocalModelManager? _manager;
  final Future<void> Function()? onStatusesChanged;
  final Map<String, LocalModelStatus> _statuses = {};
  final Map<String, double?> _downloadProgress = {};
  final Set<String> _downloadCancelled = {};

  LocalModelStatus? status(String modelId) => _statuses[modelId];

  /// Without a model manager every model counts as installed.
  bool isReady(String modelId) =>
      _manager == null ||
      _statuses[modelId]?.availability == LocalModelAvailability.ready;

  bool isDownloading(String id) => _downloadProgress.containsKey(id);

  double? downloadProgress(String id) => _downloadProgress[id];

  LocalModelAvailability bundleAvailability(LocalModelInstallBundle bundle) {
    final states = bundle.artifacts
        .map((model) => _statuses[model.id]?.availability)
        .toList(growable: false);
    if (states.every((state) => state == LocalModelAvailability.ready)) {
      return LocalModelAvailability.ready;
    }
    if (states.any((state) => state == LocalModelAvailability.corrupt)) {
      return LocalModelAvailability.corrupt;
    }
    if (states.every(
      (state) => state == null || state == LocalModelAvailability.missing,
    )) {
      return LocalModelAvailability.missing;
    }
    return LocalModelAvailability.partial;
  }

  Future<void> refresh({bool verifyIntegrity = false}) async {
    final manager = _manager;
    if (manager == null) return;
    for (final model in manager.models) {
      _statuses[model.id] = await manager.status(
        model.id,
        verifyIntegrity: verifyIntegrity,
      );
    }
    await _statusesChanged();
  }

  Future<void> download(String modelId) async {
    final manager = _manager;
    if (manager == null || isDownloading(modelId)) return;
    _downloadProgress[modelId] = 0;
    _downloadCancelled.remove(modelId);
    notifyListeners();
    try {
      await manager.download(
        modelId,
        onProgress: (downloaded, total) {
          _downloadProgress[modelId] = total == 0 ? null : downloaded / total;
          notifyListeners();
        },
        shouldCancel: () => _downloadCancelled.contains(modelId),
      );
    } finally {
      _downloadCancelled.remove(modelId);
      _downloadProgress.remove(modelId);
      _statuses[modelId] = await manager.status(modelId);
      await _statusesChanged();
    }
  }

  Future<void> downloadBundle(LocalModelInstallBundle bundle) async {
    final manager = _manager;
    if (manager == null || isDownloading(bundle.id)) return;
    final totalBytes = bundle.sizeBytes;
    var completedBytes = 0;
    _downloadProgress[bundle.id] = 0;
    _downloadCancelled.remove(bundle.id);
    notifyListeners();
    try {
      for (final model in bundle.artifacts) {
        final existing = await manager.status(model.id, verifyIntegrity: true);
        _statuses[model.id] = existing;
        if (existing.availability == LocalModelAvailability.ready) {
          completedBytes += model.sizeBytes;
          _downloadProgress[bundle.id] = totalBytes == 0
              ? null
              : completedBytes / totalBytes;
          notifyListeners();
          continue;
        }
        await manager.download(
          model.id,
          onProgress: (downloaded, _) {
            _downloadProgress[bundle.id] = totalBytes == 0
                ? null
                : (completedBytes + downloaded) / totalBytes;
            notifyListeners();
          },
          shouldCancel: () => _downloadCancelled.contains(bundle.id),
        );
        completedBytes += model.sizeBytes;
      }
    } finally {
      _downloadCancelled.remove(bundle.id);
      _downloadProgress.remove(bundle.id);
      for (final model in bundle.artifacts) {
        _statuses[model.id] = await manager.status(model.id);
      }
      await _statusesChanged();
    }
  }

  void cancelDownload(String id) {
    if (isDownloading(id)) _downloadCancelled.add(id);
  }

  void cancelBundleDownload(LocalModelInstallBundle bundle) =>
      cancelDownload(bundle.id);

  Future<void> delete(String modelId) async {
    final manager = _manager;
    if (manager == null || isDownloading(modelId)) return;
    await manager.delete(modelId);
    _statuses[modelId] = await manager.status(modelId);
    await _statusesChanged();
  }

  Future<void> deleteBundle(LocalModelInstallBundle bundle) async {
    final manager = _manager;
    if (manager == null || isDownloading(bundle.id)) return;
    for (final model in bundle.artifacts) {
      await manager.delete(model.id);
      _statuses[model.id] = await manager.status(model.id);
    }
    await _statusesChanged();
  }

  Future<void> _statusesChanged() async {
    notifyListeners();
    await onStatusesChanged?.call();
  }
}
