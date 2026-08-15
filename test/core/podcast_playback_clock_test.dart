import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/core/podcast_models.dart';
import 'package:meow_stt/state/podcast_player.dart';

void main() {
  final sampledAt = DateTime.utc(2026, 8, 15, 12);

  test('paused clock stays on the last reported position', () {
    const clock = PodcastPlaybackClock(
      reportedMs: 1840,
      playing: false,
      rate: 1,
      sampledAt: null,
    );
    expect(clock.at(sampledAt.add(const Duration(milliseconds: 200))), 1840);
  });

  test('playing clock leads the report at the sample instant', () {
    final clock = PodcastPlaybackClock(
      reportedMs: 1000,
      playing: true,
      rate: 1,
      sampledAt: sampledAt,
    );
    expect(clock.at(sampledAt), 1000 + PodcastPlaybackClock.highlightLeadMs);
  });

  test('playing clock interpolates between media_kit ticks', () {
    final clock = PodcastPlaybackClock(
      reportedMs: 1000,
      playing: true,
      rate: 1,
      sampledAt: sampledAt,
    );
    expect(
      clock.at(sampledAt.add(const Duration(milliseconds: 120))),
      1000 + 120 + PodcastPlaybackClock.highlightLeadMs,
    );
  });

  test('interpolation respects playback rate', () {
    final clock = PodcastPlaybackClock(
      reportedMs: 2000,
      playing: true,
      rate: 1.5,
      sampledAt: sampledAt,
    );
    expect(
      clock.at(sampledAt.add(const Duration(milliseconds: 100))),
      2000 + 150 + PodcastPlaybackClock.highlightLeadMs,
    );
  });

  test('interpolation does not run away if position updates stall', () {
    final clock = PodcastPlaybackClock(
      reportedMs: 500,
      playing: true,
      rate: 1,
      sampledAt: sampledAt,
    );
    expect(
      clock.at(sampledAt.add(const Duration(seconds: 3))),
      500 +
          PodcastPlaybackClock.maxExtrapolateMs +
          PodcastPlaybackClock.highlightLeadMs,
    );
  });

  test('display position clamps to the known duration', () {
    final clock = PodcastPlaybackClock(
      reportedMs: 990,
      playing: true,
      rate: 1,
      durationMs: 1000,
      sampledAt: sampledAt,
    );
    expect(clock.at(sampledAt.add(const Duration(milliseconds: 80))), 1000);
  });

  test('display cue index uses the caption clock, not the raw report', () {
    const cues = [
      PodcastPlayerCue(startMs: 0, endMs: 400, text: 'Hello'),
      PodcastPlayerCue(startMs: 400, endMs: 900, text: 'world'),
    ];
    final clock = PodcastPlaybackClock(
      reportedMs: 350,
      playing: true,
      rate: 1,
      sampledAt: sampledAt,
    );
    expect(PodcastPlayer.cueIndexAt(cues, 350), 0);
    expect(PodcastPlayer.cueIndexAt(cues, clock.at(sampledAt)), 1);
  });

  test('playback source prefers an existing local file over the stream', () async {
    final directory = await Directory.systemTemp.createTemp('meow-local-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/episode.mp3')
      ..writeAsBytesSync(const [1, 2, 3]);

    expect(
      podcastPlaybackSource(
        enclosureUrl: 'https://cdn.example/episode.mp3',
        localPath: file.path,
      ),
      Uri.file(file.absolute.path).toString(),
    );
    expect(
      podcastPlaybackSource(
        enclosureUrl: 'https://cdn.example/episode.mp3',
        localPath: '${directory.path}/missing.mp3',
      ),
      'https://cdn.example/episode.mp3',
    );
    expect(
      podcastPlaybackSource(
        enclosureUrl: 'https://cdn.example/episode.mp3',
      ),
      'https://cdn.example/episode.mp3',
    );
  });

  test('provenance rebuilds a playable episode and feed', () {
    const provenance = PodcastEpisodeProvenance(
      feedUrl: 'https://feeds.example/show',
      episodeId: 'https://feeds.example/show\nguid-1',
      enclosureUrl: 'https://cdn.example/one.mp3',
      showTitle: 'The Daily',
      episodeTitle: 'Today',
      author: 'NYT',
      artworkUrl: 'https://cdn.example/art.jpg',
      description: 'Notes that should survive a download.',
    );
    final episode = provenance.toEpisode(durationMs: 1800000);
    final feed = provenance.toFeed(episode: episode);
    expect(episode.title, 'Today');
    expect(episode.durationMs, 1800000);
    expect(episode.description, 'Notes that should survive a download.');
    expect(feed.title, 'The Daily');
    expect(feed.author, 'NYT');
    expect(feed.episodes.single.id, episode.id);
  });
}
