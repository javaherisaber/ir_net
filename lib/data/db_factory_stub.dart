import 'package:sqflite_common/sqlite_api.dart';

/// Web has no SQLite; callers check [AppDatabase.isSupported] first.
DatabaseFactory platformDatabaseFactory() =>
    throw UnsupportedError('Local history is not available on this platform');
