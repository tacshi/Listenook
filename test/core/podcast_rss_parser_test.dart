import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/podcast_models.dart';
import 'package:listenook/data/podcast/http_podcast_gateway.dart';
import 'package:listenook/data/podcast/podcast_urls.dart';
import 'package:listenook/data/podcast/rss_parser.dart';

void main() {
  const parser = PodcastRssParser();

  test('parses a namespaced iTunes feed and preserves rich descriptions', () {
    final feed = parser.parse(_sampleFeed, requestedFeedUrl: _requestedUrl);

    expect(feed.title, 'All Ears English');
    expect(feed.author, 'Lindsay and Michelle');
    expect(feed.language, 'en-us');
    expect(feed.episodes, hasLength(2));
    expect(feed.episodes.first.title, 'Newest episode');
    expect(feed.episodes.first.guid, 'ep-2');
    expect(feed.episodes.first.durationMs, 12 * 60 * 1000);
    expect(
      feed.episodes.first.description,
      '<p>Hello <strong>learners</strong>.</p>',
    );
    expect(
      feed.episodes.first.episodeUrl,
      'https://example.com/episodes/newest',
    );
    expect(feed.episodes.first.transcripts, hasLength(1));
    expect(feed.episodes.first.transcripts.single.type, 'text/vtt');
    expect(feed.episodes.last.enclosureUrl, contains('first.mp3'));
    expect(feed.episodes.any((item) => item.title == 'No audio'), isFalse);
  });

  test(
    'deduplicates items and falls back to enclosure when GUID is missing',
    () {
      final feed = parser.parse(
        _duplicateFeed,
        requestedFeedUrl: _requestedUrl,
      );

      expect(feed.episodes, hasLength(2));
      expect(feed.episodes.first.id, contains('https://cdn.example/a.mp3'));
      expect(feed.episodes.last.id, contains('guid-b'));
    },
  );

  test('rejects feeds without a supported enclosure', () {
    expect(
      () => parser.parse(_emptyFeed, requestedFeedUrl: _requestedUrl),
      throwsA(
        isA<PodcastException>().having(
          (error) => error.code,
          'code',
          'podcast_feed_empty',
        ),
      ),
    );
  });

  test('rejects malformed XML', () {
    expect(
      () => parser.parse('<rss><channel>', requestedFeedUrl: _requestedUrl),
      throwsA(anything),
    );
  });

  test('talk-heavy filter drops entertainment charts', () {
    const kept = PodcastShowSummary(id: '1', title: 'The Daily', genre: 'News');
    const dropped = PodcastShowSummary(
      id: '2',
      title: 'A Music Show',
      genre: 'Music',
    );
    expect(talkHeavyShows([kept, dropped]).single.id, '1');
  });

  test('parses Apple top-podcast chart entries', () {
    final shows = parseApplePodcastChart(_appleChart);

    expect(shows, hasLength(2));
    expect(shows.first.id, '1200361736');
    expect(shows.first.title, 'The Daily');
    expect(shows.first.artworkUrl, contains('170x170'));
    expect(shows.last.title, 'TED Talks Daily');
  });

  test('canonicalizes feed URLs and redacts secrets from diagnostics', () {
    expect(
      canonicalizeHttpUrl('HTTPS://Example.com:443/feed/'),
      'https://example.com/feed',
    );
    expect(
      redactUrlForDiagnostics(
        'https://cdn.example/file.mp3?token=secret&name=ep',
      ),
      'https://cdn.example/file.mp3?name=ep',
    );
  });
}

const _requestedUrl = 'https://feeds.example.com/english.xml';

const _sampleFeed = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
     xmlns:podcast="https://podcastindex.org/namespace/1.0">
  <channel>
    <title>All Ears English</title>
    <language>en-us</language>
    <itunes:author>Lindsay and Michelle</itunes:author>
    <item>
      <title>Older episode</title>
      <guid>ep-1</guid>
      <pubDate>Mon, 01 Jan 2024 08:00:00 GMT</pubDate>
      <enclosure url="https://cdn.example/first.mp3" type="audio/mpeg"/>
    </item>
    <item>
      <title>Newest episode</title>
      <guid>ep-2</guid>
      <pubDate>Mon, 08 Jan 2024 08:00:00 GMT</pubDate>
      <itunes:duration>12:00</itunes:duration>
      <description>&lt;p&gt;Hello &lt;strong&gt;learners&lt;/strong&gt;.&lt;/p&gt;</description>
      <content:encoded xmlns:content="http://purl.org/rss/1.0/modules/content/"><![CDATA[<p>Hello <strong>learners</strong>.</p>]]></content:encoded>
      <link>https://example.com/episodes/newest</link>
      <enclosure url="https://cdn.example/second.mp3" type="audio/mpeg"/>
      <podcast:transcript url="https://cdn.example/second.vtt" type="text/vtt" language="en"/>
    </item>
    <item>
      <title>No audio</title>
      <guid>ep-3</guid>
    </item>
  </channel>
</rss>
''';

const _duplicateFeed = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Duplicates</title>
    <item>
      <title>A</title>
      <enclosure url="https://cdn.example/a.mp3" type="audio/mpeg"/>
    </item>
    <item>
      <title>A again</title>
      <enclosure url="https://cdn.example/a.mp3" type="audio/mpeg"/>
    </item>
    <item>
      <title>B</title>
      <guid>guid-b</guid>
      <enclosure url="https://cdn.example/b.mp3" type="audio/mpeg"/>
    </item>
  </channel>
</rss>
''';

const _appleChart = '''
{
  "feed": {
    "entry": [
      {
        "im:name": {"label": "The Daily"},
        "im:artist": {"label": "The New York Times"},
        "im:image": [
          {"label": "https://is1-ssl.mzstatic.com/60x60bb.jpg", "attributes": {"height": "60"}},
          {"label": "https://is1-ssl.mzstatic.com/170x170bb.jpg", "attributes": {"height": "170"}}
        ],
        "id": {
          "label": "https://podcasts.apple.com/us/podcast/the-daily/id1200361736",
          "attributes": {"im:id": "1200361736"}
        }
      },
      {
        "im:name": {"label": "TED Talks Daily"},
        "im:artist": {"label": "TED"},
        "im:image": [
          {"label": "https://example.com/ted.jpg", "attributes": {"height": "170"}}
        ],
        "id": {
          "label": "https://podcasts.apple.com/us/podcast/ted/id160904630",
          "attributes": {"im:id": "160904630"}
        }
      }
    ]
  }
}
''';

const _emptyFeed = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Empty</title>
    <item>
      <title>Text only</title>
    </item>
  </channel>
</rss>
''';
