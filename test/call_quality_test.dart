import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/data/app_database.dart';
import 'package:ir_net/data/call_quality.dart';
import 'package:ir_net/data/quality.dart';
import 'package:ir_net/data/quality_store.dart';
import 'package:ir_net/utils/call_tester.dart';
import 'package:ir_net/utils/quality_probes.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('E-model', () {
    test('delay and loss impairments match G.107 reference values', () {
      expect(EModel.delayImpairment(100), closeTo(2.4, 1e-9));
      expect(EModel.delayImpairment(200), closeTo(0.024 * 200 + 0.11 * 22.7, 1e-9));
      expect(EModel.lossImpairment(0), 0);
      expect(EModel.lossImpairment(1), closeTo(95 / 26.1, 1e-9));
      expect(EModel.lossImpairment(1, burstRatio: 2), closeTo(95 / 25.6, 1e-9),
          reason: 'bursty loss hurts more');
      expect(EModel.lossImpairment(1, bpl: 10), greaterThan(EModel.lossImpairment(1)));
    });

    test('R → MOS', () {
      expect(EModel.mosFromR(0), 1);
      expect(EModel.mosFromR(100), 4.5);
      expect(EModel.mosFromR(93.2), closeTo(4.41, 0.01));
      expect(EModel.mosFromR(80), closeTo(4.02, 0.01));
      expect(EModel.mosFromR(50), closeTo(2.58, 0.01));
    });

    test('grades follow the G.107 satisfaction bands', () {
      expect(CallQuality.gradeOfMos(4.4), QualityGrade.excellent);
      expect(CallQuality.gradeOfMos(4.1), QualityGrade.good);
      expect(CallQuality.gradeOfMos(3.7), QualityGrade.fair);
      expect(CallQuality.gradeOfMos(3.2), QualityGrade.poor);
      expect(CallQuality.gradeOfMos(2.0), QualityGrade.bad);
    });
  });

  group('call estimates', () {
    CallQuality est(CallKind k, double rtt, double jitter, double loss, [double burst = 1]) =>
        CallQuality.estimate(kind: k, rttMs: rtt, jitterMs: jitter, lossPercent: loss, burstRatio: burst);

    test('a clean VPN path is excellent for both', () {
      expect(est(CallKind.voice, 105, 5, 0).grade, QualityGrade.excellent);
      expect(est(CallKind.video, 105, 5, 0).grade, QualityGrade.excellent);
    });

    test('video suffers from loss sooner than voice', () {
      final voice = est(CallKind.voice, 105, 5, 3);
      final video = est(CallKind.video, 105, 5, 3);
      expect(voice.grade, QualityGrade.good);
      expect(video.mos, lessThan(voice.mos));
      expect(video.grade, isIn([QualityGrade.fair, QualityGrade.poor]));
    });

    test('long delay and jitter make calls poor even without loss', () {
      expect(est(CallKind.voice, 650, 80, 0).grade, isIn([QualityGrade.poor, QualityGrade.bad]));
    });

    test('estimates from background probes, with TCP fallback', () {
      final s = QualityStats();
      s.udp.addReply(100);
      s.udp.addReply(104, previous: 100);
      expect(s.call(CallKind.voice)!.viaTcp, isFalse);
      expect(s.call(CallKind.voice)!.grade, QualityGrade.excellent);

      final blocked = QualityStats();
      for (var i = 0; i < 5; i++) {
        blocked.udp.addLost();
      }
      blocked.http.addReply(180);
      expect(blocked.call(CallKind.voice)!.viaTcp, isTrue);

      final down = QualityStats()..udp.addLost();
      expect(down.call(CallKind.video)!.mos, 1);
      expect(QualityStats().call(CallKind.voice), isNull);
    });

    test('video tiers from bandwidth', () {
      expect(VideoTier.of(55, 14), VideoTier.fullHd);
      expect(VideoTier.of(55, 2), VideoTier.hd);
      expect(VideoTier.of(0.8, 5), VideoTier.sd);
      expect(VideoTier.of(0.3, 5), VideoTier.audioOnly);
    });
  });

  group('burst analysis', () {
    test('a clean call', () {
      final r = analyzeBurstForTest(List.generate(100, (i) => 100.0 + (i % 2)));
      expect(r.lossPercent, 0);
      expect(r.late, 0);
      expect(r.maxBurst, 0);
      expect(r.burstRatio, 1);
      expect(r.jitter, closeTo(1, 1e-9));
      expect(r.voice.grade, QualityGrade.excellent);
    });

    test('clustered loss is bursty and scores worse than the same loss spread out', () {
      final spread = List<double?>.generate(100, (i) => i % 20 == 0 ? null : 100.0);
      final clustered = List<double?>.generate(100, (i) => i >= 40 && i < 45 ? null : 100.0);
      final a = analyzeBurstForTest(spread);
      final b = analyzeBurstForTest(clustered);
      expect(a.lossPercent, 5);
      expect(b.lossPercent, 5);
      expect(a.maxBurst, 1);
      expect(b.maxBurst, 5);
      expect(b.burstRatio, greaterThan(4));
      expect(b.voice.mos, lessThan(a.voice.mos));
    });

    test('replies that miss the playout buffer count against the call', () {
      final rtt = List<double?>.generate(100, (i) => i % 10 == 0 ? 400.0 : 100.0);
      final r = analyzeBurstForTest(rtt);
      expect(r.lossPercent, 0);
      expect(r.late, 10);
      expect(r.voice.mos, lessThan(analyzeBurstForTest(List.filled(100, 100.0)).voice.mos));
    });

    test('no replies: UDP blocked', () {
      final r = analyzeBurstForTest(List.filled(50, null));
      expect(r.udpBlocked, isTrue);
      expect(r.voice.mos, 1);
    });
  });

  group('CallTester', () {
    late RawDatagramSocket stun;
    late HttpServer http;
    var seen = 0;
    var uploaded = 0;

    setUp(() async {
      seen = 0;
      uploaded = 0;
      stun = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      stun.listen((e) {
        final d = stun.receive();
        if (d == null) return;
        final index = seen++;
        // Drop the 21st–25th call packet (index 0 is the server pre-check).
        if (index >= 21 && index <= 25) return;
        final reply = Uint8List.fromList(d.data.sublist(0, 20))..[0] = 1..[1] = 1;
        reply[2] = 0;
        reply[3] = 0;
        stun.send(reply, d.address, d.port);
      });
      http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      http.listen((req) async {
        if (req.uri.path == '/__down') {
          req.response.add(Uint8List(int.parse(req.uri.queryParameters['bytes']!)));
        } else {
          await for (final chunk in req) {
            uploaded += chunk.length;
          }
        }
        await req.response.close();
      });
    });

    tearDown(() async {
      stun.close();
      await http.close(force: true);
    });

    CallTester tester({List<StunTarget>? targets}) => CallTester(
          targets: targets ?? [StunTarget('stun.test', stun.port)],
          lookup: (_) async => [InternetAddress.loopbackIPv4],
          packets: 80,
          spacing: const Duration(milliseconds: 5),
          lossTimeout: const Duration(milliseconds: 300),
          downloadUrl: 'http://127.0.0.1:${http.port}/__down?bytes=300000',
          uploadUrl: 'http://127.0.0.1:${http.port}/__up',
          uploadBytes: 200000,
        );

    test('simulates a call and measures bandwidth', () async {
      final progress = <CallTestPhase>[];
      final r = await tester().run(server: '203.0.113.7', onProgress: (p) => progress.add(p.phase));
      expect(r.server, '203.0.113.7');
      expect(r.sent, 80);
      expect(r.received, 75);
      expect(r.maxBurst, 5);
      expect(r.burstRatio, greaterThan(4));
      expect(r.rttMedian, lessThan(50));
      expect(r.downMbps, greaterThan(1));
      expect(r.upMbps, greaterThan(1));
      expect(uploaded, 200000);
      expect(r.tier, isNotNull);
      expect(progress.toSet(), {CallTestPhase.voice, CallTestPhase.download, CallTestPhase.upload});
      expect(r.voice.mos, greaterThan(r.video.mos));
    });

    test('skips a dead server and uses the next one', () async {
      final dead = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final r = await tester(targets: [StunTarget('dead.test', dead.port), StunTarget('live.test', stun.port)])
          .run(server: 'x');
      expect(r.received, greaterThan(70));
      dead.close();
    });

    test('when nothing answers, UDP is reported blocked', () async {
      final dead = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final r = await tester(targets: [StunTarget('dead.test', dead.port)]).run(server: 'x');
      expect(r.udpBlocked, isTrue);
      expect(r.voice.mos, 1);
      expect(r.downMbps, isNotNull, reason: 'bandwidth is still measured');
      dead.close();
    });

    test('a failed bandwidth check leaves the tier unknown', () async {
      final r = await CallTester(
        targets: [StunTarget('stun.test', stun.port)],
        lookup: (_) async => [InternetAddress.loopbackIPv4],
        packets: 10,
        spacing: const Duration(milliseconds: 5),
        lossTimeout: const Duration(milliseconds: 200),
        downloadUrl: 'http://127.0.0.1:1/__down?bytes=1',
        uploadUrl: 'http://127.0.0.1:1/__up',
        transferTimeout: const Duration(seconds: 1),
      ).run(server: 'x');
      expect(r.downMbps, isNull);
      expect(r.tier, isNull);
    });
  });

  test('call tests are stored and listed newest first', () async {
    sqfliteFfiInit();
    final db = await AppDatabase.openAt(inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final store = QualityStore(db);
    CallTestResult result(int minute, double mos) => CallTestResult(
          at: DateTime.fromMillisecondsSinceEpoch(minute * 60000),
          server: '203.0.113.7',
          sent: 400,
          received: 396,
          late: 2,
          maxBurst: 3,
          burstRatio: 1.8,
          rttMedian: 104.7,
          rttP95: 237.4,
          jitter: 4.5,
          voice: CallQuality(kind: CallKind.voice, mos: mos, rFactor: 0),
          video: CallQuality(kind: CallKind.video, mos: mos - 0.2, rFactor: 0),
          downMbps: 55.5,
          upMbps: 13.7,
        );
    await store.saveCallTest(result(1, 4.1));
    await store.saveCallTest(result(5, 4.3));
    final tests = await store.callTests();
    expect(tests.map((t) => t.voice.mos), [4.3, 4.1]);
    final t = tests.first;
    expect(t.rttP95, 237.4);
    expect(t.tier, VideoTier.fullHd);
    expect(t.video.mos, closeTo(4.1, 1e-9));
    expect(t.latePercent, 0.5);
    await store.clear();
    expect(await store.callTests(), isEmpty);
    await db.close();
  });
}
