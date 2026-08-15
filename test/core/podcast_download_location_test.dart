import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/podcast_models.dart';
import 'package:meow_stt/data/podcast/download_location.dart';
import 'package:meow_stt/data/podcast/podcast_urls.dart';

void main() {
  const locator = PodcastDownloadLocator();
  const episode = PodcastEpisode(
    id: 'https://feeds.example/show\nguid-abc-123456',
    feedUrl: 'https://feeds.example/show',
    title: 'Listen: Today / Tomorrow?',
    enclosureUrl: 'https://cdn.example/ep.mp3',
    mediaExtension: 'mp3',
    guid: 'guid-abc-123456',
  );

  test('always writes into application-managed storage', () {
    final location = locator.resolve(
      jobId: 'job-1',
      episode: episode,
      managedRoot: '/tmp/MeowSTT',
    );

    expect(location.kind, PodcastDownloadLocationKind.managedCache);
    expect(location.directory, '/tmp/MeowSTT/podcasts/job-1');
    expect(location.fileName, contains('Listen Today Tomorrow'));
    expect(location.fileName, endsWith('.mp3'));
    expect(location.partPath, endsWith('.mp3.part'));
  });

  test('episode identity owns serialization and filename shortening', () {
    final identity = PodcastEpisodeId.fromParts(
      feedUrl: episode.feedUrl,
      guid: episode.guid,
      enclosureUrl: episode.enclosureUrl,
    );

    expect(identity.serialized, episode.id);
    expect(PodcastEpisodeId.parse(episode.id), identity);
    expect(identity.shortFileComponent, 'guidabc123');
  });
}
