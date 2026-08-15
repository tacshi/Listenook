import 'package:xml/xml.dart';

import '../../core/models.dart';
import '../../core/podcast_models.dart';
import 'html_text.dart';
import 'podcast_urls.dart';

class PodcastRssParser {
  const PodcastRssParser();

  PodcastFeed parse(String xml, {required String requestedFeedUrl}) {
    final document = XmlDocument.parse(xml);
    final channel = document.findAllElements('channel').firstOrNull;
    if (channel == null) {
      throw const PodcastException('podcast_invalid_feed');
    }
    final feedUrl =
        canonicalizeHttpUrl(
          _childText(channel, 'atom:link') ??
              _atomSelfHref(channel) ??
              requestedFeedUrl,
        ) ??
        canonicalizeHttpUrl(requestedFeedUrl);
    if (feedUrl == null) {
      throw const PodcastException('podcast_invalid_feed_url');
    }
    final title = _text(channel, const ['title']) ?? '';
    if (title.trim().isEmpty) {
      throw const PodcastException('podcast_invalid_feed');
    }
    final artwork =
        _itunesImage(channel) ??
        _childAttribute(channel, 'image', 'href') ??
        _nestedText(channel, const ['image', 'url']);
    final episodes = <PodcastEpisode>[];
    final seen = <String>{};
    for (final item in channel.findElements('item')) {
      final episode = _episode(item, feedUrl: feedUrl, showArtwork: artwork);
      if (episode == null) continue;
      if (!seen.add(episode.id)) continue;
      episodes.add(episode);
    }
    if (episodes.isEmpty) {
      throw const PodcastException('podcast_feed_empty');
    }
    episodes.sort((a, b) {
      final aDate = a.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bDate = b.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bDate.compareTo(aDate);
    });
    return PodcastFeed(
      feedUrl: feedUrl,
      title: title.trim(),
      author: _text(channel, const [
        'itunes:author',
        'author',
        'managingEditor',
      ]),
      description: _html(
        _text(channel, const ['description', 'itunes:summary']),
      ),
      artworkUrl: artwork,
      language: _text(channel, const ['language']),
      showUrl: canonicalizeHttpUrl(_text(channel, const ['link']) ?? ''),
      episodes: List.unmodifiable(episodes),
      fetchedAt: DateTime.now().toUtc(),
    );
  }

  PodcastEpisode? _episode(
    XmlElement item, {
    required String feedUrl,
    String? showArtwork,
  }) {
    final enclosure = _enclosure(item);
    if (enclosure == null) return null;
    final guid = _text(item, const ['guid']);
    final title = _text(item, const ['title', 'itunes:title'])?.trim();
    if (title == null || title.isEmpty) return null;
    final id = PodcastEpisodeId.fromParts(
      feedUrl: feedUrl,
      guid: guid,
      enclosureUrl: enclosure.url,
    );
    return PodcastEpisode(
      id: id.serialized,
      feedUrl: feedUrl,
      title: title,
      enclosureUrl: enclosure.url,
      mediaExtension: enclosure.extension,
      guid: guid?.trim().isEmpty ?? true ? null : guid!.trim(),
      publishedAt: _date(_text(item, const ['pubDate', 'itunes:pubDate'])),
      durationMs: _durationMs(_text(item, const ['itunes:duration'])),
      // content:encoded is the publisher's rich episode description. Keep its
      // HTML intact; the detail view renders it with a restricted tag set.
      description: _description(item),
      episodeUrl: canonicalizeHttpUrl(_text(item, const ['link']) ?? ''),
      artworkUrl: _itunesImage(item) ?? showArtwork,
      mimeType: enclosure.mimeType,
      transcripts: _transcripts(item),
    );
  }

  ({String url, String extension, String? mimeType})? _enclosure(
    XmlElement item,
  ) {
    for (final enclosure in item.findElements('enclosure')) {
      final url = canonicalizeHttpUrl(enclosure.getAttribute('url') ?? '');
      if (url == null) continue;
      final mimeType = enclosure.getAttribute('type');
      final extension = extensionForEnclosure(url: url, mimeType: mimeType);
      if (extension == null) continue;
      return (url: url, extension: extension, mimeType: mimeType);
    }
    final mediaContent = item.findAllElements('media:content').firstOrNull;
    if (mediaContent != null) {
      final url = canonicalizeHttpUrl(mediaContent.getAttribute('url') ?? '');
      final mimeType = mediaContent.getAttribute('type');
      if (url != null) {
        final extension = extensionForEnclosure(url: url, mimeType: mimeType);
        if (extension != null) {
          return (url: url, extension: extension, mimeType: mimeType);
        }
      }
    }
    return null;
  }

  List<PodcastTranscriptReference> _transcripts(XmlElement item) {
    final result = <PodcastTranscriptReference>[];
    for (final node in item.childElements.where(
      (node) => node.name.local == 'transcript',
    )) {
      final url = canonicalizeHttpUrl(
        node.getAttribute('url') ?? node.innerText,
      );
      if (url == null) continue;
      result.add(
        PodcastTranscriptReference(
          url: url,
          type: node.getAttribute('type'),
          language: node.getAttribute('language'),
          rel: node.getAttribute('rel'),
        ),
      );
    }
    return result;
  }

  String? _atomSelfHref(XmlElement channel) {
    for (final link in channel.findElements('link')) {
      if ((link.getAttribute('rel') ?? '') == 'self') {
        return link.getAttribute('href');
      }
    }
    for (final link in channel.findElements('atom:link')) {
      if ((link.getAttribute('rel') ?? '') == 'self') {
        return link.getAttribute('href');
      }
    }
    return null;
  }

  String? _itunesImage(XmlElement parent) {
    for (final name in const ['itunes:image', 'image']) {
      for (final node in parent.findElements(name)) {
        final href = node.getAttribute('href') ?? node.getAttribute('url');
        final url = canonicalizeHttpUrl(href ?? '');
        if (url != null) return url;
      }
    }
    return null;
  }

  String? _childAttribute(XmlElement parent, String name, String attribute) {
    final node = parent.findElements(name).firstOrNull;
    return canonicalizeHttpUrl(node?.getAttribute(attribute) ?? '');
  }

  String? _nestedText(XmlElement parent, List<String> path) {
    XmlElement? current = parent;
    for (final name in path) {
      current = current?.findElements(name).firstOrNull;
    }
    return canonicalizeHttpUrl(current?.innerText ?? '');
  }

  String? _text(XmlElement parent, List<String> names) {
    for (final name in names) {
      final local = name.contains(':') ? name.split(':').last : name;
      for (final node in parent.childElements) {
        if (node.name.local == local || node.name.qualified == name) {
          final value = node.innerText.trim();
          if (value.isNotEmpty) return value;
        }
      }
    }
    return null;
  }

  String? _childText(XmlElement parent, String name) => _text(parent, [name]);

  String? _html(String? value) {
    if (value == null) return null;
    final stripped = stripHtml(value);
    return stripped.isEmpty ? null : stripped;
  }

  String? _description(XmlElement item) {
    final value = _text(item, const [
      'content:encoded',
      'description',
      'itunes:summary',
    ]);
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  DateTime? _date(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    return DateTime.tryParse(raw.trim())?.toUtc() ?? _rfc822(raw.trim());
  }

  DateTime? _rfc822(String raw) {
    const months = {
      'jan': 1,
      'feb': 2,
      'mar': 3,
      'apr': 4,
      'may': 5,
      'jun': 6,
      'jul': 7,
      'aug': 8,
      'sep': 9,
      'oct': 10,
      'nov': 11,
      'dec': 12,
    };
    final match = RegExp(
      r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?',
    ).firstMatch(raw);
    if (match == null) return null;
    final month = months[match.group(2)!.toLowerCase()];
    if (month == null) return null;
    return DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6) ?? '0'),
    );
  }

  int? _durationMs(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = raw.trim();
    if (RegExp(r'^\d+$').hasMatch(value)) {
      return int.parse(value) * 1000;
    }
    final parts = value.split(':').map(int.tryParse).toList();
    if (parts.any((part) => part == null)) return null;
    var seconds = 0;
    for (final part in parts) {
      seconds = seconds * 60 + part!;
    }
    return seconds * 1000;
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
