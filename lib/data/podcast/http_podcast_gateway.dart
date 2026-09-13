import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/contracts.dart';
import '../../core/models.dart';
import '../../core/podcast_models.dart';
import 'podcast_urls.dart';
import 'rss_parser.dart';

class HttpPodcastGateway implements PodcastGateway {
  HttpPodcastGateway({
    http.Client? client,
    this.searchEndpoint = 'https://itunes.apple.com/search',
    PodcastRssParser parser = const PodcastRssParser(),
    this.maxFeedBytes = defaultMaxFeedBytes,
  }) : _client = client ?? http.Client(),
       _parser = parser;

  static const defaultMaxFeedBytes = 32 * 1024 * 1024;
  static const maxTranscriptBytes = 20 * 1024 * 1024;
  static const maxRedirects = 5;
  static const _minSearchInterval = Duration(milliseconds: 3000);

  final http.Client _client;
  final String searchEndpoint;
  final PodcastRssParser _parser;
  final int maxFeedBytes;
  DateTime _lastSearchAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Future<List<PodcastShowSummary>> searchShows(
    String query, {
    String country = 'us',
  }) async {
    final trimmed = query.trim();
    if (trimmed.length < 2) return const [];
    final wait = _minSearchInterval - DateTime.now().difference(_lastSearchAt);
    if (!wait.isNegative) await Future<void>.delayed(wait);
    _lastSearchAt = DateTime.now();
    final uri = Uri.parse(searchEndpoint).replace(
      queryParameters: {
        'term': trimmed,
        'media': 'podcast',
        'entity': 'podcast',
        'country': country,
        'limit': '25',
      },
    );
    final response = await _send(
      http.Request('GET', uri),
      maxBytes: 1024 * 1024,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const PodcastException('podcast_search_failed');
    }
    return parseItunesResults(utf8.decode(await response.stream.toBytes()));
  }

  @override
  Future<List<PodcastShowSummary>> lookupShows(
    Iterable<String> collectionIds,
  ) async {
    final ids = collectionIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return const [];
    final uri = Uri.https('itunes.apple.com', '/lookup', {
      'id': ids.join(','),
      'entity': 'podcast',
    });
    final response = await _send(
      http.Request('GET', uri),
      maxBytes: 1024 * 1024,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const PodcastException('podcast_lookup_failed');
    }
    return parseItunesResults(utf8.decode(await response.stream.toBytes()));
  }

  @override
  Future<List<PodcastShowSummary>> topShows({
    String country = 'us',
    int? genreId,
    int limit = 16,
    bool resolveFeeds = true,
  }) async {
    final path = genreId == null
        ? '/$country/rss/toppodcasts/limit=$limit/explicit=true/json'
        : '/$country/rss/toppodcasts/limit=$limit/genre=$genreId/explicit=true/json';
    final response = await _send(
      http.Request('GET', Uri.https('itunes.apple.com', path)),
      maxBytes: 1024 * 1024,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const PodcastException('podcast_chart_failed');
    }
    final chart = parseApplePodcastChart(
      utf8.decode(await response.stream.toBytes()),
    );
    if (chart.isEmpty) return const [];
    if (!resolveFeeds) return chart;
    try {
      final resolved = await lookupShows(chart.map((item) => item.id));
      if (resolved.isNotEmpty) return resolved;
    } on Object {
      // Artwork from the chart is still enough to render the browse mosaic.
    }
    return chart;
  }

  @override
  Future<PodcastFeed> fetchFeed(String feedUrl) async {
    final url = canonicalizeHttpUrl(feedUrl);
    if (url == null) throw const PodcastException('podcast_invalid_feed_url');
    final http.StreamedResponse response;
    try {
      response = await _send(
        http.Request('GET', Uri.parse(url)),
        maxBytes: maxFeedBytes,
      );
    } on PodcastException catch (error) {
      if (error.code == 'podcast_payload_too_large') {
        throw const PodcastException('podcast_feed_too_large');
      }
      rethrow;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PodcastException(
        'podcast_feed_failed',
        message: redactUrlForDiagnostics(url),
      );
    }
    return _parser.parse(
      utf8.decode(await response.stream.toBytes()),
      requestedFeedUrl: url,
    );
  }

  @override
  Future<void> downloadEpisode({
    required String enclosureUrl,
    required String destinationPath,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    final url = canonicalizeHttpUrl(enclosureUrl);
    if (url == null) throw const PodcastException('podcast_invalid_media_url');
    final destination = File(destinationPath);
    final part = File('$destinationPath.part');
    await part.parent.create(recursive: true);
    var offset = await part.exists() ? await part.length() : 0;
    final request = http.Request('GET', Uri.parse(url));
    if (offset > 0) request.headers[HttpHeaders.rangeHeader] = 'bytes=$offset-';
    final response = await _send(
      request,
      maxBytes: null,
      streamed: true,
      shouldCancel: shouldCancel,
    );
    if (response.statusCode == 200) {
      if (await part.exists()) await part.delete();
      offset = 0;
    } else if (response.statusCode != 206) {
      throw PodcastException(
        'podcast_download_failed',
        message: redactUrlForDiagnostics(url),
      );
    }
    final total = _totalBytes(response, offset);
    var received = offset;
    final sink = part.openWrite(mode: FileMode.append);
    try {
      await for (final chunk in response.stream) {
        if (shouldCancel?.call() ?? false) {
          throw const OperationCancelledException();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(
          total == null || total == 0 ? null : received / total,
          null,
        );
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (await destination.exists()) await destination.delete();
    await part.rename(destination.path);
  }

  @override
  Future<String> fetchTranscript(PodcastTranscriptReference reference) async {
    final url = canonicalizeHttpUrl(reference.url);
    if (url == null) {
      throw const PodcastException('podcast_invalid_transcript_url');
    }
    final response = await _send(
      http.Request('GET', Uri.parse(url)),
      maxBytes: maxTranscriptBytes,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const PodcastException('podcast_transcript_failed');
    }
    return utf8.decode(await response.stream.toBytes());
  }

  Future<http.StreamedResponse> _send(
    http.Request request, {
    required int? maxBytes,
    bool streamed = false,
    CancelCheck? shouldCancel,
  }) async {
    var current = request;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      if (shouldCancel?.call() ?? false) {
        throw const OperationCancelledException();
      }
      current.followRedirects = false;
      current.headers.putIfAbsent(
        HttpHeaders.userAgentHeader,
        () => 'Listenook/1.2 (podcast)',
      );
      final response = await _client.send(current);
      if (response.isRedirect) {
        final location = response.headers[HttpHeaders.locationHeader];
        await response.stream.drain<void>();
        final next = canonicalizeHttpUrl(
          location == null
              ? ''
              : Uri.parse(current.url.toString()).resolve(location).toString(),
        );
        if (next == null) {
          throw const PodcastException('podcast_invalid_redirect');
        }
        if (hop == maxRedirects) {
          throw const PodcastException('podcast_too_many_redirects');
        }
        current = http.Request(current.method, Uri.parse(next));
        current.headers.addAll(request.headers);
        continue;
      }
      if (!streamed) {
        final announced = response.contentLength;
        if (maxBytes != null && announced != null && announced > maxBytes) {
          await response.stream.drain<void>();
          throw const PodcastException('podcast_payload_too_large');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          bytes.add(chunk);
          if (maxBytes != null && bytes.length > maxBytes) {
            throw const PodcastException('podcast_payload_too_large');
          }
        }
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([bytes.takeBytes()]),
          response.statusCode,
          headers: response.headers,
          reasonPhrase: response.reasonPhrase,
        );
      }
      return response;
    }
    throw const PodcastException('podcast_too_many_redirects');
  }

  int? _totalBytes(http.StreamedResponse response, int offset) {
    final range = response.headers[HttpHeaders.contentRangeHeader];
    if (range != null) {
      final match = RegExp(r'/(\d+)$').firstMatch(range);
      if (match != null) return int.parse(match.group(1)!);
    }
    final length = response.contentLength;
    if (length == null) return null;
    return response.statusCode == 206 ? length + offset : length;
  }
}

List<PodcastShowSummary> parseItunesResults(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map || decoded['results'] is! List) return const [];
  return [
    for (final item in decoded['results'] as List)
      if (item is Map) ?showFromItunesResult(item.cast<String, dynamic>()),
  ];
}

PodcastShowSummary? showFromItunesResult(Map<String, dynamic> item) {
  if ('${item['kind'] ?? ''}'.trim().toLowerCase() != 'podcast') return null;
  final title = '${item['collectionName'] ?? ''}'.trim();
  if (title.isEmpty) return null;
  final feedUrl = canonicalizeHttpUrl('${item['feedUrl'] ?? ''}') ?? '';
  return PodcastShowSummary(
    id: '${item['collectionId'] ?? feedUrl}',
    title: title,
    feedUrl: feedUrl,
    author: _optionalItunesString(item['artistName']),
    artworkUrl: _optionalItunesString(
      item['artworkUrl600'] ?? item['artworkUrl100'],
    ),
    showUrl: canonicalizeHttpUrl('${item['collectionViewUrl'] ?? ''}'),
    genre: _optionalItunesString(item['primaryGenreName']),
  );
}

List<PodcastShowSummary> parseApplePodcastChart(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) return const [];
  final feed = decoded['feed'];
  if (feed is! Map) return const [];
  final entries = feed['entry'];
  final items = entries is List
      ? entries
      : entries is Map
      ? [entries]
      : const [];
  final shows = <PodcastShowSummary>[];
  for (final item in items) {
    if (item is! Map) continue;
    final json = item.cast<String, dynamic>();
    final id = _appleLabel(json['id'], attribute: 'im:id');
    final title = _appleLabel(json['im:name']) ?? _appleLabel(json['title']);
    if (id == null || id.isEmpty || title == null || title.isEmpty) continue;
    shows.add(
      PodcastShowSummary(
        id: id,
        title: title,
        author: _appleLabel(json['im:artist']),
        artworkUrl: _largestAppleImage(json['im:image']),
        showUrl: _appleLabel(json['id']) ?? _appleHref(json['link']),
      ),
    );
  }
  return shows;
}

String? _optionalItunesString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

String? _appleLabel(Object? value, {String? attribute}) {
  if (value is Map) {
    if (attribute != null) {
      final attributes = value['attributes'];
      if (attributes is Map && attributes[attribute] != null) {
        return attributes[attribute].toString().trim();
      }
    }
    final label = value['label'];
    if (label != null) return label.toString().trim();
  }
  return value?.toString().trim();
}

String? _appleHref(Object? value) {
  if (value is Map) {
    final attributes = value['attributes'];
    if (attributes is Map && attributes['href'] != null) {
      return attributes['href'].toString();
    }
  }
  if (value is List && value.isNotEmpty) return _appleHref(value.first);
  return null;
}

String? _largestAppleImage(Object? value) {
  if (value is! List) return _appleLabel(value);
  String? best;
  var bestSize = -1;
  for (final item in value) {
    if (item is! Map) continue;
    final url = _appleLabel(item);
    final height =
        int.tryParse(_appleLabel(item, attribute: 'height') ?? '') ?? 0;
    if (url == null || url.isEmpty) continue;
    if (height >= bestSize) {
      best = url;
      bestSize = height;
    }
  }
  return best;
}

class MemoryPodcastGateway implements PodcastGateway {
  MemoryPodcastGateway({
    this.shows = const [],
    this.feeds = const {},
    this.transcripts = const {},
    this.enclosures = const {},
  });

  List<PodcastShowSummary> shows;
  Map<String, PodcastFeed> feeds;
  Map<String, String> transcripts;
  Map<String, List<int>> enclosures;
  final searchQueries = <String>[];
  final downloads = <String>[];

  @override
  Future<List<PodcastShowSummary>> searchShows(
    String query, {
    String country = 'us',
  }) async {
    searchQueries.add(query);
    final needle = query.toLowerCase();
    return [
      for (final show in shows)
        if (show.title.toLowerCase().contains(needle)) show,
    ];
  }

  @override
  Future<List<PodcastShowSummary>> lookupShows(
    Iterable<String> collectionIds,
  ) async {
    final wanted = collectionIds.map((id) => id.trim()).toSet();
    return [
      for (final show in shows)
        if (wanted.contains(show.id)) show,
    ];
  }

  @override
  Future<List<PodcastShowSummary>> topShows({
    String country = 'us',
    int? genreId,
    int limit = 16,
    bool resolveFeeds = true,
  }) async {
    final source = genreId == null
        ? shows
        : [
            for (final show in shows)
              if (show.genre == '$genreId') show,
          ];
    return (source.isEmpty ? shows : source).take(limit).toList();
  }

  @override
  Future<PodcastFeed> fetchFeed(String feedUrl) async {
    final url = canonicalizeHttpUrl(feedUrl) ?? feedUrl;
    final feed = feeds[url];
    if (feed == null) throw const PodcastException('podcast_feed_failed');
    return feed;
  }

  @override
  Future<void> downloadEpisode({
    required String enclosureUrl,
    required String destinationPath,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    downloads.add(enclosureUrl);
    final bytes = enclosures[enclosureUrl];
    if (bytes == null) throw const PodcastException('podcast_download_failed');
    final file = File(destinationPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    onProgress?.call(1, null);
  }

  @override
  Future<String> fetchTranscript(PodcastTranscriptReference reference) async {
    final body = transcripts[reference.url];
    if (body == null) throw const PodcastException('podcast_transcript_failed');
    return body;
  }
}
