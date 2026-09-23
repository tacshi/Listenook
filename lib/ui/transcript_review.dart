import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:window_manager/window_manager.dart';

import '../core/dictation_comparison.dart';
import '../core/models.dart';
import '../core/transcript_structure_editor.dart';
import '../data/transcript_exporter.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';
import 'app_notice.dart';
import 'dictation_panel.dart';
import 'job_actions.dart';
import 'keyboard_shortcuts.dart';
import 'review_fullscreen_controller.dart';
import 'transcript_export_dialog.dart';
import 'transcript_structure_cursor.dart';

part 'review/ai_brief_pane.dart';
part 'review/highlighted_text.dart';
part 'review/listening_widgets.dart';
part 'review/media_pane.dart';
part 'review/review_scaffold.dart';
part 'review/review_toolbar.dart';
part 'review/seek_helpers.dart';
part 'review/speaker_strip.dart';
part 'review/transcript_editing.dart';
part 'review/transcript_review_state.dart';
part 'review/transcript_segments.dart';

class TranscriptReview extends StatefulWidget {
  const TranscriptReview({
    super.key,
    required this.jobId,
    this.fullscreenController,
  });
  final String jobId;
  final ReviewFullscreenController? fullscreenController;

  @override
  State<TranscriptReview> createState() => _TranscriptReviewState();
}

enum _ReviewMediaMode { video, audio }

@visibleForTesting
Player Function()? debugTranscriptReviewPlayerFactory;

@visibleForTesting
Future<bool> Function(String path)? debugTranscriptReviewSourceExists;

@visibleForTesting
VoidCallback? debugTranscriptReviewScheduleMediaFrame;

@visibleForTesting
SentenceRepeatLoopController? Function(Player player)?
debugTranscriptReviewSentenceRepeatLoopFactory;

abstract interface class SentenceRepeatLoopController {
  Future<void> setRange({required int startMs, required int endMs});

  Future<void> clear();
}

class MpvSentenceRepeatLoopController implements SentenceRepeatLoopController {
  MpvSentenceRepeatLoopController(this._setProperty);

  final Future<void> Function(String property, String value) _setProperty;
  Future<void> _pending = Future<void>.value();

  @override
  Future<void> setRange({required int startMs, required int endMs}) =>
      _enqueue(() async {
        await _setProperty('ab-loop-b', 'no');
        await _setProperty('ab-loop-count', 'inf');
        await _setProperty('ab-loop-a', _mpvTimestamp(startMs));
        await _setProperty('ab-loop-b', _mpvTimestamp(endMs));
      });

  @override
  Future<void> clear() => _enqueue(() async {
    await _setProperty('ab-loop-b', 'no');
    await _setProperty('ab-loop-a', 'no');
  });

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _pending.then(
      (_) => operation(),
      onError: (_, _) => operation(),
    );
    _pending = result;
    return result;
  }

  static String _mpvTimestamp(int milliseconds) =>
      (milliseconds / 1000).toStringAsFixed(3);
}

SentenceRepeatLoopController? _mpvSentenceRepeatLoopFor(Player player) {
  final platform = player.platform;
  if (platform is! NativePlayer) return null;
  return MpvSentenceRepeatLoopController(platform.setProperty);
}

class _ReviewPlaybackTick extends ChangeNotifier {
  void tick() => notifyListeners();
}

class _DictationAttempt {
  _DictationAttempt(this.reference);
  String reference;
  String draft = '';
  DictationResult? result;
}

