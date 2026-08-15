import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/podcast/podcast_formatters.dart';
import '../l10n/strings.dart';
import '../state/podcast_controller.dart';
import '../state/podcast_player.dart';
import 'podcast_now_playing.dart';
import 'podcast_page.dart';

class PodcastMiniBar extends StatelessWidget {
  const PodcastMiniBar({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PodcastController>().playback;
    final episode = player.episode;
    if (episode == null) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme;
    return Material(
      color: color.surfaceContainerHigh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: PodcastSeekBar(
              position: player.position,
              duration: player.duration,
              onSeek: player.seek,
              compact: true,
              positionKey: const Key('podcast-mini-position'),
              durationKey: const Key('podcast-mini-duration'),
              seekKey: const Key('podcast-mini-seek'),
            ),
          ),
          SizedBox(
            height: 60,
            child: InkWell(
              onTap: player.expand,
              hoverColor: color.onSurface.withValues(alpha: 0.06),
              highlightColor: color.onSurface.withValues(alpha: 0.08),
              splashColor: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    PodcastArtwork(
                      key: const Key('podcast-mini-artwork'),
                      url: player.artworkUrl,
                      size: 44,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            episode.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          if (player.feed?.title != null)
                            Text(
                              player.feed!.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    PodcastMiniSpeedButton(
                      rate: player.rate,
                      onChanged: player.setRate,
                    ),
                    IconButton(
                      key: const Key('podcast-mini-toggle'),
                      tooltip: context.strings.t(
                        player.playing ? 'pause' : 'play',
                      ),
                      style: IconButton.styleFrom(
                        hoverColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                      ),
                      onPressed: player.toggle,
                      icon: Icon(
                        player.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                    IconButton(
                      key: const Key('podcast-mini-close'),
                      tooltip: context.strings.t('close'),
                      style: IconButton.styleFrom(
                        hoverColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                      ),
                      onPressed: player.stop,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PodcastMiniSpeedButton extends StatelessWidget {
  const PodcastMiniSpeedButton({
    super.key,
    required this.rate,
    required this.onChanged,
  });

  final double rate;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<double>(
    key: const Key('podcast-mini-speed'),
    tooltip: context.strings.t('podcast_playback_speed'),
    initialValue: rate,
    position: PopupMenuPosition.under,
    onSelected: onChanged,
    itemBuilder: (context) => [
      for (final value in PodcastPlayer.rates)
        CheckedPopupMenuItem<double>(
          key: ValueKey('podcast-mini-speed-${(value * 100).round()}'),
          value: value,
          checked: (value - rate).abs() < 0.001,
          child: Text(formatPodcastRate(value)),
        ),
    ],
    child: SizedBox(
      width: 44,
      height: 44,
      child: Center(
        child: Text(
          formatPodcastRate(rate),
          key: const Key('podcast-mini-speed-label'),
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    ),
  );
}
