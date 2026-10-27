// Verifies the country flag tray icons: the vector flag shipped by
// `country_flags` has to come out of the encoder as a valid icon, letterboxed
// into a square, and badged when a leak was found. `pathFor` is also expected
// to give up quietly for unknown countries so the tray can fall back to the
// bundled IRNet icons.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ir_net/utils/flag_tray_icon.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The encoder writes .ico on Windows and .png everywhere else.
  img.Image decode(Uint8List bytes) {
    final decoded = Platform.isWindows
        ? img.IcoDecoder().decode(bytes)
        : img.PngDecoder().decode(bytes);
    expect(decoded, isNotNull, reason: 'the tray icon must be readable');
    return decoded!;
  }

  test('encodes the flag of a country as a tray icon', () async {
    final bytes = await FlagTrayIcon.encodeIcon('ir');
    expect(bytes, isNotEmpty);

    final icon = decode(bytes);
    expect(icon.width, icon.height, reason: 'tray icons are square');

    // The Iranian flag: green, white and red bands must all have made it in.
    var green = 0;
    var white = 0;
    var red = 0;
    for (final pixel in icon) {
      if (pixel.a < 250) continue;
      final r = pixel.r;
      final g = pixel.g;
      final b = pixel.b;
      if (g > 100 && r < 100 && b < 120) green++;
      if (r > 200 && g > 200 && b > 200) white++;
      if (r > 120 && g < 100 && b < 100) red++;
    }
    expect(green, greaterThan(20));
    expect(white, greaterThan(20));
    expect(red, greaterThan(20));
  });

  test('letterboxes the flag so its aspect ratio is kept', () async {
    final icon = decode(await FlagTrayIcon.encodeIcon('ir'));
    // Flags are wider than they are tall, so the top and bottom of the square
    // stay empty while the middle is painted.
    expect(icon.getPixel(0, 0).a, 0);
    expect(icon.getPixel(icon.width - 1, icon.height - 1).a, 0);
    expect(icon.getPixel(icon.width ~/ 2, icon.height ~/ 2).a, 255);
  });

  test('badges the flag when a leak was found', () async {
    // Japan: white where the badge lands, so the red dot cannot be mistaken
    // for the flag itself.
    final clean = decode(await FlagTrayIcon.encodeIcon('jp'));
    final leaked = decode(await FlagTrayIcon.encodeIcon('jp', leaked: true));

    // Center of the badge, which is drawn one radius away from the corner.
    final x = (leaked.width * 0.72).round();
    final y = (leaked.height * 0.72).round();

    final before = clean.getPixel(x, y);
    expect(before.r, greaterThan(200));
    expect(before.g, greaterThan(200));

    final badge = leaked.getPixel(x, y);
    expect(badge.a, 255);
    expect(badge.r, greaterThan(200));
    expect(badge.g, lessThan(100));
    expect(badge.b, lessThan(100));
  });

  test('packs several resolutions into the Windows icon', () async {
    if (!Platform.isWindows) {
      return;
    }
    final decoder = img.IcoDecoder()
      ..startDecode(await FlagTrayIcon.encodeIcon('ir'));
    expect(decoder.numFrames(), 4);
  });

  test('gives up on countries without a flag so the tray can fall back',
      () async {
    expect(await FlagTrayIcon.pathFor(null), isNull);
    expect(await FlagTrayIcon.pathFor(''), isNull);
    expect(await FlagTrayIcon.pathFor('  '), isNull);
    expect(await FlagTrayIcon.pathFor('ZZ'), isNull);
  });
}
