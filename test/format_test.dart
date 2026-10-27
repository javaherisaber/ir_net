import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/ui/charts.dart';
import 'package:ir_net/ui/format.dart';
import 'package:ir_net/utils/time_utils.dart';

void main() {
  test('byte sizes use 1024 units and three significant digits', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(812), '812 B');
    expect(formatBytes(1536), '1.50 KB');
    expect(formatBytes(4.27 * 1024 * 1024), '4.27 MB');
    expect(formatBytes(12.4 * 1024 * 1024 * 1024), '12.4 GB');
    expect(formatBytes(512 * 1024 * 1024), '512 MB');
    expect(formatBytesParts(1.84 * 1024 * 1024 * 1024), ('1.84', 'GB'));
    expect(formatBytesTick(20 * 1024 * 1024), '20 MB');
    expect(formatBytesTick(2.5 * 1024 * 1024), '2.50 MB');
  });

  test('percent, milliseconds and durations', () {
    expect(formatPercent(null), '—');
    expect(formatPercent(0), '0.0%');
    expect(formatPercent(0.05), '<0.1%');
    expect(formatPercent(12.345), '12.3%');
    expect(formatMs(4.25), '4.3 ms');
    expect(formatMs(104.6), '105 ms');
    expect(formatDuration(const Duration(seconds: 45)), '45s');
    expect(formatDuration(const Duration(minutes: 12)), '12m');
    expect(formatDuration(const Duration(hours: 3, minutes: 20)), '3h 20m');
    expect(formatDuration(const Duration(days: 2, hours: 4)), '2d 4h');
  });

  test('scale tops are round and close above the data', () {
    expect(niceCeil(0), 1);
    expect(niceCeil(281), 300);
    expect(niceCeil(96), 100);
    expect(niceCeil(1100), 1200);
    expect(niceCeil(4.2), 5);
    expect(niceBytes(85 * 1024 * 1024), 100 * 1024 * 1024);
    expect(niceBytes(900), 1000);
    expect(niceBytes(1.3 * 1024 * 1024 * 1024), 1.5 * 1024 * 1024 * 1024);
  });

  test('time ticks are aligned to local time and at least a minute apart', () {
    // Iran: UTC+03:30, so hours start at :30 UTC.
    const offset = 3 * 3600 + 1800;
    final from = DateTime.utc(2026, 10, 26, 0, 10).millisecondsSinceEpoch / 1000;
    final to = from + 6 * 3600;
    final ticks = timeTicks(from, to, 600, offset);
    expect(ticks.step, 3600);
    for (final t in ticks.times) {
      expect((t + offset) % 3600, 0);
      expect(t, inInclusiveRange(from, to));
    }
    final live = timeTicks(0, 300, 2000, 0);
    expect(live.step, greaterThanOrEqualTo(60), reason: 'labels are HH:mm');
  });

  test('history bin sizes keep the bucket count bounded', () {
    expect(pickBinSeconds(3600, maxBins: 150), 60);
    expect(pickBinSeconds(24 * 3600, maxBins: 150), 600);
    expect(pickBinSeconds(30 * 86400, maxBins: 150), 6 * 3600);
    expect(pickBinSeconds(400 * 86400, maxBins: 60), 7 * 86400);
    expect(minuteStart(DateTime.utc(2026, 10, 26, 10, 3, 59)),
        DateTime.utc(2026, 10, 26, 10, 3).millisecondsSinceEpoch ~/ 1000);
  });
}
