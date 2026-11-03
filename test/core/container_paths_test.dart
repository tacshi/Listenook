import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/container_paths.dart';
import 'package:listenook/data/local_repositories.dart';

void main() {
  const root =
      '/var/mobile/Containers/Data/Application/'
      '11111111-2222-3333-4444-555555555555';
  const codec = ContainerPathCodec(root);

  test('container paths are stored relative and expanded on load', () {
    final json = jsonEncode({
      'source_path': '$root/Library/Application Support/media/a/talk.mp3',
      'private': '/private$root/Documents/Import/clip.mp4',
      'outside': '/Users/me/talk.mp3',
      'text': 'The file is at $root/Documents, said nobody',
    });

    final stored = codec.encode(json);
    expect(
      jsonDecode(stored)['source_path'],
      '@container/Library/Application Support/media/a/talk.mp3',
    );
    expect(
      jsonDecode(stored)['private'],
      '@container/Documents/Import/clip.mp4',
    );
    // Only whole string values that start with the container are rewritten.
    expect(jsonDecode(stored)['text'], contains(root));
    expect(jsonDecode(stored)['outside'], '/Users/me/talk.mp3');

    final loaded = jsonDecode(codec.decode(stored)) as Map;
    expect(
      loaded['source_path'],
      '$root/Library/Application Support/media/a/talk.mp3',
    );
    expect(loaded['private'], '$root/Documents/Import/clip.mp4');
  });

  test('paths saved by an earlier container move onto the current one', () {
    const old =
        '/private/var/mobile/Containers/Data/Application/'
        'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
    final loaded = jsonDecode(
      codec.decode(jsonEncode({'path': '$old/Documents/Import/a.wav'})),
    );
    expect(loaded['path'], '$root/Documents/Import/a.wav');
  });

  test('desktop paths are left alone', () {
    const none = ContainerPathCodec.none();
    const json = '{"path":"/Users/me/talk.mp3"}';
    expect(none.encode(json), json);
    expect(none.decode(json), json);
  });

  test('repositories store container-relative paths', () async {
    final directory = await Directory.systemTemp.createTemp('listenook-paths-');
    addTearDown(() => directory.delete(recursive: true));
    final container = directory.resolveSymbolicLinksSync();
    final paths = AppPaths.forTesting(
      '$container/Library/Application Support',
      pathCodec: ContainerPathCodec(container),
    );
    final repository = JsonVideoPlaybackRepository(paths);
    final media = '$container/Documents/Import/clip.mp4';
    await repository.save(
      media,
      VideoPlaybackEntry(positionMs: 1200, updatedAt: DateTime.utc(2026)),
    );
    await pendingFileWrites();

    final stored = await paths.videoPlayback.readAsString();
    expect(stored, contains('"@container/Documents/Import/clip.mp4"'));
    expect(stored, isNot(contains(container)));
    final reloaded = JsonVideoPlaybackRepository(paths);
    expect((await reloaded.load(media))?.positionMs, 1200);
  });
}
