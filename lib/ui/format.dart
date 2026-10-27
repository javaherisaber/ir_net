/// Display formatting shared by the quality and usage dashboards.
library;

const _units = ['B', 'KB', 'MB', 'GB', 'TB'];

/// 1024-based, three significant digits: "812 B", "4.27 MB", "12.4 GB".
String formatBytes(num bytes) {
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < _units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) return '${value.round()} B';
  final digits = value < 10 ? 2 : (value < 100 ? 1 : 0);
  return '${value.toStringAsFixed(digits)} ${_units[unit]}';
}

/// Axis-tick variant: "20 MB" rather than "20.0 MB".
String formatBytesTick(num bytes) {
  final text = formatBytes(bytes);
  return text.replaceFirst(RegExp(r'\.0+ '), ' ');
}

/// Number and unit separately, for big figures with a small unit label.
(String, String) formatBytesParts(num bytes) {
  final text = formatBytes(bytes);
  final space = text.lastIndexOf(' ');
  return (text.substring(0, space), text.substring(space + 1));
}

String formatMs(double? ms) {
  if (ms == null) return '—';
  return ms < 10 ? '${ms.toStringAsFixed(1)} ms' : '${ms.round()} ms';
}

String formatPercent(double? value, {int digits = 1}) {
  if (value == null) return '—';
  if (value > 0 && value < 0.1 && digits <= 1) return '<0.1%';
  return '${value.toStringAsFixed(digits)}%';
}

/// "45s", "12m", "3h 20m", "2d 4h".
String formatDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) {
    final m = d.inMinutes % 60;
    return m == 0 ? '${d.inHours}h' : '${d.inHours}h ${m}m';
  }
  final h = d.inHours % 24;
  return h == 0 ? '${d.inDays}d' : '${d.inDays}d ${h}h';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _two(int v) => v.toString().padLeft(2, '0');

DateTime _local(num epochSeconds) =>
    DateTime.fromMillisecondsSinceEpoch((epochSeconds * 1000).round());

/// "14:05" (local time).
String formatClock(num epochSeconds, {bool seconds = false}) {
  final t = _local(epochSeconds);
  return seconds ? '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}' : '${_two(t.hour)}:${_two(t.minute)}';
}

/// "Oct 26".
String formatDay(num epochSeconds) {
  final t = _local(epochSeconds);
  return '${_months[t.month - 1]} ${t.day}';
}

/// "Oct 26, 14:05".
String formatDayClock(num epochSeconds) => '${formatDay(epochSeconds)}, ${formatClock(epochSeconds)}';

/// Label for a time bucket of [binSeconds], e.g. "14:00–15:00" or "Oct 26".
String formatBin(num start, int binSeconds) {
  if (binSeconds >= 86400) {
    return binSeconds == 86400 ? formatDay(start) : '${formatDay(start)} – ${formatDay(start + binSeconds - 1)}';
  }
  final end = start + binSeconds;
  final day = _local(start);
  final today = DateTime.now();
  final sameDay = day.year == today.year && day.month == today.month && day.day == today.day;
  final prefix = sameDay ? '' : '${formatDay(start)}, ';
  return '$prefix${formatClock(start)}–${formatClock(end)}';
}
