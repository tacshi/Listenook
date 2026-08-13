import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/contracts.dart';

class LocalMediaSourceResolver implements MediaSourceResolver {
  const LocalMediaSourceResolver();

  @override
  Future<List<ResolvedMediaSource>> resolve(Iterable<String> inputs) async {
    final resolved = <ResolvedMediaSource>[];
    for (final input in inputs) {
      await _collect(input, resolved);
    }
    return resolved;
  }

  Future<void> _collect(
    String input,
    List<ResolvedMediaSource> resolved,
  ) async {
    final type = await FileSystemEntity.type(input, followLinks: false);
    if (type == FileSystemEntityType.file) {
      if (!_isHidden(input)) resolved.add(_resolve(input));
      return;
    }
    if (type != FileSystemEntityType.directory) return;
    await for (final entity in Directory(
      input,
    ).list(recursive: true, followLinks: false)) {
      if (entity is File && !_isHidden(entity.path)) {
        resolved.add(_resolve(entity.path));
      }
    }
  }

  ResolvedMediaSource _resolve(String path) {
    final absolute = p.absolute(path);
    return ResolvedMediaSource(path: absolute, identity: identityFor(absolute));
  }

  @override
  String identityFor(String path) {
    final canonical = p.canonicalize(p.absolute(path));
    return Platform.isWindows ? canonical.toLowerCase() : canonical;
  }

  bool _isHidden(String path) => p
      .split(p.normalize(path))
      .any((part) => part.startsWith('.') && part != '.' && part != '..');
}
