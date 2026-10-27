/// Seconds since epoch.
int epochSeconds(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

/// Seconds-since-epoch of the minute containing [time].
int minuteStart(DateTime time) {
  final seconds = epochSeconds(time);
  return seconds - seconds % 60;
}

const _binChoices = [
  60, 120, 300, 600, 900, 1800, 3600, 2 * 3600, 3 * 3600, 6 * 3600, 12 * 3600, 86400, 2 * 86400,
  7 * 86400, 14 * 86400, 30 * 86400,
];

/// The smallest "round" bucket size that splits [spanSeconds] into at most
/// [maxBins] buckets.
int pickBinSeconds(int spanSeconds, {int maxBins = 180}) {
  for (final bin in _binChoices) {
    if (spanSeconds / bin <= maxBins) return bin;
  }
  return _binChoices.last;
}
