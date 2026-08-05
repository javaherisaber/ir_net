import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:ir_net/utils/platform.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'package:path_provider/path_provider.dart';

/// Turns the flag of a country into an icon file the system tray can display.
///
/// The tray plugin only accepts a path on disk, so the vector flag shipped by
/// `country_flags` is rasterised on demand and written to the app support
/// directory. Windows needs a multi resolution `.ico`, the other desktops read
/// a `.png` (same convention as the bundled `assets/*.ico|png` icons).
class FlagTrayIcon {
  FlagTrayIcon._();

  /// Resolutions packed into the Windows icon: the tray asks for 16px at 100%
  /// scaling and up to 48px on high DPI displays.
  static const _icoSizes = [16, 24, 32, 48];
  static const _pngSize = 44;
  static const _cacheFolder = 'tray_flags';

  /// Rendered icons of this run, keyed by [_cacheKey].
  static final Map<String, String> _paths = {};
  static Directory? _directory;

  /// Whether the tray of this platform can show a generated icon.
  ///
  /// macOS is left out on purpose: `system_tray` reads macOS icons through the
  /// asset bundle (it sends them base64 encoded), so it cannot display an icon
  /// that was written to disk at runtime. Windows and Linux hand the path to
  /// `LoadImage` / `app_indicator_set_icon_full`, which read any file.
  static bool get isSupported =>
      PlatformUtils.isDesktop && !Platform.isMacOS;

  /// Path to the tray icon of [countryCode] (ISO 3166 alpha-2 or alpha-3), or
  /// null when the country has no flag or the icon could not be rendered — the
  /// caller is expected to fall back to the default IRNet icons then.
  ///
  /// When [leaked] is true the flag is badged with a red dot so the leak
  /// warning is not lost while the flag occupies the tray.
  static Future<String?> pathFor(String? countryCode,
      {bool leaked = false}) async {
    if (!isSupported) {
      return null;
    }
    if (countryCode == null || countryCode.trim().isEmpty) {
      return null;
    }
    final flagCode = FlagCode.fromCountryCode(countryCode.trim().toUpperCase());
    if (flagCode == null) {
      return null;
    }
    final key = _cacheKey(flagCode, leaked);
    final cached = _paths[key];
    if (cached != null) {
      return cached;
    }
    try {
      final path = await _render(flagCode, key, leaked);
      _paths[key] = path;
      return path;
    } on Exception catch (ex) {
      // A missing flag asset or an unwritable cache directory must not take
      // the tray icon down with it.
      debugPrint('Could not render the tray flag of $countryCode => $ex');
      return null;
    }
  }

  static String _cacheKey(String flagCode, bool leaked) {
    return leaked ? '${flagCode}_leaked' : flagCode;
  }

  static Future<String> _render(
      String flagCode, String key, bool leaked) async {
    final directory = await _iconDirectory();
    final extension = Platform.isWindows ? 'ico' : 'png';
    final file =
        File('${directory.path}${Platform.pathSeparator}$key.$extension');
    await file.writeAsBytes(
      await encodeIcon(flagCode, leaked: leaked),
      flush: true,
    );
    return file.path;
  }

  /// Encodes the flag of [flagCode] (the lowercase asset name used by
  /// `country_flags`) as tray icon bytes: an `.ico` on Windows, a `.png`
  /// elsewhere.
  @visibleForTesting
  static Future<Uint8List> encodeIcon(String flagCode,
      {bool leaked = false}) async {
    final flag = await ScalableImage.fromSIAsset(
      rootBundle,
      'packages/country_flags/res/si/$flagCode.si',
    );
    await flag.prepareImages();
    try {
      if (Platform.isWindows) {
        final frames = <img.Image>[];
        for (final size in _icoSizes) {
          frames.add(await _rasterize(flag, size, leaked));
        }
        return img.IcoEncoder().encodeImages(frames);
      }
      return img.encodePng(await _rasterize(flag, _pngSize, leaked));
    } finally {
      flag.unprepareImages();
    }
  }

  /// Draws [flag] centered in a transparent square of [size] pixels, keeping
  /// its aspect ratio, and hands the pixels over to the `image` encoders.
  static Future<img.Image> _rasterize(
      ScalableImage flag, int size, bool leaked) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final viewport = flag.viewport;
    final scale = math.min(size / viewport.width, size / viewport.height);
    final bounds = Rect.fromLTWH(
      (size - viewport.width * scale) / 2,
      (size - viewport.height * scale) / 2,
      viewport.width * scale,
      viewport.height * scale,
    );
    canvas.save();
    canvas.translate(bounds.left, bounds.top);
    canvas.scale(scale);
    flag.paint(canvas);
    canvas.restore();
    _paintBorder(canvas, bounds, size);
    if (leaked) {
      _paintLeakBadge(canvas, size.toDouble());
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(size, size);
    picture.dispose();
    try {
      final pixels =
          await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      return img.Image.fromBytes(
        width: size,
        height: size,
        bytes: pixels!.buffer,
        numChannels: 4,
      );
    } finally {
      image.dispose();
    }
  }

  /// Keeps mostly white flags (Japan, Finland, ...) readable on light taskbars.
  static void _paintBorder(Canvas canvas, Rect bounds, int size) {
    final width = math.max(1, size / 24).toDouble();
    canvas.drawRect(
      bounds.deflate(width / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = const Color(0x59000000),
    );
  }

  static void _paintLeakBadge(Canvas canvas, double size) {
    final radius = size * 0.26;
    final center = Offset(size - radius, size - radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = const Color(0xFF0B0F14),
    );
    canvas.drawCircle(
      center,
      radius * 0.72,
      Paint()..color = const Color(0xFFEF4444),
    );
  }

  static Future<Directory> _iconDirectory() async {
    var directory = _directory;
    if (directory != null) {
      return directory;
    }
    final support = await getApplicationSupportDirectory();
    directory = Directory(
      '${support.path}${Platform.pathSeparator}$_cacheFolder',
    );
    await directory.create(recursive: true);
    _directory = directory;
    return directory;
  }
}
