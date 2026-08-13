import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/data/local_media_source_resolver.dart';
import 'package:path/path.dart' as p;

void main() {
  test('folder imports resolve recursively and exclude hidden paths', () async {
    final root = await Directory.systemTemp.createTemp('meow-source-resolver-');
    addTearDown(() => root.delete(recursive: true));
    final nested = await Directory(p.join(root.path, 'nested')).create();
    final hiddenDirectory = await Directory(
      p.join(root.path, '.hidden'),
    ).create();
    final first = File(p.join(root.path, 'first.wav'));
    final second = File(p.join(nested.path, 'second.mp4'));
    final hiddenFile = File(p.join(root.path, '.ignored.wav'));
    final hiddenNested = File(p.join(hiddenDirectory.path, 'ignored.mp3'));
    await first.writeAsBytes(const [1]);
    await second.writeAsBytes(const [2]);
    await hiddenFile.writeAsBytes(const [3]);
    await hiddenNested.writeAsBytes(const [4]);
    const resolver = LocalMediaSourceResolver();

    final resolved = await resolver.resolve([root.path]);

    expect(resolved.map((source) => source.path), {
      p.absolute(first.path),
      p.absolute(second.path),
    });
    expect(resolved.map((source) => source.identity).toSet(), hasLength(2));
  });

  test('equivalent file paths receive the same canonical identity', () async {
    final root = await Directory.systemTemp.createTemp('meow-source-identity-');
    addTearDown(() => root.delete(recursive: true));
    final file = File(p.join(root.path, 'sample.wav'));
    await file.writeAsBytes(const [1]);
    const resolver = LocalMediaSourceResolver();

    final resolved = await resolver.resolve([
      file.path,
      p.join(root.path, '.', 'sample.wav'),
    ]);

    expect(resolved, hasLength(2));
    expect(resolved.first.identity, resolved.last.identity);
  });
}
