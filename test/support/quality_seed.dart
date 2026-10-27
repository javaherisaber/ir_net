// Shared test fixtures: a realistic day of network-quality history.

import 'dart:math';

import 'package:ir_net/data/call_quality.dart';
import 'package:ir_net/data/quality.dart';
import 'package:ir_net/data/quality_store.dart';
import 'package:ir_net/utils/call_tester.dart';
import 'package:ir_net/utils/quality_probes.dart';
import 'package:ir_net/utils/time_utils.dart';

class ScriptedProber implements RttProber {
  ScriptedProber(this.next);
  final double? Function(int call) next;
  int _calls = 0;

  @override
  Future<double?> probe() async => next(_calls++);

  @override
  void reset() {}

  @override
  void close() {}
}

CallTestResult callResult(String server, DateTime at,
        {double rtt = 104, double loss = 0.5, double down = 48, double up = 14}) =>
    CallTestResult(
      at: at,
      server: server,
      sent: 400,
      received: (400 * (1 - loss / 100)).round(),
      late: 1,
      maxBurst: 2,
      burstRatio: 1.4,
      rttMedian: rtt,
      rttP95: rtt * 1.6,
      jitter: 6,
      voice: CallQuality.estimate(kind: CallKind.voice, rttMs: rtt, jitterMs: 6, lossPercent: loss),
      video: CallQuality.estimate(kind: CallKind.video, rttMs: rtt, jitterMs: 6, lossPercent: loss),
      downMbps: down,
      upMbps: up,
    );

class InstantCallTester extends CallTester {
  @override
  Future<CallTestResult> run({required String server, void Function(CallTestProgress)? onProgress}) async {
    onProgress?.call(const CallTestProgress(CallTestPhase.voice, 0.4));
    return callResult(server, DateTime.now());
  }
}

/// A day of minutes for three exit servers: a good one, the current one and
/// a lossy one, with an outage.
Future<void> seedQuality(QualityStore store, DateTime now) async {
  final rnd = Random(7);
  final servers = [
    const ServerInfo(
        ip: '185.220.101.12',
        country: 'Germany',
        countryCode: 'DE',
        region: 'Hesse',
        city: 'Frankfurt am Main',
        isp: 'Hetzner Online GmbH'),
    const ServerInfo(
        ip: '45.86.200.5',
        country: 'Turkey',
        countryCode: 'TR',
        region: 'Istanbul',
        city: 'Istanbul',
        isp: 'Turk Telekom'),
    const ServerInfo(
        ip: '172.233.41.190',
        country: 'The Netherlands',
        countryCode: 'NL',
        region: 'North Holland',
        city: 'Amsterdam',
        isp: 'Akamai Technologies, Inc.'),
  ];
  for (final s in servers) {
    await store.touchServer(s, now);
  }
  await store.setLabel('185.220.101.12', 'Hetzner DE #2');
  final end = minuteStart(now);
  final windows = <QualityWindow>[];
  for (var m = 24 * 60; m > 2; m--) {
    final ts = end - m * 60;
    final phase = m > 16 * 60 ? 0 : (m > 8 * 60 ? 1 : 2);
    final (base, spread, loss) =
        switch (phase) { 0 => (78.0, 6.0, 0.003), 1 => (235.0, 70.0, 0.08), _ => (104.0, 18.0, 0.015) };
    final outage = phase == 1 && m % 180 < 4;
    final w = QualityWindow(ts, servers[phase].ip)..ticks = 30;
    double? prev;
    for (var i = 0; i < 30; i++) {
      if (outage || rnd.nextDouble() < loss) {
        w.udp.addLost();
        if (outage) w.downTicks++;
        continue;
      }
      final rtt = base + rnd.nextDouble() * spread + (rnd.nextDouble() < 0.03 ? spread * 3 : 0);
      w.udp.addReply(rtt, previous: prev);
      prev = rtt;
    }
    for (var i = 0; i < 6; i++) {
      if (outage) {
        w.http.addLost();
      } else {
        w.http.addReply(base * 1.15 + rnd.nextDouble() * spread);
      }
    }
    windows.add(w);
  }
  await store.saveWindows(windows);
  await store.saveCallTest(callResult('185.220.101.12', now.subtract(const Duration(hours: 18)), rtt: 78, loss: 0.2));
  await store.saveCallTest(
      callResult('45.86.200.5', now.subtract(const Duration(hours: 10)), rtt: 236, loss: 7, down: 4, up: 0.9));
}
