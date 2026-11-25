import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/ui/connection_widgets.dart';
import 'package:ir_net/ui/theme.dart';
import 'package:ir_net/utils/cmd.dart';

void main() {
  Future<void> loadFonts() async {
    Future<ByteData> file(String path) async => ByteData.sublistView(await File(path).readAsBytes());
    await (FontLoader(AppFonts.ui)..addFont(file('assets/fonts/SpaceGrotesk.ttf'))).load();
    await (FontLoader(AppFonts.mono)..addFont(file('assets/fonts/JetBrainsMono.ttf'))).load();
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
        File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
    final icons = File('$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) await (FontLoader('MaterialIcons')..addFont(file(icons.path))).load();
  }

  const lookup = {
    'query': '45.76.91.5',
    'country': 'Germany',
    'countryCode': 'DE',
    'regionName': 'Hesse',
    'city': 'Frankfurt am Main',
    'isp': 'The Constant Company',
  };
  final network = LocalNetworksResult(
    [NetworkInterface('Wi-Fi (en0)', '192.168.70.133'), NetworkInterface('VPN tunnel (utun4)', '240.0.0.2')],
    ['1.1.1.1', '1.0.0.1'],
  );

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
            padding: const EdgeInsets.all(20),
            child: ConnectionDetails(compact: compact, testLookup: lookup, testNetwork: network),
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

  testWidgets('details read clearly, and a local IP copies on click', (tester) async {
    await tester.runAsync(loadFonts);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await pump(tester, const Size(780, 640), compact: false);
    expect(find.text('Germany'), findsWidgets);
    expect(find.text('45.76.91.5'), findsOneWidget);
    expect(find.text('Primary'), findsOneWidget);
    expect(find.text('Wi-Fi'), findsOneWidget);
    expect(find.text('en0'), findsOneWidget);
    await shot(tester, 'connection_desktop');

    await tester.tap(find.text('192.168.70.133'));
    await tester.pump();
    expect(copied, '192.168.70.133');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Copied', findRichText: true), findsOneWidget);

    await tester.tap(find.text('45.76.91.5'));
    await tester.pump();
    expect(copied, '45.76.91.5');

    await pump(tester, const Size(390, 1100), compact: true);
    await tester.tap(find.text('1.0.0.1'));
    await tester.pump();
    expect(copied, '1.0.0.1');
    await tester.pump(const Duration(seconds: 3));
    await shot(tester, 'connection_phone');
  });
}
