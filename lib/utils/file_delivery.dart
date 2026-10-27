import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where an exported file ended up.
class DeliveredFile {
  const DeliveredFile(this.path, {required this.shared});

  final String path;

  /// Handed to the system share sheet (phones) rather than saved to a folder.
  final bool shared;

  String get name => p.basename(path);
  String get folder => p.dirname(path);
}

/// Gets an exported file to the user: the share sheet on Android and iOS
/// (`ir_net/share` channel), the Downloads folder on desktops.
class FileDelivery {
  const FileDelivery();

  static const _channel = MethodChannel('ir_net/share');

  /// Phones share files; desktops save them.
  bool get sharesFiles => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<DeliveredFile> deliver(String name, Uint8List bytes, {required String mimeType, String? subject}) async {
    if (sharesFiles) {
      final dir = Directory(p.join((await getTemporaryDirectory()).path, 'exports'));
      if (dir.existsSync()) {
        // Earlier exports were only needed while their share sheet was open.
        for (final old in dir.listSync()) {
          try {
            old.deleteSync();
          } catch (_) {}
        }
      }
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, name));
      await file.writeAsBytes(bytes, flush: true);
      await _channel.invokeMethod<void>('shareFile', {
        'path': file.path,
        'mimeType': mimeType,
        'subject': subject ?? name,
      });
      return DeliveredFile(file.path, shared: true);
    }
    final dir = await _saveFolder();
    await dir.create(recursive: true);
    final file = uniqueFile(dir, name);
    await file.writeAsBytes(bytes, flush: true);
    return DeliveredFile(file.path, shared: false);
  }

  Future<Directory> _saveFolder() async {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    } catch (_) {
      // No Downloads folder known (some Linux setups): use Documents.
    }
    return getApplicationDocumentsDirectory();
  }

  /// `name.pdf` in [dir], or `name (2).pdf` when that is taken.
  @visibleForTesting
  static File uniqueFile(Directory dir, String name) {
    final base = p.basenameWithoutExtension(name);
    final extension = p.extension(name);
    var file = File(p.join(dir.path, name));
    for (var i = 2; file.existsSync(); i++) {
      file = File(p.join(dir.path, '$base ($i)$extension'));
    }
    return file;
  }

  /// Opens a saved file in its default app.
  Future<void> open(String path) async {
    if (Platform.isMacOS) {
      await _channel.invokeMethod<void>('openFile', {'path': path});
    } else {
      await launchUrl(Uri.file(path));
    }
  }

  /// Shows a saved file in Finder / Explorer / the file manager.
  Future<void> reveal(String path) async {
    if (Platform.isMacOS) {
      await _channel.invokeMethod<void>('revealFile', {'path': path});
    } else if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', path]);
    } else {
      await launchUrl(Uri.directory(p.dirname(path)));
    }
  }
}
