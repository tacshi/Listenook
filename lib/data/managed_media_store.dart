import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Keeps Listenook's own copies of files brought in from outside the app
/// container (iOS). The document picker hands over temporary copies that
/// the system may purge, and files opened from other apps are only readable
/// for a moment, so jobs refer to these copies instead.
///
/// Each import gets its own folder, so media and the subtitles picked with
/// it stay side by side and sidecar subtitle matching keeps working.
class ManagedMediaStore {
  ManagedMediaStore({
    required this.root,
    required this.containerRoot,
    required this.temporaryRoots,
  });

  /// Where the copies live: `<Application Support>/media`.
  final Directory root;

  /// Files already inside the container (downloaded podcasts) are used
  /// where they are.
  final String containerRoot;

  /// Temporary folders whose files are moved rather than copied.
  final List<String> temporaryRoots;

  static const _uuid = Uuid();

  /// Returns where each of [paths] can be used from now on.
  Future<List<String>> adopt(Iterable<String> paths) async {
    Directory? batch;
    final adopted = <String>[];
    for (final path in paths) {
      final source = p.normalize(p.absolute(path));
      if (_inside(source, containerRoot) && !_isTemporary(source)) {
        adopted.add(source);
        continue;
      }
      batch ??= await Directory(
        p.join(root.path, _uuid.v4()),
      ).create(recursive: true);
      adopted.add(await _bring(source, batch));
    }
    return adopted;
  }

  /// Whether [path] is one of the copies, which leave with their last job.
  bool owns(String path) => _inside(p.normalize(p.absolute(path)), root.path);

  /// Deletes the copy at [path], and its import folder once nothing in it
  /// is still [inUse] (the subtitles picked with the media go with it).
  Future<void> release(String path, {bool Function(String)? inUse}) async {
    if (!owns(path)) return;
    final file = File(path);
    try {
      if (await file.exists()) await file.delete();
      var folder = file.parent;
      while (p.isWithin(root.path, folder.path) &&
          p.dirname(folder.path) != root.path) {
        folder = folder.parent;
      }
      if (!p.isWithin(root.path, folder.path) || !await folder.exists()) {
        return;
      }
      final remaining = await folder
          .list(recursive: true)
          .where((entity) => entity is File)
          .map((entity) => entity.path)
          .toList();
      if (remaining.any((item) => inUse?.call(item) ?? false)) return;
      await folder.delete(recursive: true);
    } on FileSystemException {
      // Best effort: the job record is going away regardless.
    }
  }

  bool _isTemporary(String path) =>
      temporaryRoots.any((root) => _inside(path, root));

  static bool _inside(String path, String root) {
    final normalized = p.normalize(p.absolute(root));
    return path == normalized || p.isWithin(normalized, path);
  }

  Future<String> _bring(String source, Directory batch) async {
    final type = await FileSystemEntity.type(source);
    final target = await _freeName(batch, p.basename(source));
    final move = _isTemporary(source);
    if (type == FileSystemEntityType.directory) {
      await _copyDirectory(Directory(source), Directory(target));
      if (move) await Directory(source).delete(recursive: true);
      return target;
    }
    if (move) {
      try {
        return (await File(source).rename(target)).path;
      } on FileSystemException {
        // Another volume: fall back to copying.
      }
    }
    await File(source).copy(target);
    if (move) await File(source).delete();
    return target;
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final destination = p.join(target.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(destination));
      } else if (entity is File) {
        await entity.copy(destination);
      }
    }
  }

  Future<String> _freeName(Directory folder, String name) async {
    final stem = p.basenameWithoutExtension(name);
    final extension = p.extension(name);
    var candidate = p.join(folder.path, name);
    for (var index = 2; await _exists(candidate); index++) {
      candidate = p.join(folder.path, '$stem ($index)$extension');
    }
    return candidate;
  }

  static Future<bool> _exists(String path) async =>
      await FileSystemEntity.type(path) != FileSystemEntityType.notFound;
}
