import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// Text of the QR code in an image file (a screenshot of a config shared
/// in a messenger, a saved QR PNG…), or null when none is found.
Future<String?> decodeQrImage(Uint8List bytes) => compute(_decode, bytes);

String? _decode(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null) return null;
  // Big screenshots decode faster (and often better) scaled down; fall back
  // to full size for small, dense codes.
  final candidates = <img.Image>[
    if (image.width > 1400 || image.height > 1400)
      img.copyResize(image, width: image.width >= image.height ? 1400 : null, height: image.height > image.width ? 1400 : null),
    image,
  ];
  for (final candidate in candidates) {
    final pixels = candidate.convert(numChannels: 4).getBytes(order: img.ChannelOrder.abgr).buffer.asInt32List();
    final source = RGBLuminanceSource(candidate.width, candidate.height, pixels);
    // Dark-mode messengers draw light-on-dark codes; try those inverted.
    final inverted = InvertedLuminanceSource(source);
    for (final bitmap in [
      BinaryBitmap(HybridBinarizer(source)),
      BinaryBitmap(GlobalHistogramBinarizer(source)),
      BinaryBitmap(HybridBinarizer(inverted)),
    ]) {
      try {
        final text = QRCodeReader().decode(bitmap, hints: DecodeHints()..put(DecodeHintType.tryHarder)).text;
        if (text.trim().isNotEmpty) return text.trim();
      } on ReaderException {
        continue;
      } catch (_) {
        continue;
      }
    }
  }
  return null;
}
