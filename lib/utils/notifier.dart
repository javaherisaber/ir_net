import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:win_toast/win_toast.dart';

/// System notifications on every platform IRNet runs on: macOS
/// (UserNotifications, falling back to AppleScript), Android (an "Alerts"
/// channel), Windows (toasts) and Linux (notify-send).
class AppNotifier {
  AppNotifier._();

  static const _channel = MethodChannel('ir_net/notify');

  /// Replaced in tests.
  @visibleForTesting
  static Future<void> Function(String title, String body, String? id)? override;

  /// [id] makes a later notification with the same id replace this one.
  static Future<void> show(String title, String body, {String? id}) async {
    if (override != null) return override!(title, body, id);
    if (kIsWeb) return;
    try {
      if (Platform.isWindows) {
        await WinToast.instance().showToast(type: ToastType.text02, title: title, subtitle: body);
      } else if (Platform.isMacOS || Platform.isAndroid) {
        final shown = await _channel.invokeMethod<bool>('show', {'title': title, 'body': body, 'id': id});
        if (shown != true && Platform.isMacOS) await _appleScript(title, body);
      } else if (Platform.isLinux) {
        await Process.run('notify-send', ['--app-name=IRNet', title, body]);
      }
    } catch (e) {
      debugPrint('Notification failed: $e');
      if (!kIsWeb && Platform.isMacOS) await _appleScript(title, body);
    }
  }

  /// Shows even when the app isn't allowed to post its own notifications.
  static Future<void> _appleScript(String title, String body) async {
    String q(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
    try {
      await Process.run('/usr/bin/osascript', ['-e', 'display notification ${q(body)} with title ${q(title)}']);
    } catch (_) {}
  }
}
