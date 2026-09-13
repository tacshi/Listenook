# Apple podcast transcript availability

Checked 2026-08-15.

## Finding

Apple does not document a supported way for a third-party podcast player to
download Apple-generated transcripts. Apple automatically creates transcripts
for eligible catalog episodes and displays them in Apple Podcasts, but the only
full-transcript download Apple documents is inside Apple Podcasts Connect for
the show's publisher. For listeners, Apple documents viewing the transcript and
copying at most 200 words at a time. See Apple's
[Transcripts on Apple Podcasts](https://podcasters.apple.com/support/5316-transcripts-on-apple-podcasts).

The public [iTunes Search API](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/)
is documented as a catalog search and ID-lookup service. Neither its documented
result fields nor the live
[Modern Wisdom lookup response](https://itunes.apple.com/lookup?id=1347973549&entity=podcast)
provides an Apple transcript URL. Therefore, using an Apple-generated transcript
in Listenook would require relying on an undocumented Apple-internal interface,
which is not a stable or supported integration.

The supported interoperable route is publisher-supplied captions. Apple accepts
a transcript file linked from each RSS `<item>` with
`<podcast:transcript>`; its RSS guide lists VTT and SRT as accepted timed
formats. The Podcasting 2.0 namespace likewise defines the tag as a public URL
plus MIME type, with optional language and relationship attributes. See Apple's
[RSS guide](https://help.apple.com/itc/podcasts_connect/en.lproj/itcb54353390.html)
and the [Podcasting 2.0 transcript specification](https://podcasting2.org/docs/podcast-namespace/tags/transcript).

## Why Modern Wisdom has no captions in Listenook

Apple's lookup resolves Modern Wisdom (catalog ID `1347973549`) to the
[publisher's live Megaphone feed](https://feeds.megaphone.fm/modernwisdom). A
complete scan on 2026-08-15 found 1,133 RSS `<item>` elements and zero
`<podcast:transcript>` elements. The feed also did not declare the Podcasting
2.0 namespace. Apple may still show an automatically generated transcript in
its own app, but that Apple-hosted transcript is not published through the
show's RSS feed.

This matches Listenook's current behavior:

- The [RSS parser](../../lib/data/podcast/rss_parser.dart) only creates
  transcript references from transcript elements in an episode.
- The [podcast player](../../lib/state/podcast_player.dart) returns without
  loading captions when the episode has no transcript references; otherwise it
  downloads the referenced publisher file through the
  [HTTP gateway](../../lib/data/podcast/http_podcast_gateway.dart).
- A downloaded episode with no publisher transcript is assigned to the Soniox
  acquisition path by the [app controller](../../lib/state/app_controller.dart).
  That transcript becomes available after the user sends the downloaded episode
  through Listenook's transcription workflow; ordinary streaming playback does
  not start transcription by itself.

## Product implication

The empty transcript pane is expected for Modern Wisdom under the current
architecture, not evidence that Apple's catalog lookup failed. Listenook can show
captions immediately only when a publisher exposes a timed transcript in RSS
or when Listenook already has a completed transcript. Supporting captions for
every streamed episode would require a separate Listenook transcription-on-demand
feature, not an Apple transcript download integration.
