import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/podcast/html_text.dart';

typedef PodcastDescriptionLinkOpener = Future<void> Function(Uri uri);

class PodcastEpisodeDescription extends StatelessWidget {
  const PodcastEpisodeDescription({
    super.key,
    required this.description,
    this.openLink,
  });

  final String description;
  final PodcastDescriptionLinkOpener? openLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final body = theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16);
    return SelectionArea(
      child: Html(
        key: const Key('podcast-episode-description-html'),
        data: podcastDescriptionHtml(description),
        doNotRenderTheseTags: const {
          'script',
          'style',
          'iframe',
          'object',
          'embed',
          'form',
          'input',
          'button',
          'video',
          'audio',
          'img',
          'svg',
        },
        style: {
          'body': Style.fromTextStyle(
            body.copyWith(height: 1.5, color: colors.onSurface),
          ).copyWith(margin: Margins.zero, padding: HtmlPaddings.zero),
          'p': Style(margin: Margins.only(bottom: 14)),
          'h1': _headingStyle(theme.textTheme.headlineSmall),
          'h2': _headingStyle(theme.textTheme.titleLarge),
          'h3': _headingStyle(theme.textTheme.titleMedium),
          'a': Style(
            color: colors.primary,
            textDecoration: TextDecoration.underline,
            textDecorationColor: colors.primary,
          ),
          'blockquote': Style(
            margin: Margins.only(left: 12, bottom: 14),
            padding: HtmlPaddings.only(left: 12),
            border: Border(left: BorderSide(color: colors.outlineVariant)),
          ),
          'hr': Style(
            margin: Margins.symmetric(vertical: 12),
            border: Border(top: BorderSide(color: colors.outlineVariant)),
          ),
        },
        onLinkTap: (url, _, _) {
          final uri = _safeExternalUri(url);
          if (uri == null) return;
          unawaited(
            openLink?.call(uri) ??
                launchUrl(uri, mode: LaunchMode.externalApplication),
          );
        },
      ),
    );
  }

  static Style _headingStyle(TextStyle? textStyle) => Style.fromTextStyle(
    (textStyle ?? const TextStyle()).copyWith(fontWeight: FontWeight.w700),
  ).copyWith(margin: Margins.only(top: 8, bottom: 8));
}

Uri? _safeExternalUri(String? value) {
  final uri = value == null ? null : Uri.tryParse(value);
  if (uri == null || !uri.hasScheme) return null;
  return switch (uri.scheme.toLowerCase()) {
    'http' || 'https' || 'mailto' => uri,
    _ => null,
  };
}
