import 'dart:ffi';
import 'dart:io';

import 'package:sqflite/sqflite.dart' as plugin;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// Mobile uses the sqflite plugin; desktop talks to the system SQLite library
/// through FFI on a background isolate.
DatabaseFactory platformDatabaseFactory() {
  if (Platform.isAndroid || Platform.isIOS) return plugin.databaseFactory;
  return createDatabaseFactoryFfi(ffiInit: _initDesktopSqlite);
}

/// Runs inside the database isolate. The `libsqlite3.so` name only exists when
/// the -dev package is installed, so fall back to the runtime soname on Linux.
/// Windows already falls back to the OS-provided `winsqlite3.dll`.
void _initDesktopSqlite() {
  open.overrideFor(OperatingSystem.linux, () {
    try {
      return DynamicLibrary.open('libsqlite3.so');
    } on ArgumentError {
      return DynamicLibrary.open('libsqlite3.so.0');
    }
  });
}
