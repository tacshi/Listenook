import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/dictation_comparison.dart';
import '../l10n/strings.dart';

class DictationPanel extends StatelessWidget {
  const DictationPanel({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.targetLabel,
    required this.eligible,
    required this.result,
    required this.onChanged,
    required this.onCheck,
    required this.onReplay,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String? targetLabel;
  final bool eligible;
  final DictationResult? result;
  final ValueChanged<String> onChanged;
  final VoidCallback? onCheck;
  final VoidCallback? onReplay;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final theme = Theme.of(context);
    final shortcutModifier = theme.platform == TargetPlatform.macOS
        ? '⌘'
        : 'Ctrl+';
    final matches = result?.matches == true;
    final feedbackLabel = strings.t(
      matches ? 'dictation_matches' : 'dictation_retry',
    );
    void check() {
      if (!controller.value.composing.isValid ||
          controller.value.composing.isCollapsed) {
        onCheck?.call();
      }
    }

    return Material(
      key: const Key('dictation-panel'),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      targetLabel ?? strings.t('dictation_select_sentence'),
                    ),
                  ),
                  IconButton(
                    key: const Key('close-dictation'),
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
              if (targetLabel != null) ...[
                CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                        check,
                    const SingleActivator(
                      LogicalKeyboardKey.enter,
                      control: true,
                    ): check,
                  },
                  child: _DictationAnswerShake(
                    result: result,
                    target: targetLabel,
                    child: Stack(
                      children: [
                        TextField(
                          key: const Key('dictation-answer'),
                          controller: controller,
                          focusNode: focusNode,
                          minLines: 2,
                          maxLines: 4,
                          autocorrect: false,
                          enableSuggestions: false,
                          textCapitalization: TextCapitalization.none,
                          decoration: InputDecoration(
                            hintText: strings.t('dictation_prompt'),
                            contentPadding: const EdgeInsets.fromLTRB(
                              12,
                              12,
                              44,
                              12,
                            ),
                          ),
                          onChanged: onChanged,
                        ),
                        if (result != null)
                          Positioned(
                            top: 12,
                            right: 12,
                            child: Tooltip(
                              message: feedbackLabel,
                              excludeFromSemantics: true,
                              child: Icon(
                                matches
                                    ? Icons.check_rounded
                                    : Icons.close_rounded,
                                key: Key(
                                  matches
                                      ? 'dictation-correct'
                                      : 'dictation-retry',
                                ),
                                semanticLabel: feedbackLabel,
                                color: !matches
                                    ? Theme.of(context).colorScheme.error
                                    : Theme.of(context).brightness ==
                                          Brightness.dark
                                    ? Colors.green.shade300
                                    : Colors.green.shade800,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (result != null && !matches)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _DictationDiff(words: result!.words),
                  ),
                if (!eligible) Text(strings.t('dictation_english_only')),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton.icon(
                      key: const Key('dictation-replay'),
                      onPressed: onReplay,
                      icon: const Icon(Icons.replay),
                      label: Text(strings.t('dictation_replay')),
                    ),
                    Tooltip(
                      message:
                          '${strings.t('dictation_check')} ($shortcutModifier↩)',
                      child: FilledButton(
                        key: const Key('dictation-check'),
                        onPressed: onCheck == null ? null : check,
                        child: Text(strings.t('dictation_check')),
                      ),
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
}

/// Renders the answer as a word diff. Expected words are never shown: wrong
/// words are underlined, missed words become '…', extra words are struck out.
class _DictationDiff extends StatelessWidget {
  const _DictationDiff({required this.words});
  final List<DictationWord> words;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium;
    final error = theme.colorScheme.error;
    final spans = <TextSpan>[];
    for (final word in words) {
      if (spans.isNotEmpty) spans.add(const TextSpan(text: ' '));
      spans.add(switch (word.kind) {
        DictationWordKind.matching => TextSpan(text: word.actual),
        DictationWordKind.different => TextSpan(
          text: word.actual,
          style: TextStyle(
            color: error,
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.wavy,
            decorationColor: error,
          ),
        ),
        DictationWordKind.missing => TextSpan(
          text: '…',
          style: TextStyle(color: error, fontWeight: FontWeight.bold),
        ),
        DictationWordKind.extra => TextSpan(
          text: word.actual,
          style: TextStyle(
            color: error,
            decoration: TextDecoration.lineThrough,
            decorationColor: error,
          ),
        ),
      });
    }
    return Text.rich(
      TextSpan(style: base, children: spans),
      key: const Key('dictation-diff'),
    );
  }
}

class _DictationAnswerShake extends StatefulWidget {
  const _DictationAnswerShake({
    required this.result,
    required this.target,
    required this.child,
  });
  final DictationResult? result;
  final String? target;
  final Widget child;

  @override
  State<_DictationAnswerShake> createState() => _DictationAnswerShakeState();
}

class _DictationAnswerShakeState extends State<_DictationAnswerShake>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );

  @override
  void didUpdateWidget(covariant _DictationAnswerShake oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.target != oldWidget.target ||
        widget.result == null ||
        widget.result!.matches) {
      _animation.reset();
    } else if (!identical(widget.result, oldWidget.result) &&
        !MediaQuery.disableAnimationsOf(context)) {
      _animation.forward(from: 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _animation.reset();
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _animation,
    child: widget.child,
    builder: (context, child) {
      final t = _animation.value;
      return Transform.translate(
        key: const Key('dictation-answer-shake'),
        offset: Offset(5 * math.sin(t * math.pi * 6) * (1 - t), 0),
        child: child,
      );
    },
  );
}
