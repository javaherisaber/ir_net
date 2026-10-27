import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _ProcPidPathNative = Int32 Function(Int32 pid, Pointer<Uint8> buffer, Uint32 size);
typedef _ProcPidPath = int Function(int pid, Pointer<Uint8> buffer, int size);

/// PROC_PIDPATHINFO_MAXSIZE.
const _maxPath = 4096;

_ProcPidPath? _procPidPath;

/// Executable path of [pid] via libproc's `proc_pidpath` (macOS). Unlike `ps`
/// this works inside the App Sandbox, which allows `proc_pidinfo` on other
/// processes. Null when the process is gone or the call isn't available.
String? processPath(int pid) {
  if (!Platform.isMacOS) return null;
  final fn = _procPidPath ??= DynamicLibrary.process()
      .lookupFunction<_ProcPidPathNative, _ProcPidPath>('proc_pidpath');
  final buffer = malloc<Uint8>(_maxPath);
  try {
    final length = fn(pid, buffer, _maxPath);
    if (length <= 0) return null;
    return utf8.decode(buffer.asTypedList(length), allowMalformed: true);
  } finally {
    malloc.free(buffer);
  }
}
