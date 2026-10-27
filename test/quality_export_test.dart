// The network-quality export: the report snapshot taken from the controller,
// its findings, the text summary, the CSV/ZIP files and the PDF report.
//
// Set IRNET_REPORTS=/some/dir to also keep the generated PDF and ZIP:
//   IRNET_REPORTS=/tmp/reports flutter test test/quality_export_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/data/app_database.dart';
import 'package:ir_net/data/quality.dart';
import 'package:ir_net/data/quality_report.dart';
import 'package:ir_net/data/quality_store.dart';
import 'package:ir_net/data/shared_preferences.dart';
import 'package:ir_net/quality_bloc.dart';
import 'package:ir_net/utils/file_delivery.dart';
import 'package:ir_net/utils/quality_export.dart';
import 'package:ir_net/utils/quality_monitor.dart';
import 'package:ir_net/utils/quality_report_pdf.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/quality_seed.dart';

const amsterdam = {
  'query': '172.233.41.190',
  'country': 'The Netherlands',
  'countryCode': 'NL',
  'regionName': 'North Holland',
  'city': 'Amsterdam',
  'isp': 'Akamai Technologies, Inc.',
};

/// Pages in a PDF: page objects are plain dictionaries even when content
/// streams are compressed.
int pageCount(Uint8List pdf) => RegExp(r'/Type\s*/Page[^s]').allMatches(latin1.decode(pdf)).length;

Future<void> keep(String name, List<int> bytes) async {
  final dir = Platform.environment['IRNET_REPORTS'];
  if (dir == null) return;
  await Directory(dir).create(recursive: true);
  await File('$dir/$name').writeAsBytes(bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late ReportFonts fonts;

  setUpAll(() async {
    sqfliteFfiInit();
    fonts = await ReportFonts.load((path) async => ByteData.sublistView(await File(path).readAsBytes()));
  });

  setUp(() async {
    AppSharedPreferences.resetCache();
    SharedPreferences.setMockInitialValues({'flutter.qualityMonitoring': false});
    db = await AppDatabase.openAt(inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
  });
  tearDown(() => db.close());

  /// A controller over the seeded day, connected through Amsterdam, with a
  /// minute of live probes in memory.
  Future<QualityBloc> seeded({bool seed = true}) async {
    if (seed) await seedQuality(QualityStore(db), DateTime.now());
    var clock = DateTime.now().subtract(const Duration(seconds: 60));
    final monitor = QualityMonitor(
      udp: ScriptedProber((i) => i % 11 == 4 ? null : 96 + (i * 7 % 13)),
      http: ScriptedProber((i) => 121),
      clock: () => clock,
    );
    final quality = QualityBloc(monitor: monitor, database: () async => db, callTester: InstantCallTester());
    await quality.initialize();
    quality.onIpLookup(amsterdam);
    for (var i = 0; i < 30; i++) {
      await monitor.runTick();
      clock = clock.add(const Duration(seconds: 2));
    }
    return quality;
  }

  group('report snapshot', () {
    test('follows the dashboard range, grouping and selection', () async {
      final quality = await seeded();
      final report = (await quality.report(appVersion: '1.5.0', platform: 'macOS'))!;
      expect(report.range, QualityRange.hours24);
      expect(report.rows.map((r) => r.key), containsAll(['185.220.101.12', '45.86.200.5', '172.233.41.190']));
      expect(report.selected, isNull);
      expect(report.current?.ip, '172.233.41.190');
      expect(report.minutes.length, greaterThan(24 * 60 - 10));
      expect(report.callTests, hasLength(2));
      expect(report.samples, isNotEmpty, reason: 'live probes for probes.csv');
      expect(report.probeInterval, const Duration(seconds: 2));
      expect(reportScope(report), 'All servers, compared by IP');

      quality.toggleSelected('185.220.101.12');
      final selected = (await quality.report())!;
      expect(selected.selected?.key, '185.220.101.12');
      expect(selected.scopeMinutes.every((m) => m.server == '185.220.101.12'), isTrue);
      expect(selected.minutes.length, report.minutes.length, reason: 'raw data keeps every server');
      expect(reportScope(selected), 'Hetzner DE #2 (185.220.101.12)');
      expect(selected.total.ticks, lessThan(report.total.ticks));

      quality.toggleSelected('185.220.101.12');
      quality.setRange(QualityRange.hours6);
      final sixHours = (await quality.report())!;
      expect(sixHours.rows.map((r) => r.key), ['172.233.41.190'], reason: 'only Amsterdam in the last 6 h');
      expect(sixHours.callTests, isEmpty);
      await quality.dispose();
    });

    test('outages, lossy minutes and weakest periods', () async {
      final quality = await seeded();
      final report = (await quality.report())!;
      // Istanbul's phase drops out for 4 minutes three times.
      expect(report.outages, hasLength(3));
      for (final o in report.outages) {
        expect(o.end - o.start, 3 * 60);
        expect(o.downSeconds, closeTo(4 * 30 * 2, 0.1));
      }
      expect(report.lossyMinutes(), greaterThan(0));
      final worst = report.worstPeriods();
      expect(worst, isNotEmpty);
      for (var i = 1; i < worst.length; i++) {
        expect(worst[i].stats.score!.value, greaterThanOrEqualTo(worst[i - 1].stats.score!.value));
      }
      expect(worst.every((b) => b.stats.score!.value < 75), isTrue);
      await quality.dispose();
    });
  });

  group('findings and summary', () {
    test('describe the period in plain language', () async {
      final quality = await seeded();
      final report = (await quality.report(appVersion: '1.5.0', platform: 'macOS'))!;
      final findings = reportFindings(report).map((f) => f.text).toList();
      expect(findings.first, startsWith('Overall quality was '));
      expect(findings, contains(startsWith('Ping averaged ')));
      expect(findings, contains(startsWith('Packet loss averaged ')));
      expect(findings, contains(startsWith('Connectivity dropped completely 3 times, about 12m in total')));
      expect(findings, contains(startsWith('Estimated call quality: voice MOS ')));
      expect(findings, contains(startsWith('Latest call test (')));
      expect(findings, contains(matches(RegExp(r'^Best server: Hetzner DE #2 \(score \d+\); worst: Istanbul, Turkey'))));
      expect(findings, contains(startsWith('Worst period: ')));

      final summary = reportSummary(report);
      expect(summary, startsWith('IRNet network quality report\nPeriod: Last 24 hours, '));
      expect(summary, contains('Scope: All servers, compared by IP'));
      expect(summary, contains('Current exit: 172.233.41.190 — Amsterdam, The Netherlands — Akamai Technologies, Inc.'));
      expect(summary, contains('Generated by IRNet 1.5.0 on macOS'));
      expect(summary, contains('1. Hetzner DE #2 (185.220.101.12): score '));
      expect(summary, contains('Amsterdam, The Netherlands (172.233.41.190) [current]'));
      expect(summary, contains('\nCall tests\n'));
      await quality.dispose();
    });

    test('an empty period says so', () async {
      final quality = await seeded(seed: false);
      await quality.clearHistory();
      final report = (await quality.report())!;
      expect(report.isEmpty, isTrue);
      expect(reportFindings(report).single.text, 'No quality measurements were recorded in this period.');
      expect(reportSummary(report), contains('No quality measurements in this period.'));
      final pdf = await buildQualityReportPdf(report, fonts);
      expect(latin1.decode(pdf.sublist(0, 5)), '%PDF-');
      expect(ZipDecoder().decodeBytes(buildReportZip(report)).files, hasLength(6));
      await quality.dispose();
    });
  });

  group('files', () {
    test('CSV fields are quoted per RFC 4180; times carry their offset', () {
      expect(csvField(null), '');
      expect(csvField(12.5), '12.5');
      expect(csvField('plain'), 'plain');
      expect(csvField('a,b'), '"a,b"');
      expect(csvField('say "hi"'), '"say ""hi"""');
      expect(csvField('two\nlines'), '"two\nlines"');
      expect(isoLocal(1761487500), matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d([+-]\d\d:\d\d|Z)$')));
      expect(utcOffsetLabel(const Duration(hours: 3, minutes: 30)), 'UTC+03:30');
      expect(utcOffsetLabel(const Duration(hours: -5)), 'UTC-05:00');
      expect(utcOffsetLabel(Duration.zero), 'UTC');
    });

    test('the ZIP holds a README and one CSV per table', () async {
      final quality = await seeded();
      await quality.rename('185.220.101.12', 'Hetzner "DE", #2');
      final report = (await quality.report())!;
      final zip = buildReportZip(report);
      await keep(reportFileName(report, 'zip'), zip);
      final entries = ZipDecoder().decodeBytes(zip).files;
      final files = {for (final f in entries) f.name: utf8.decode(f.content)};
      expect(files.keys, ['README.txt', 'servers.csv', 'history.csv', 'minutes.csv', 'call_tests.csv', 'probes.csv']);
      expect(files['README.txt'], startsWith('IRNet network quality report'));
      expect(files['README.txt'], contains('minutes.csv'));
      List<String> lines(String name) => files[name]!.split('\r\n')..removeLast();
      for (final f in entries.where((f) => f.name.endsWith('.csv'))) {
        expect(f.content.sublist(0, 3), [0xEF, 0xBB, 0xBF], reason: '${f.name}: BOM so Excel reads UTF-8');
      }
      expect(lines('minutes.csv'), hasLength(report.minutes.length + 1));
      expect(lines('history.csv'), hasLength(report.bins.length + 1));
      expect(lines('call_tests.csv'), hasLength(3));
      expect(lines('probes.csv'), hasLength(report.samples.length + 1));
      final servers = lines('servers.csv');
      expect(servers.first, startsWith('name,label,ips,country'));
      expect(servers, contains(startsWith('"Hetzner ""DE"", #2","Hetzner ""DE"", #2",185.220.101.12,Germany,DE,')));
      expect(servers.where((l) => l.contains(',yes,')), hasLength(1), reason: 'one current server');
      expect(reportFileName(report, 'zip'), matches(RegExp(r'^IRNet-network-quality-\d{4}-\d\d-\d\d-\d{4}\.zip$')));
      await quality.dispose();
    });

    test('the PDF report renders every section on A4 pages', () async {
      final quality = await seeded();
      quality.onIpLookup(amsterdam);
      final report = (await quality.report(appVersion: '1.5.0', platform: 'macOS'))!;
      final watch = Stopwatch()..start();
      final pdf = await buildQualityReportPdf(report, fonts);
      watch.stop();
      await keep(reportFileName(report, 'pdf'), pdf);
      expect(latin1.decode(pdf.sublist(0, 5)), '%PDF-');
      expect(pageCount(pdf), inInclusiveRange(2, 4));
      expect(latin1.decode(pdf), matches(RegExp(r'/MediaBox\s*\[\s*0 0 595\.2\d* 841\.8\d*\s*\]')), reason: 'A4');
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      await quality.dispose();
    });

    test('labels the fonts cannot draw fall back to the location', () async {
      final quality = await seeded();
      await quality.rename('172.233.41.190', 'سرور هلند');
      final report = (await quality.report())!;
      expect(fonts.canWrite('Hetzner DE #2'), isTrue);
      expect(fonts.canWrite('سرور هلند'), isFalse);
      expect(fonts.clean('Zürich → İstanbul'), 'Zürich → İstanbul');
      expect(fonts.clean('VPN سرور'), 'VPN ????');

      final printable = report.keepingLabels(fonts.canWrite);
      ServerQuality row(QualityReport r, String key) => r.rows.firstWhere((q) => q.key == key);
      expect(report.titleOf(row(report, '172.233.41.190')), 'سرور هلند');
      expect(printable.titleOf(row(printable, '172.233.41.190')), 'Amsterdam, The Netherlands');
      expect(printable.titleOf(row(printable, '185.220.101.12')), 'Hetzner DE #2');
      expect(printable.current?.label, isNull);
      expect(printable.serverName('172.233.41.190'), 'Amsterdam, The Netherlands');
      expect(pageCount(await buildQualityReportPdf(report, fonts)), greaterThanOrEqualTo(2));
      await quality.dispose();
    });

    test('saved files never overwrite an earlier export', () async {
      final dir = await Directory.systemTemp.createTemp('irnet_export');
      addTearDown(() => dir.delete(recursive: true));
      expect(FileDelivery.uniqueFile(dir, 'report.pdf').path, '${dir.path}/report.pdf');
      File('${dir.path}/report.pdf').writeAsStringSync('1');
      File('${dir.path}/report (2).pdf').writeAsStringSync('2');
      expect(FileDelivery.uniqueFile(dir, 'report.pdf').path, '${dir.path}/report (3).pdf');
    });
  });
}
