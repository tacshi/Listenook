const _sensitiveQueryKeys = {
  'token',
  'access_token',
  'auth',
  'authorization',
  'key',
  'api_key',
  'apikey',
  'password',
  'secret',
  'signature',
  'sig',
};

const supportedPodcastMediaExtensions = {
  'mp3',
  'wav',
  'm4a',
  'ogg',
  'mp4',
  'mkv',
  'avi',
};

String? canonicalizeHttpUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  final path = uri.path.isEmpty ? '/' : uri.path;
  final normalizedPath = path == '/'
      ? '/'
      : path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
  return Uri(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host.toLowerCase(),
    port: uri.hasPort && !_isDefaultPort(uri) ? uri.port : null,
    path: normalizedPath,
    query: uri.hasQuery ? uri.query : null,
  ).toString();
}

bool _isDefaultPort(Uri uri) =>
    (uri.scheme == 'http' && uri.port == 80) ||
    (uri.scheme == 'https' && uri.port == 443);

String redactUrlForDiagnostics(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.queryParameters.isEmpty) return raw;
  final kept = <String, String>{};
  uri.queryParameters.forEach((key, value) {
    if (_sensitiveQueryKeys.contains(key.toLowerCase())) return;
    kept[key] = value;
  });
  return uri.replace(queryParameters: kept.isEmpty ? null : kept).toString();
}

class PodcastEpisodeId {
  const PodcastEpisodeId._({required this.feedUrl, required this.itemKey});

  factory PodcastEpisodeId.fromParts({
    required String feedUrl,
    String? guid,
    required String enclosureUrl,
  }) {
    final feed = canonicalizeHttpUrl(feedUrl) ?? feedUrl.trim();
    final normalizedGuid = guid?.trim().replaceAll('\n', ' ');
    final itemKey = normalizedGuid != null && normalizedGuid.isNotEmpty
        ? normalizedGuid
        : canonicalizeHttpUrl(enclosureUrl) ?? enclosureUrl.trim();
    return PodcastEpisodeId._(feedUrl: feed, itemKey: itemKey);
  }

  factory PodcastEpisodeId.parse(String serialized) {
    final separator = serialized.indexOf('\n');
    if (separator < 0) {
      return PodcastEpisodeId._(feedUrl: '', itemKey: serialized.trim());
    }
    return PodcastEpisodeId._(
      feedUrl: serialized.substring(0, separator),
      itemKey: serialized.substring(separator + 1),
    );
  }

  final String feedUrl;
  final String itemKey;

  String get serialized => '$feedUrl\n$itemKey';

  String get shortFileComponent {
    final compact = itemKey.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (compact.isEmpty) return 'episode';
    return compact.length <= 10 ? compact : compact.substring(0, 10);
  }

  @override
  bool operator ==(Object other) =>
      other is PodcastEpisodeId &&
      other.feedUrl == feedUrl &&
      other.itemKey == itemKey;

  @override
  int get hashCode => Object.hash(feedUrl, itemKey);
}

String? extensionForEnclosure({required String url, String? mimeType}) {
  final fromUrl = _extensionFromPath(Uri.tryParse(url)?.path ?? url);
  if (fromUrl != null) return fromUrl;
  return extensionForMimeType(mimeType);
}

String? extensionForMimeType(String? mimeType) {
  final type = mimeType?.split(';').first.trim().toLowerCase();
  return switch (type) {
    'audio/mpeg' || 'audio/mp3' => 'mp3',
    'audio/mp4' || 'audio/x-m4a' || 'audio/aac' => 'm4a',
    'audio/wav' || 'audio/x-wav' || 'audio/wave' => 'wav',
    'audio/ogg' || 'application/ogg' => 'ogg',
    'video/mp4' => 'mp4',
    'video/x-matroska' => 'mkv',
    'video/x-msvideo' || 'video/avi' => 'avi',
    _ => null,
  };
}

String? _extensionFromPath(String path) {
  final slash = path.lastIndexOf('/');
  final name = slash >= 0 ? path.substring(slash + 1) : path;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  final extension = name.substring(dot + 1).toLowerCase();
  return supportedPodcastMediaExtensions.contains(extension) ? extension : null;
}

String sanitizePodcastFileName(String value, {int maxLength = 80}) {
  var result = value.trim().replaceAll(RegExp(r'[<>:"/\\|?*]'), ' ');
  result = result.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (result.isEmpty) result = 'episode';
  if (result.length > maxLength) result = result.substring(0, maxLength).trim();
  return result;
}
