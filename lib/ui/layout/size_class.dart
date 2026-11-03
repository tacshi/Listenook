import 'package:material_ui/material_ui.dart';

/// Window width classes. Desktop windows never go below 920 points, so
/// compact and medium only occur on iPhone and in iPad Split View, Slide Over
/// and Stage Manager.
enum LayoutSize {
  /// Under 600: phones, and a third of an iPad screen.
  compact,

  /// 600–839: landscape phones, half an iPad screen, iPad mini portrait.
  medium,

  /// 840–1179: iPad portrait and landscape, small desktop windows.
  expanded,

  /// 1180 and up.
  wide;

  static LayoutSize forWidth(double width) => width < 600
      ? compact
      : width < 840
      ? medium
      : width < 1180
      ? expanded
      : wide;

  static LayoutSize of(BuildContext context) =>
      forWidth(MediaQuery.sizeOf(context).width);

  bool get isCompact => this == compact;
  bool operator >=(LayoutSize other) => index >= other.index;
  bool operator <(LayoutSize other) => index < other.index;
}
