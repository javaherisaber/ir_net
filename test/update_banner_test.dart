import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/ui/theme.dart';
import 'package:ir_net/ui/update_banner.dart';
import 'package:ir_net/utils/update_checker.dart';

void main() {
  Future<void> loadFonts() async {
    Future<ByteData> file(String path) async => ByteData.sublistView(await File(path).readAsBytes());
    await (FontLoader(AppFonts.ui)..addFont(file('assets/fonts/SpaceGrotesk.ttf'))).load();
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
        File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
    final icons = File('$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) await (FontLoader('MaterialIcons')..addFont(file(icons.path))).load();
  }

  const info = UpdateInfo(version: '1.7.0', url: 'https://github.com/javaherisaber/ir_net/releases/tag/1.7.0');

  Future<void> shot(WidgetTester tester, String name) async {
    final dir = Platform.environment['IRNET_SCREENSHOTS'];
    if (dir == null) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(dir).create(recursive: true);
      await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('the banner names the release, opens it, and hides on ×', (tester) async {
    await tester.runAsync(loadFonts);
    var opened = 0, dismissed = 0;
    Future<void> pump(double width, {required bool compact}) async {
      tester.view.physicalSize = Size(width, 200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(
          theme: buildAppTheme(),
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: AppColors.panel,
            body: Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.topCenter,
                child: UpdateBanner(
                  compact: compact,
                  testInfo: info,
                  onOpen: () => opened++,
                  onDismiss: () => dismissed++,
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    // The desktop sidebar is 240 px wide with 12 px padding.
    await pump(240, compact: false);
    expect(find.text('Update available'), findsOneWidget);
    expect(find.text('IRNet 1.7.0 is out.'), findsOneWidget);
    await shot(tester, 'update_sidebar');

    await tester.tap(find.text('Download on GitHub'));
    expect(opened, 1);
    await tester.tap(find.byIcon(Icons.close));
    expect(dismissed, 1);
    expect(opened, 1, reason: '× doesn\'t open the page');

    await pump(375, compact: true);
    await shot(tester, 'update_phone');
  });
}
