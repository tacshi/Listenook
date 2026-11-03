import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/data/managed_media_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory container;
  late Directory temporary;
  late Directory outside;
  late ManagedMediaStore store;

  setUp(() async {
    final base = (await Directory.systemTemp.createTemp(
      'listenook-managed-',
    )).resolveSymbolicLinksSync();
    container = await Directory(p.join(base, 'container')).create();
    temporary = await Directory(p.join(container.path, 'tmp')).create();
    outside = await Directory(p.join(base, 'elsewhere')).create();
    store = ManagedMediaStore(
      root: Directory(p.join(container.path, 'media')),
      containerRoot: container.path,
      temporaryRoots: [temporary.path],
    );
  });

  tearDown(() => container.parent.delete(recursive: true));

  test('picked files move in together; others are copied', () async {
    final picked = File(p.join(temporary.path, 'Inbox', 'talk.mp3'))
      ..createSync(recursive: true)
      ..writeAsStringSync('audio');
    final subtitle = File(p.join(temporary.path, 'Inbox', 'talk.srt'))
      ..writeAsStringSync('subtitle');
    final external = File(p.join(outside.path, 'clip.mp4'))
      ..writeAsStringSync('video');
    final inside = File(p.join(container.path, 'Library', 'podcasts', 'a.mp3'))
      ..createSync(recursive: true);

    final adopted = await store.adopt([
      picked.path,
      subtitle.path,
      external.path,
      inside.path,
    ]);

    expect(picked.existsSync(), isFalse);
    expect(subtitle.existsSync(), isFalse);
    expect(external.existsSync(), isTrue);
    // Files already in the container are used where they are.
    expect(adopted[3], inside.path);
    // One folder per import, so a subtitle stays next to its media.
    expect(p.dirname(adopted[0]), p.dirname(adopted[1]));
    expect(p.dirname(adopted[0]), p.dirname(adopted[2]));
    expect(p.basename(adopted[0]), 'talk.mp3');
    expect(File(adopted[0]).readAsStringSync(), 'audio');
    expect(store.owns(adopted[0]), isTrue);
    expect(store.owns(inside.path), isFalse);
  });

  test('name clashes in one import get a number', () async {
    final first = File(p.join(outside.path, 'a', 'talk.mp3'))
      ..createSync(recursive: true);
    final second = File(p.join(outside.path, 'b', 'talk.mp3'))
      ..createSync(recursive: true);
    final adopted = await store.adopt([first.path, second.path]);
    expect(adopted.map(p.basename), ['talk.mp3', 'talk (2).mp3']);
  });

  test('a received folder moves in whole', () async {
    final folder = Directory(p.join(temporary.path, 'Incoming', 'x', 'Course'))
      ..createSync(recursive: true);
    File(p.join(folder.path, 'week 1', 'a.mp3'))
      ..createSync(recursive: true)
      ..writeAsStringSync('a');

    final adopted = (await store.adopt([folder.path])).single;

    expect(folder.existsSync(), isFalse);
    expect(p.basename(adopted), 'Course');
    expect(File(p.join(adopted, 'week 1', 'a.mp3')).readAsStringSync(), 'a');
  });

  test('a released copy takes its import folder along when unused', () async {
    final media = File(p.join(outside.path, 'talk.mp3'))..createSync();
    final subtitle = File(p.join(outside.path, 'talk.srt'))..createSync();
    final other = File(p.join(outside.path, 'other.mp3'))..createSync();
    final adopted = await store.adopt([media.path, subtitle.path, other.path]);
    final folder = Directory(p.dirname(adopted[0]));

    // Another job still uses a file in the folder: only this copy goes.
    await store.release(adopted[0], inUse: (path) => path == adopted[2]);
    expect(File(adopted[0]).existsSync(), isFalse);
    expect(folder.existsSync(), isTrue);

    await store.release(adopted[2], inUse: (_) => false);
    expect(folder.existsSync(), isFalse);

    // Files outside the store are never deleted.
    await store.release(media.path);
    expect(media.existsSync(), isTrue);
  });
}
