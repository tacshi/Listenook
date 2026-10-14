import 'dart:async';

import 'package:flutter/material.dart';

import 'review_fullscreen_controller.dart';
import 'review/transcript_review_state.dart';

export 'review/highlighted_text.dart' show PlaybackHighlightedText;
export 'review/listening_widgets.dart'
    show
        BlindListeningBlur,
        SearchHighlightedText,
        SentenceNavigationControls,
        SentenceRevealButton,
        currentListeningSegmentIndex,
        sentenceNavigationTarget;
export 'review/media_pane.dart'
    show
        AudioTransport,
        PlaybackSpeedButton,
        VideoFullscreenKeyboardRegion,
        VideoTransport,
        WaveformScrubber,
        formatPlaybackRate,
        videoViewportHeight;
export 'review/seek_helpers.dart'
    show
        LatestSeekDispatcher,
        TranscriptSeekCallback,
        TranscriptSeekReason,
        TranscriptSegmentSeekCallback,
        currentTranscriptSegmentIndex,
        fullscreenTranscriptSubtitle,
        fullscreenTranscriptWordRange,
        isRepeatLoopEndCrossing,
        isRepeatLoopWrap,
        sentenceRepeatEndMs,
        sentenceRepeatRestartMs,
        sentenceRepeatStartMs,
        shouldAutoFollowPlaybackSegment,
        shouldFocusTranscriptAfterSeek,
        shouldFocusTranscriptOnPlaybackResume,
        shouldRestartRepeatedSentence;
export 'review/speaker_strip.dart' show SpeakerStrip;
export 'review/transcript_editing.dart' show TranscriptSegmentEditor;
export 'review/transcript_review_state.dart'
    show
        debugTranscriptReviewPlayerFactory,
        debugTranscriptReviewScheduleMediaFrame,
        debugTranscriptReviewSentenceRepeatLoopFactory,
        debugTranscriptReviewSourceExists;

class TranscriptReview extends StatefulWidget {
  const TranscriptReview({
    super.key,
    required this.jobId,
    this.fullscreenController,
  });
  final String jobId;
  final ReviewFullscreenController? fullscreenController;

  @override
  State<TranscriptReview> createState() => TranscriptReviewState();
}

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
