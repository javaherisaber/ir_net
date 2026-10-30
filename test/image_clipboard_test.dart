import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/utils/image_clipboard.dart';

void main() {
  test('dibFromRgba writes a BITMAPINFOHEADER and bottom-up BGRA rows', () {
    // 2 × 2: red, green on top; blue, white below.
    final rgba = Uint8List.fromList([
      255, 0, 0, 255, 0, 255, 0, 255, //
      0, 0, 255, 255, 255, 255, 255, 255,
    ]);
    final dib = dibFromRgba(rgba, 2, 2);
    final header = ByteData.sublistView(dib);
    expect(dib.length, 40 + 16);
    expect(header.getUint32(0, Endian.little), 40);
    expect(header.getInt32(4, Endian.little), 2);
    expect(header.getInt32(8, Endian.little), 2, reason: 'positive height = bottom-up');
    expect(header.getUint16(12, Endian.little), 1);
    expect(header.getUint16(14, Endian.little), 32);
    expect(header.getUint32(16, Endian.little), 0, reason: 'BI_RGB');
    expect(header.getUint32(20, Endian.little), 16);
    expect(dib.sublist(40), [
      255, 0, 0, 255, 255, 255, 255, 255, // blue, white (bottom row first)
      0, 0, 255, 255, 0, 255, 0, 255, // red, green
    ]);
  });

  testWidgets('copy sends the PNG over ir_net/share', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ir_net/share'), (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ir_net/share'), null));

    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 3, 2), Paint()..color = const Color(0xFF33D6C6));
      final picture = recorder.endRecording();
      final image = await picture.toImage(3, 2);
      await const ImageClipboard().copy(image, name: 'shot.png');
      image.dispose();
      picture.dispose();
    });

    final call = calls.single;
    expect(call.method, 'copyImage');
    expect(call.arguments['name'], 'shot.png');
    final png = call.arguments['png'] as Uint8List;
    expect(png.take(8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    final decoded = await tester.runAsync(() => decodeImageFromList(png));
    expect([decoded!.width, decoded.height], [3, 2]);
  }, skip: Platform.isWindows); // Windows writes to the real clipboard instead.
}
