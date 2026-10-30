import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final _user32 = DynamicLibrary.open('user32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _openClipboard = _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('OpenClipboard');
final _emptyClipboard = _user32.lookupFunction<Int32 Function(), int Function()>('EmptyClipboard');
final _closeClipboard = _user32.lookupFunction<Int32 Function(), int Function()>('CloseClipboard');
final _setClipboardData =
    _user32.lookupFunction<IntPtr Function(Uint32, IntPtr), int Function(int, int)>('SetClipboardData');
final _registerClipboardFormat = _user32
    .lookupFunction<Uint32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('RegisterClipboardFormatW');
final _findWindowEx = _user32.lookupFunction<IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
    int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
final _getWindowThreadProcessId = _user32
    .lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
        'GetWindowThreadProcessId');
final _globalAlloc = _kernel32.lookupFunction<IntPtr Function(Uint32, IntPtr), int Function(int, int)>('GlobalAlloc');
final _globalLock =
    _kernel32.lookupFunction<Pointer<Uint8> Function(IntPtr), Pointer<Uint8> Function(int)>('GlobalLock');
final _globalUnlock = _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('GlobalUnlock');
final _globalFree = _kernel32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GlobalFree');
final _getCurrentProcessId = _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');

const _cfDib = 8;
const _gmemMoveable = 0x0002;

/// Replaces the Windows clipboard with an image as both a registered "PNG"
/// and a `CF_DIB` ([dib], see `dibFromRgba`).
Future<void> copyToWindowsClipboard({required Uint8List png, required Uint8List dib}) async {
  final owner = _appWindow();
  // Another app may hold the clipboard open for a moment.
  var open = false;
  for (var attempt = 0; attempt < 10 && !open; attempt++) {
    if (attempt > 0) await Future<void>.delayed(const Duration(milliseconds: 25));
    open = _openClipboard(owner) != 0;
  }
  if (!open) throw StateError('The clipboard is in use by another app');
  try {
    _emptyClipboard();
    _put(_cfDib, dib);
    final name = 'PNG'.toNativeUtf16();
    try {
      _put(_registerClipboardFormat(name), png);
    } finally {
      malloc.free(name);
    }
  } finally {
    _closeClipboard();
  }
}

/// Hands a copy of [bytes] to the clipboard, which then owns the memory.
void _put(int format, Uint8List bytes) {
  final memory = _globalAlloc(_gmemMoveable, bytes.length);
  if (memory == 0) throw StateError('Not enough memory for the clipboard');
  final target = _globalLock(memory);
  if (target == nullptr) {
    _globalFree(memory);
    throw StateError('Not enough memory for the clipboard');
  }
  target.asTypedList(bytes.length).setAll(0, bytes);
  _globalUnlock(memory);
  if (_setClipboardData(format, memory) == 0) {
    _globalFree(memory);
    throw StateError('Windows refused the clipboard data');
  }
}

/// This app's main window, the clipboard owner (Windows wants one for
/// SetClipboardData); 0 if it can't be found.
int _appWindow() {
  final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final processId = calloc<Uint32>();
  try {
    final self = _getCurrentProcessId();
    var window = 0;
    while ((window = _findWindowEx(0, window, className, nullptr)) != 0) {
      _getWindowThreadProcessId(window, processId);
      if (processId.value == self) return window;
    }
    return 0;
  } finally {
    malloc.free(className);
    calloc.free(processId);
  }
}
