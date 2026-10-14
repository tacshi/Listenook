import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../l10n/strings.dart';
import '../../state/app_controller.dart';

const _speakerHues = <double>[270, 210, 155, 25, 335, 185];

Color colorForSpeaker(BuildContext context, String speakerId) {
  final numericId = int.tryParse(speakerId);
  var seed = numericId == null ? 0 : numericId - 1;
  if (numericId == null) {
    for (final codeUnit in speakerId.codeUnits) {
      seed = (seed * 31 + codeUnit) & 0x7fffffff;
    }
  }
  final index =
      ((seed % _speakerHues.length) + _speakerHues.length) %
      _speakerHues.length;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return HSLColor.fromAHSL(
    1,
    _speakerHues[index],
    dark ? .66 : .68,
    dark ? .72 : .4,
  ).toColor();
}

Color _onSpeakerColor(Color color) =>
    ThemeData.estimateBrightnessForColor(color) == Brightness.dark
    ? Colors.white
    : Colors.black;

class SpeakerStrip extends StatefulWidget {
  const SpeakerStrip({super.key, required this.job, required this.document});
  final TranscriptionJob job;
  final TranscriptDocument document;

  @override
  State<SpeakerStrip> createState() => _SpeakerStripState();
}

class _SpeakerStripState extends State<SpeakerStrip> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: (event) {
      if (event is! PointerScrollEvent ||
          event.scrollDelta.dx != 0 ||
          !_scroll.hasClients) {
        return;
      }
      final position = _scroll.position;
      _scroll.jumpTo(
        (position.pixels + event.scrollDelta.dy).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    },
    child: SizedBox(
      height: 56,
      child: Scrollbar(
        controller: _scroll,
        scrollbarOrientation: ScrollbarOrientation.bottom,
        interactive: true,
        child: ListView.separated(
          key: const Key('speaker-strip-scroll'),
          controller: _scroll,
          primary: false,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          scrollDirection: Axis.horizontal,
          itemCount: widget.document.speakers.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final speaker = widget.document.speakers[index];
            final speakerColor = colorForSpeaker(context, speaker.id);
            return ActionChip(
              avatarBoxConstraints: const BoxConstraints.tightFor(
                width: 18,
                height: 18,
              ),
              avatar: Container(
                key: ValueKey('speaker-avatar-${speaker.id}'),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: speakerColor,
                ),
                child: Text(
                  '${index + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _onSpeakerColor(speakerColor),
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
              label: Text(
                context.strings.speakerName(speaker.name),
                style: TextStyle(
                  color: speakerColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onPressed: () => _rename(context, speaker),
            );
          },
        ),
      ),
    ),
  );

  Future<void> _rename(BuildContext context, SpeakerProfile speaker) async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => _RenameSpeakerDialog(
        initialValue: context.strings.speakerName(speaker.name),
      ),
    );
    if (value != null && value.trim().isNotEmpty && context.mounted) {
      await context.read<AppController>().renameSpeaker(
        widget.job.id,
        speaker.id,
        value,
      );
    }
  }
}

class _RenameSpeakerDialog extends StatefulWidget {
  const _RenameSpeakerDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_RenameSpeakerDialog> createState() => _RenameSpeakerDialogState();
}

class _RenameSpeakerDialogState extends State<_RenameSpeakerDialog> {
  late final TextEditingController _field;

  @override
  void initState() {
    super.initState();
    _field = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_field.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.strings.t('rename_speaker')),
    content: TextField(
      key: const Key('speaker-name-field'),
      controller: _field,
      autofocus: true,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.strings.t('cancel')),
      ),
      FilledButton(
        key: const Key('save-speaker-name'),
        onPressed: _submit,
        child: Text(context.strings.t('save')),
      ),
    ],
  );
}
