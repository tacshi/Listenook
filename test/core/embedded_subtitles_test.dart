import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/data/embedded_subtitles.dart';

const _fixtures = 'test/fixtures/embedded_subtitles';

void main() {
  test('lists Matroska text subtitle tracks in container order', () {
    final tracks = EmbeddedSubtitleReader.listTracksSync(
      '$_fixtures/two_tracks.mkv',
    );

    expect(tracks, hasLength(2));
    expect(tracks[0].containerIndex, 2);
    expect(tracks[0].format, SubtitleFormat.srt);
    expect(tracks[0].language, 'eng');
    expect(tracks[0].title, 'English');
    expect(tracks[0].isDefault, isTrue);
    expect(tracks[1].containerIndex, 3);
    expect(tracks[1].format, SubtitleFormat.ass);
    expect(tracks[1].language, 'fre');
    expect(tracks[1].isDefault, isFalse);
  });

  test('extracts SRT cues from a Matroska track', () {
    final path = '$_fixtures/two_tracks.mkv';
    final track = EmbeddedSubtitleReader.listTracksSync(path).first;
    final cues = EmbeddedSubtitleReader.extractSync(path, track);

    expect(cues.map((cue) => (cue.startMs, cue.endMs)), [
      (200, 1000),
      (1200, 1900),
    ]);
    expect(cues.first.text, 'Hello <i>there</i>.');
    expect(cues.last.text, 'Second line, with comma.');
  });

  test('extracts ASS cues from a Matroska track without styling', () {
    final path = '$_fixtures/two_tracks.mkv';
    final track = EmbeddedSubtitleReader.listTracksSync(path).last;
    final cues = EmbeddedSubtitleReader.extractSync(path, track);

    expect(cues.map((cue) => (cue.startMs, cue.endMs)), [
      (300, 1100),
      (1300, 1800),
    ]);
    expect(cues.first.text, 'Bonjour, le monde');
    expect(cues.last.text, 'Deux\nlignes');
  });

  test('lists and extracts MP4 mov_text cues', () {
    final path = '$_fixtures/movtext.mp4';
    final tracks = EmbeddedSubtitleReader.listTracksSync(path);

    expect(tracks, hasLength(1));
    expect(tracks.single.format, SubtitleFormat.movText);
    expect(tracks.single.language, 'eng');
    expect(tracks.single.containerIndex, 2);

    final cues = EmbeddedSubtitleReader.extractSync(path, tracks.single);
    expect(cues.map((cue) => (cue.startMs, cue.endMs)), [
      (200, 1000),
      (1200, 1900),
    ]);
    expect(cues.first.text, 'Hello there.');
  });

  test('refuses to read cues from a picture-based track', () {
    const track = EmbeddedSubtitleTrack(
      containerIndex: 2,
      trackNumber: 3,
      codec: 'S_HDMV/PGS',
    );

    expect(
      () => EmbeddedSubtitleReader.extractSync(
        '$_fixtures/two_tracks.mkv',
        track,
      ),
      throwsA(isA<EmbeddedSubtitleException>()),
    );
  });

  test(
    'finds no tracks in a truncated container instead of crashing',
    () async {
      final directory = await Directory.systemTemp.createTemp('embedded-subs');
      addTearDown(() => directory.delete(recursive: true));
      final source = await File('$_fixtures/two_tracks.mkv').readAsBytes();
      final truncated = File('${directory.path}/broken.mkv')
        ..writeAsBytesSync(source.sublist(0, 40));

      expect(EmbeddedSubtitleReader.listTracksSync(truncated.path), isEmpty);
    },
  );
}
