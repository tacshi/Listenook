import 'dart:async';

import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:material_ui/material_ui.dart';
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

  static const _hiddenTags = {
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
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final body = theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16);
    final primary = _cssColor(colors.primary);
    final outline = _cssColor(colors.outlineVariant);
    return SelectionArea(
      child: HtmlWidget(
        podcastDescriptionHtml(description),
        key: const Key('podcast-episode-description-html'),
        textStyle: body.copyWith(height: 1.5, color: colors.onSurface),
        customWidgetBuilder: (element) =>
            _hiddenTags.contains(element.localName)
            ? const SizedBox.shrink()
            : null,
        customStylesBuilder: (element) => switch (element.localName) {
          'p' => {'margin': '0 0 14px 0'},
          'h1' => _headingStyles(theme.textTheme.headlineSmall),
          'h2' => _headingStyles(theme.textTheme.titleLarge),
          'h3' => _headingStyles(theme.textTheme.titleMedium),
          'a' => {
            'color': primary,
            'text-decoration': 'underline',
            'text-decoration-color': primary,
          },
          'blockquote' => {
            'margin': '0 0 14px 12px',
            'padding': '0 0 0 12px',
            'border-left': '1px solid $outline',
          },
          'hr' => {'margin': '12px 0', 'color': outline},
          _ => null,
        },
        onTapUrl: (url) {
          final uri = _safeExternalUri(url);
          if (uri != null) {
            unawaited(
              openLink?.call(uri) ??
                  launchUrl(uri, mode: LaunchMode.externalApplication),
            );
          }
          // Claim every tap so unsafe links are never handed to the default
          // launcher.
          return true;
        },
      ),
    );
  }

  static Map<String, String> _headingStyles(TextStyle? textStyle) => {
    if (textStyle?.fontSize case final size?) 'font-size': '${size}px',
    'font-weight': 'bold',
    'margin': '8px 0',
  };
}

String _cssColor(Color color) {
  int channel(double value) => (value * 255).round();
  return 'rgba(${channel(color.r)}, ${channel(color.g)}, ${channel(color.b)}, '
      '${color.a.toStringAsFixed(3)})';
}

Uri? _safeExternalUri(String? value) {
  final uri = value == null ? null : Uri.tryParse(value);
  if (uri == null || !uri.hasScheme) return null;
  return switch (uri.scheme.toLowerCase()) {
    'http' || 'https' || 'mailto' => uri,
    _ => null,
  };
}
