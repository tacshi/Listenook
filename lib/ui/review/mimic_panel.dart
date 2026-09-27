part of '../transcript_review.dart';

class _MimicPanel extends StatelessWidget {
  const _MimicPanel({
    required this.targetLabel,
    required this.text,
    required this.translation,
    required this.blindListening,
    required this.revealed,
    required this.onReveal,
    required this.looping,
    required this.onToggleLoop,
    required this.reps,
    required this.repGoal,
    required this.onRepGoalChanged,
    required this.pauseSeconds,
    required this.onPauseSecondsChanged,
    required this.onResetReps,
    required this.playbackRate,
    required this.onPlaybackRateChanged,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
  });

  final String? targetLabel;
  final String? text;
  final String? translation;
  final bool blindListening;
  final bool revealed;
  final VoidCallback? onReveal;
  final bool looping;
  final VoidCallback? onToggleLoop;
  final int reps;
  final int repGoal;
  final Future<void> Function(int goal) onRepGoalChanged;
  final int pauseSeconds;
  final Future<void> Function(int seconds) onPauseSecondsChanged;
  final VoidCallback? onResetReps;
  final double playbackRate;
  final Future<void> Function(double rate) onPlaybackRateChanged;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final theme = Theme.of(context);
    final trimmedTranslation = translation?.trim() ?? '';
    return Material(
      key: const Key('mimic-panel'),
      color: theme.colorScheme.surfaceContainerLow,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context),
              if (targetLabel != null) ...[
                if (trimmedTranslation.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      trimmedTranslation,
                      key: const Key('mimic-translation'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: BlindListeningBlur(
                    blurred: blindListening && !revealed,
                    onHiddenTap: onReveal,
                    child: Text(
                      text ?? '',
                      key: const Key('mimic-text'),
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    IconButton(
                      key: const Key('mimic-previous'),
                      tooltip: strings.t('previous_sentence'),
                      onPressed: onPrevious,
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.skip_previous_rounded),
                    ),
                    IconButton(
                      key: const Key('mimic-loop-toggle'),
                      tooltip: strings.t(
                        looping ? 'mimic_pause_loop' : 'mimic_loop',
                      ),
                      isSelected: looping,
                      onPressed: onToggleLoop,
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        looping
                            ? Icons.pause_circle_outline_rounded
                            : Icons.play_circle_outline_rounded,
                      ),
                    ),
                    IconButton(
                      key: const Key('mimic-next'),
                      tooltip: strings.t('next_sentence'),
                      onPressed: onNext,
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                    if (blindListening)
                      IconButton(
                        key: const Key('mimic-reveal'),
                        tooltip: strings.t('reveal_current_sentence'),
                        isSelected: revealed,
                        onPressed: onReveal,
                        constraints: const BoxConstraints.tightFor(
                          width: 40,
                          height: 40,
                        ),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          revealed
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                        ),
                      ),
                    PlaybackSpeedButton(
                      rate: playbackRate,
                      onChanged: onPlaybackRateChanged,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final strings = context.strings;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 480;
        final settings = targetLabel == null
            ? const <Widget>[]
            : <Widget>[_repGoalButton(context), _pauseButton(context)];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    targetLabel ?? strings.t('mimic_select_sentence'),
                  ),
                ),
                if (!compact) ...settings,
                if (targetLabel != null)
                  IconButton(
                    key: const Key('mimic-reset-reps'),
                    tooltip: strings.t('mimic_reset_reps'),
                    onPressed: onResetReps,
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 40,
                    ),
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.restart_alt_rounded),
                  ),
                IconButton(
                  key: const Key('close-mimic'),
                  tooltip: strings.t('close'),
                  onPressed: onClose,
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 40,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (compact && settings.isNotEmpty) Wrap(children: settings),
          ],
        );
      },
    );
  }

  Widget _repGoalButton(BuildContext context) {
    final strings = context.strings;
    final theme = Theme.of(context);
    return PopupMenuButton<int>(
      key: const Key('mimic-rep-goal'),
      tooltip: strings.t('mimic_rep_goal'),
      initialValue: repGoal,
      onSelected: (value) => unawaited(onRepGoalChanged(value)),
      itemBuilder: (context) => [
        for (final goal in [1, 2, 3, 5, 10, 20, 30])
          CheckedPopupMenuItem<int>(
            key: ValueKey('mimic-rep-goal-$goal'),
            value: goal,
            checked: goal == repGoal,
            child: Text('$goal'),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${strings.t('mimic_reps')} $reps/$repGoal',
              key: const Key('mimic-rep-count'),
              style: theme.textTheme.labelLarge,
            ),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _pauseButton(BuildContext context) {
    final strings = context.strings;
    String label(int seconds) => seconds == 0
        ? strings.t('mimic_pause_auto')
        : strings.t('mimic_pause_seconds').replaceAll('{seconds}', '$seconds');
    return PopupMenuButton<int>(
      key: const Key('mimic-pause'),
      tooltip: strings.t('mimic_pause'),
      initialValue: pauseSeconds,
      onSelected: (value) => unawaited(onPauseSecondsChanged(value)),
      itemBuilder: (context) => [
        for (final seconds in [0, 1, 2, 3, 5, 10])
          CheckedPopupMenuItem<int>(
            key: ValueKey('mimic-pause-$seconds'),
            value: seconds,
            checked: seconds == pauseSeconds,
            child: Text(
              seconds == 0
                  ? strings.t('mimic_pause_auto_option')
                  : label(seconds),
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${strings.t('mimic_pause')} ${label(pauseSeconds)}',
              key: const Key('mimic-pause-label'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }
}
