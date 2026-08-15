String? formatEpisodeLength(int? milliseconds, {required bool chinese}) {
  if (milliseconds == null || milliseconds <= 0) return null;
  final totalSeconds = (milliseconds / 1000).round();
  if (totalSeconds <= 0) return null;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (chinese) {
    if (hours > 0 && minutes > 0) return '$hours小时$minutes分';
    if (hours > 0) return '$hours小时';
    if (minutes > 0) return '$minutes分钟';
    return '$seconds秒';
  }
  if (hours > 0 && minutes > 0) return '${hours}h ${minutes}m';
  if (hours > 0) return '${hours}h';
  if (minutes > 0) return '${minutes}m';
  return '${seconds}s';
}

String formatPodcastRate(double rate) {
  final fixed = rate.toStringAsFixed(2);
  final value = fixed.endsWith('00')
      ? fixed.substring(0, fixed.length - 3)
      : fixed.endsWith('0')
      ? fixed.substring(0, fixed.length - 1)
      : fixed;
  return '$value×';
}
