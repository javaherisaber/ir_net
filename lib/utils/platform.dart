import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform;

class PlatformUtils {
  static bool get isDesktop {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  /// macOS draws no title bar (see MainFlutterWindow.swift): the window
  /// buttons float over the top-left corner of the content.
  static bool get hiddenTitleBar => !kIsWeb && Platform.isMacOS;

  static bool get isMobile {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }
}