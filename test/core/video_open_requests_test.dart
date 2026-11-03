import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/data/local_repositories.dart';
import 'package:listenook/state/video_open_requests.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('listenook-open-');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('keeps only existing videos and plays the latest request', () {
    final first = File('${directory.path}/first.mkv')..writeAsStringSync('');
    final second = File('${directory.path}/Second.MP4')..writeAsStringSync('');
    File('${directory.path}/notes.srt').writeAsStringSync('');
    final requests = VideoOpenRequests();
    var notifications = 0;
    requests.addListener(() => notifications++);

    requests.addAll([
      '--background',
      '${directory.path}/notes.srt',
      '${directory.path}/missing.mp4',
    ]);
    expect(requests.hasPending, isFalse);
    expect(notifications, 0);

    requests.addAll([first.path, second.path]);
    expect(notifications, 1);
    expect(requests.takeLatest(), second.path);
    expect(requests.takeLatest(), isNull);
  });

  test('iOS queues audio, subtitles and folders for the Inbox', () {
    final audio = File('${directory.path}/talk.m4a')..writeAsStringSync('');
    final subtitle = File('${directory.path}/talk.srt')..writeAsStringSync('');
    final folder = Directory('${directory.path}/Course')..createSync();
    final video = File('${directory.path}/clip.mp4')..writeAsStringSync('');
    File('${directory.path}/notes.txt').writeAsStringSync('');
    final requests = VideoOpenRequests(acceptsImports: true);

    requests.addAll([
      audio.path,
      subtitle.path,
      folder.path,
      video.path,
      '${directory.path}/notes.txt',
    ]);

    expect(requests.takeLatest(), video.path);
    expect(requests.takeImports(), [audio.path, subtitle.path, folder.path]);
    expect(requests.hasImports, isFalse);
  });

  test('desktop ignores files that are not videos', () {
    File('${directory.path}/talk.m4a').writeAsStringSync('');
    final requests = VideoOpenRequests()
      ..addAll(['${directory.path}/talk.m4a']);
    expect(requests.hasImports, isFalse);
    expect(requests.hasPending, isFalse);
  });

  test('video playback positions survive a reload', () async {
    final paths = AppPaths.forTesting(directory.path);
    final video = '${directory.path}/movie.mkv';
    await JsonVideoPlaybackRepository(paths).save(
      video,
      VideoPlaybackEntry(
        positionMs: 42000,
        subtitleId: 'embedded:3',
        updatedAt: DateTime.utc(2026, 10, 11),
      ),
    );
    await pendingFileWrites();

    final restored = await JsonVideoPlaybackRepository(paths).load(video);

    expect(restored?.positionMs, 42000);
    expect(restored?.subtitleId, 'embedded:3');
    expect(await JsonVideoPlaybackRepository(paths).load('/other.mp4'), isNull);
  });
}
