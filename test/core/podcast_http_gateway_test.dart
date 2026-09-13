import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:listenook/core/podcast_models.dart';
import 'package:listenook/data/podcast/http_podcast_gateway.dart';

void main() {
  test('Apple lookup ignores non-podcast tracks returned for stale IDs', () {
    final shows = parseItunesResults('''
{
  "resultCount": 2,
  "results": [
    {
      "wrapperType": "track",
      "kind": "song",
      "collectionId": 1441595604,
      "trackId": 1441595773,
      "collectionName": "Musik' Haria"
    },
    {
      "wrapperType": "track",
      "kind": "podcast",
      "collectionId": 160904630,
      "collectionName": "TED Talks Daily",
      "feedUrl": "https://feeds.example/ted"
    }
  ]
}
''');

    expect(shows, hasLength(1));
    expect(shows.single.title, 'TED Talks Daily');
  });

  test('opens a large RSS catalog that used to exceed the 5MB cap', () async {
    final xml = _rssWithPadding(6 * 1024 * 1024);
    final gateway = HttpPodcastGateway(client: _ScriptedClient(xml));

    final feed = await gateway.fetchFeed('https://feeds.example/ted.xml');

    expect(feed.title, 'TED Talks Daily');
    expect(feed.episodes, hasLength(1));
    expect(feed.episodes.single.title, 'A talk');
  });

  test('maps an oversized feed to podcast_feed_too_large', () async {
    final gateway = HttpPodcastGateway(
      client: _ScriptedClient(_rssWithPadding(80)),
      maxFeedBytes: 40,
    );

    await expectLater(
      gateway.fetchFeed('https://feeds.example/huge.xml'),
      throwsA(
        isA<PodcastException>().having(
          (error) => error.code,
          'code',
          'podcast_feed_too_large',
        ),
      ),
    );
  });
}

class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.body);

  final String body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = body.codeUnits;
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      200,
      contentLength: bytes.length,
      headers: const {'content-type': 'application/rss+xml'},
    );
  }
}

String _rssWithPadding(int minBytes) {
  final padding = 'x' * minBytes;
  return '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>TED Talks Daily</title>
    <description>$padding</description>
    <item>
      <title>A talk</title>
      <guid>talk-1</guid>
      <enclosure url="https://cdn.example/talk.mp3" type="audio/mpeg"/>
    </item>
  </channel>
</rss>
''';
}
