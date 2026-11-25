import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/data/leak_item.dart';
import 'package:ir_net/ui/leak_widgets.dart';
import 'package:ir_net/ui/theme.dart';

// Widget tests replace dart:io's HttpClient with one that answers 400, so
// the checker's own tests live in leak_check_test.dart.
void main() {
  group('leak list', () {
    Future<void> loadFonts() async {
      Future<ByteData> file(String path) async => ByteData.sublistView(await File(path).readAsBytes());
      await (FontLoader(AppFonts.ui)..addFont(file('assets/fonts/SpaceGrotesk.ttf'))).load();
      await (FontLoader(AppFonts.mono)..addFont(file('assets/fonts/JetBrainsMono.ttf'))).load();
      final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
          File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
      final icons = File('$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
      if (icons.existsSync()) await (FontLoader('MaterialIcons')..addFont(file(icons.path))).load();
    }

    List<LeakItem> items() => [
          LeakItem('https://developer.android.com', status: LeakStatus.passed)..ms = 312,
          LeakItem('https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/4.1.3/gradle-4.1.3.pom',
              status: LeakStatus.failed)
            ..failure = LeakFailure.http(403, 'Forbidden'),
          LeakItem('https://pub.dev/api/archives/live_event-1.0.0.tar.gz', status: LeakStatus.failed)
            ..failure = LeakFailure.from(
                const SocketException('Connection reset by peer', osError: OSError('Connection reset by peer', 54))),
          LeakItem('https://example.com', status: LeakStatus.loading),
        ];

    Future<void> pump(WidgetTester tester, Size size, {required bool compact}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(
          theme: buildAppTheme(),
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: LeakList(compact: compact, items: items()),
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    Future<void> shot(WidgetTester tester, String name) async {
      final dir = Platform.environment['IRNET_SCREENSHOTS'];
      if (dir == null) return;
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(dir).create(recursive: true);
        await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      });
    }

    testWidgets('each failure says why, with the technical message one tap away', (tester) async {
      await tester.runAsync(loadFonts);
      await pump(tester, const Size(760, 700), compact: false);
      expect(find.text('Answered in 312 ms'), findsOneWidget);
      expect(find.text('Blocked for your location (403)'), findsOneWidget);
      expect(find.text('Connection cut'), findsOneWidget);
      expect(find.text('HTTP 403 Forbidden'), findsNothing);

      await tester.tap(find.text('Details').first);
      await tester.pump();
      expect(find.text('HTTP 403 Forbidden'), findsOneWidget);
      expect(find.text('Hide details'), findsOneWidget);
      await shot(tester, 'leak_desktop');

      await pump(tester, const Size(375, 900), compact: true);
      expect(find.text('Reachable · 312 ms'), findsOneWidget);
      expect(find.text('Checking…'), findsOneWidget);
      await shot(tester, 'leak_phone');
    });
  });
}
