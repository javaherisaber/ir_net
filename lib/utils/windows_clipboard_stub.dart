import 'dart:typed_data';

/// No Win32 clipboard without dart:ffi (web).
Future<void> copyToWindowsClipboard({required Uint8List png, required Uint8List dib}) async =>
    throw UnsupportedError('The Windows clipboard is not available here');
