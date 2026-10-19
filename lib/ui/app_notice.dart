import 'dart:async';

import 'package:material_ui/material_ui.dart';

enum AppNoticeTone { success, info, error }

const appNoticeDuration = Duration(seconds: 4);

OverlayEntry? _activeNotice;

void dismissAppNotice() {
  final notice = _activeNotice;
  _activeNotice = null;
  if (notice?.mounted == true) notice!.remove();
}

void showAppNotice(
  BuildContext context, {
  required String message,
  AppNoticeTone tone = AppNoticeTone.info,
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = appNoticeDuration,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  dismissAppNotice();
  late final OverlayEntry notice;

  void dismiss() {
    if (!identical(_activeNotice, notice)) return;
    dismissAppNotice();
  }

  notice = OverlayEntry(
    builder: (context) => Positioned(
      left: 16,
      right: 16,
      bottom: 16,
      child: SafeArea(
        top: false,
        left: false,
        right: false,
        child: Align(
          alignment: Alignment.bottomRight,
          child: TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            tween: Tween(begin: .96, end: 1),
            builder: (context, value, child) => Transform.scale(
              scale: value,
              alignment: Alignment.bottomRight,
              child: child,
            ),
            child: _TimedAppNotice(
              duration: duration,
              onElapsed: dismiss,
              child: AppNoticeSurface(
                key: const Key('app-notice'),
                message: message,
                tone: tone,
                actionLabel: actionLabel,
                onAction: onAction == null
                    ? null
                    : () {
                        dismiss();
                        onAction();
                      },
                onDismiss: dismiss,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  _activeNotice = notice;
  overlay.insert(notice);
}

class _TimedAppNotice extends StatefulWidget {
  const _TimedAppNotice({
    required this.duration,
    required this.onElapsed,
    required this.child,
  });

  final Duration duration;
  final VoidCallback onElapsed;
  final Widget child;

  @override
  State<_TimedAppNotice> createState() => _TimedAppNoticeState();
}

class _TimedAppNoticeState extends State<_TimedAppNotice> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, widget.onElapsed);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class AppNoticeSurface extends StatelessWidget {
  const AppNoticeSurface({
    super.key,
    required this.message,
    required this.onDismiss,
    this.tone = AppNoticeTone.info,
    this.actionLabel,
    this.onAction,
    this.actionKey,
    this.dismissKey,
  });

  final String message;
  final AppNoticeTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onDismiss;
  final Key? actionKey;
  final Key? dismissKey;

  IconData get _icon => switch (tone) {
    AppNoticeTone.success => Icons.check_circle_outline_rounded,
    AppNoticeTone.info => Icons.info_outline_rounded,
    AppNoticeTone.error => Icons.error_outline_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      container: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Material(
          elevation: 6,
          color: colors.inverseSurface,
          shadowColor: Colors.black.withValues(alpha: .22),
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_icon, size: 18, color: colors.onInverseSurface),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onInverseSurface,
                    ),
                  ),
                ),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    key: actionKey,
                    onPressed: onAction,
                    style: TextButton.styleFrom(
                      foregroundColor: colors.inversePrimary,
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(actionLabel!),
                  ),
                ],
                IconButton(
                  key: dismissKey,
                  onPressed: onDismiss,
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  color: colors.onInverseSurface.withValues(alpha: .76),
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
