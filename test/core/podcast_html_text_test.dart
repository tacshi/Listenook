import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/data/podcast/html_text.dart';

void main() {
  test('turns plain podcast notes into paragraphs, headings, and links', () {
    final html = podcastDescriptionHtml('''
Opening paragraph.

Sponsors:

Visit https://example.com/deals?src=podcast.&amp;nbsp;

Timestamps:

(00:00) Introduction
(03:12) Main topic
''');

    expect(html, contains('<p>Opening paragraph.</p>'));
    expect(html, contains('<p><strong>Sponsors:</strong></p>'));
    expect(
      html,
      contains(
        '<a href="https://example.com/deals?src=podcast">'
        'https://example.com/deals?src=podcast</a>.',
      ),
    );
    expect(html, isNot(contains('&amp;nbsp;')));
    expect(html, contains('(00:00) Introduction<br>(03:12) Main topic'));
  });

  test('keeps rich markup and preserves newlines inside HTML paragraphs', () {
    final html = podcastDescriptionHtml('''
<p><strong>Timestamps:</strong></p>
<p>(00:00) Introduction
(03:12) Main topic</p>
<p>-</p>
''');

    expect(html, contains('<p><strong>Timestamps:</strong></p>'));
    expect(html, contains('(00:00) Introduction<br>(03:12) Main topic'));
    expect(html, contains('<hr>'));
    expect(html, isNot(contains('<p>-</p>')));
  });
}
