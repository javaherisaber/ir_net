import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'windows_clipboard_stub.dart' if (dart.library.ffi) 'windows_clipboard_native.dart';

/// Puts images on the system clipboard for pasting into chats and documents:
/// a PNG over the `ir_net/share` channel, or the Win32 clipboard on Windows.
class ImageClipboard {
  const ImageClipboard();

  /// The clipboard the screenshot button copies to; tests swap in a fake.
  static ImageClipboard instance = const ImageClipboard();

  static const _channel = MethodChannel('ir_net/share');

  /// Copies [image]. [name] names the file where the platform shares one
  /// (Android puts a content URI on the clipboard).
  Future<void> copy(ui.Image image, {required String name}) async {
    final png = await _encode(image, ui.ImageByteFormat.png);
    if (!kIsWeb && Platform.isWindows) {
      // Most Windows apps paste a DIB; browsers and Office prefer the PNG.
      final rgba = await _encode(image, ui.ImageByteFormat.rawRgba);
      await copyToWindowsClipboard(png: png, dib: dibFromRgba(rgba, image.width, image.height));
      return;
    }
    await _channel.invokeMethod<void>('copyImage', {'png': png, 'name': name});
  }

  static Future<Uint8List> _encode(ui.Image image, ui.ImageByteFormat format) async {
    final data = await image.toByteData(format: format);
    if (data == null) throw StateError('Could not encode the image');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}

/// A `CF_DIB`: a BITMAPINFOHEADER and bottom-up 32-bit BGRA rows, from
/// top-down RGBA pixels.
Uint8List dibFromRgba(Uint8List rgba, int width, int height) {
  const header = 40;
  final dib = Uint8List(header + width * height * 4);
  ByteData.sublistView(dib)
    ..setUint32(0, header, Endian.little)
    ..setInt32(4, width, Endian.little)
    ..setInt32(8, height, Endian.little) // positive: bottom row first
    ..setUint16(12, 1, Endian.little) // planes
    ..setUint16(14, 32, Endian.little) // bits per pixel; BI_RGB stays 0
    ..setUint32(20, width * height * 4, Endian.little);
  for (var y = 0; y < height; y++) {
    final from = (height - 1 - y) * width * 4;
    final to = header + y * width * 4;
    for (var x = 0; x < width * 4; x += 4) {
      dib[to + x] = rgba[from + x + 2];
      dib[to + x + 1] = rgba[from + x + 1];
      dib[to + x + 2] = rgba[from + x];
      dib[to + x + 3] = rgba[from + x + 3];
    }
  }
  return dib;
}
