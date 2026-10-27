import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'db_factory_stub.dart' if (dart.library.ffi) 'db_factory_native.dart';

export 'package:sqflite_common/sqlite_api.dart' show Database, DatabaseFactory;

/// Local SQLite database backing the network-quality and data-usage history.
///
/// Desktop platforms use SQLite through FFI (the OS copy of the library),
/// mobile uses the sqflite plugin. The web build has no database.
class AppDatabase {
  AppDatabase._();

  static const fileName = 'irnet.db';
  static const _version = 2;

  static Future<Database>? _instance;

  static bool get isSupported => !kIsWeb;

  /// The app-wide database, opened (and created) on first use.
  static Future<Database> get instance => _instance ??= _openDefault();

  static Future<Database> _openDefault() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return openAt(p.join(dir.path, fileName), factory: platformDatabaseFactory());
  }

  /// Opens [path] with [factory] and applies the schema. Tests use this with an
  /// in-memory path and the no-isolate FFI factory.
  static Future<Database> openAt(String path, {required DatabaseFactory factory}) {
    return factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _version,
        onConfigure: (db) async {
          // WAL keeps the frequent small writes cheap. Some platforms report
          // the pragma result as a row, hence rawQuery; failure is harmless.
          try {
            await db.rawQuery('PRAGMA journal_mode=WAL');
          } catch (_) {}
        },
        onCreate: (db, version) async {
          final batch = db.batch();
          for (final statement in schema) {
            batch.execute(statement);
          }
          await batch.commit(noResult: true);
        },
        onUpgrade: (db, from, to) async {
          final batch = db.batch();
          if (from < 2) {
            batch.execute('ALTER TABLE quality_minute ADD COLUMN secs REAL NOT NULL DEFAULT 0');
            batch.execute(_callTestTable);
          }
          await batch.commit(noResult: true);
        },
      ),
    );
  }

  /// Every statement is plain SQL that works on old SQLite builds too
  /// (Android 8, the Windows `winsqlite3.dll`), so no UPSERT syntax is used
  /// anywhere: writes do `INSERT OR IGNORE` followed by `UPDATE`.
  static const schema = <String>[
    // One row per minute per exit IP. Sums (not averages) are stored so any
    // time range can be re-aggregated exactly.
    '''
    CREATE TABLE quality_minute (
      ts INTEGER NOT NULL,
      server TEXT NOT NULL,
      ticks INTEGER NOT NULL DEFAULT 0,
      down_ticks INTEGER NOT NULL DEFAULT 0,
      udp_sent INTEGER NOT NULL DEFAULT 0,
      udp_recv INTEGER NOT NULL DEFAULT 0,
      udp_rtt_sum REAL NOT NULL DEFAULT 0,
      udp_rtt_min REAL,
      udp_rtt_max REAL,
      udp_jitter_sum REAL NOT NULL DEFAULT 0,
      udp_jitter_n INTEGER NOT NULL DEFAULT 0,
      http_sent INTEGER NOT NULL DEFAULT 0,
      http_ok INTEGER NOT NULL DEFAULT 0,
      http_rtt_sum REAL NOT NULL DEFAULT 0,
      http_rtt_min REAL,
      http_rtt_max REAL,
      http_jitter_sum REAL NOT NULL DEFAULT 0,
      http_jitter_n INTEGER NOT NULL DEFAULT 0,
      secs REAL NOT NULL DEFAULT 0,
      PRIMARY KEY (ts, server)
    )''',
    'CREATE INDEX quality_minute_server ON quality_minute (server, ts)',
    // Location metadata for every exit IP seen while monitoring.
    '''
    CREATE TABLE quality_server (
      ip TEXT PRIMARY KEY,
      country TEXT,
      country_code TEXT,
      region TEXT,
      city TEXT,
      isp TEXT,
      label TEXT,
      first_seen INTEGER NOT NULL,
      last_seen INTEGER NOT NULL
    )''',
    // Recent traffic at minute resolution, per app and remote address. Rows
    // older than a few days are rolled up into usage_hour.
    '''
    CREATE TABLE usage_minute (
      ts INTEGER NOT NULL,
      app TEXT NOT NULL,
      ip TEXT NOT NULL,
      iface INTEGER NOT NULL,
      rx INTEGER NOT NULL DEFAULT 0,
      tx INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (ts, app, ip, iface)
    )''',
    '''
    CREATE TABLE usage_hour (
      ts INTEGER NOT NULL,
      app TEXT NOT NULL,
      domain TEXT NOT NULL,
      country TEXT NOT NULL,
      iface INTEGER NOT NULL,
      rx INTEGER NOT NULL DEFAULT 0,
      tx INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (ts, app, domain, country, iface)
    )''',
    // What we know about a remote address: reverse DNS, owner and country.
    '''
    CREATE TABLE ip_info (
      ip TEXT PRIMARY KEY,
      kind INTEGER NOT NULL,
      domain_key TEXT,
      host TEXT,
      country_code TEXT,
      country TEXT,
      org TEXT,
      updated_at INTEGER NOT NULL
    )''',
    _callTestTable,
  ];

  /// Simulated call tests (schema v2).
  static const _callTestTable = '''
    CREATE TABLE call_test (
      ts INTEGER NOT NULL,
      server TEXT NOT NULL,
      sent INTEGER NOT NULL,
      received INTEGER NOT NULL,
      late INTEGER NOT NULL,
      max_burst INTEGER NOT NULL,
      burst_ratio REAL NOT NULL,
      rtt_median REAL,
      rtt_p95 REAL,
      jitter REAL,
      voice_mos REAL NOT NULL,
      video_mos REAL NOT NULL,
      via_tcp INTEGER NOT NULL DEFAULT 0,
      down_mbps REAL,
      up_mbps REAL,
      PRIMARY KEY (ts, server)
    )''';
}
