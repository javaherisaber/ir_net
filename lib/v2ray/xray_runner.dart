import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A running Xray core.
abstract class XrayInstance {
  /// Completes when the core stops, whether asked to or not.
  Future<void> get exited;
  bool get hasExited;

  /// The last lines the core logged (for error messages).
  String get logTail;

  /// Process id where there is one (desktop).
  int? get pid;

  /// The outbound tag ("proxy-3") of the most recent connection in the
  /// core's access log, if it logs one.
  String? get lastOutboundTag;

  Future<void> stop();
}

/// Starts Xray cores from a JSON config.
abstract class XrayRunner {
  /// Throws [XrayStartException] when the core can't be started.
  Future<XrayInstance> start(String config, {String label = 'core'});
}

class XrayStartException implements Exception {
  const XrayStartException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Where the bundled core lives, per platform.
class XrayBinary {
  XrayBinary._();

  static String get fileName => Platform.isWindows ? 'xray.exe' : 'xray';

  /// The bundled core next to the app's executable (Contents/MacOS on macOS),
  /// or `$IRNET_XRAY` for development.
  static String? locate() {
    final override = Platform.environment['IRNET_XRAY'];
    if (override != null && override.isNotEmpty && File(override).existsSync()) return override;
    final dir = File(Platform.resolvedExecutable).parent.path;
    for (final candidate in [p.join(dir, fileName), p.join(dir, 'lib', fileName)]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static const missingMessage =
      'The Xray core isn\'t bundled with this build. Run "dart run tool/fetch_xray.dart" and rebuild.';
}

/// Runs the core as a child process (desktop).
class ProcessXrayRunner implements XrayRunner {
  ProcessXrayRunner(this.binary, {this.assetDir});
  final String binary;

  /// Where imported geoip/geosite .dat files live (XRAY_LOCATION_ASSET).
  final String? assetDir;

  static Directory? _workDir;

  /// The app's private Xray folder (configs, and assets/ for .dat files).
  static Future<Directory> workDir() => _dir();

  static Future<Directory> _dir() async {
    if (_workDir != null) return _workDir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'v2ray'));
    await dir.create(recursive: true);
    if (!Platform.isWindows) {
      // Configs carry server credentials; keep them to this user.
      await Process.run('chmod', ['700', dir.path]);
    }
    return _workDir = dir;
  }

  @override
  Future<XrayInstance> start(String config, {String label = 'core'}) async {
    final dir = await _dir();
    final file = File(p.join(dir.path, 'xray-$label-${DateTime.now().microsecondsSinceEpoch}.json'));
    await file.writeAsString(config, flush: true);
    final Process process;
    try {
      process = await Process.start(
        binary,
        ['run', '-c', file.path],
        workingDirectory: dir.path,
        environment: {if (assetDir != null) 'XRAY_LOCATION_ASSET': assetDir!},
      );
    } on ProcessException catch (e) {
      await _delete(file);
      throw XrayStartException('Could not start the Xray core: ${e.message}');
    }
    final instance = _ProcessInstance(process);
    // The core reads its config once at start-up; don't leave credentials on disk.
    unawaited(Future.any([instance.exited, Future.delayed(const Duration(seconds: 10))])
        .then((_) => _delete(file)));
    return instance;
  }

  static Future<void> _delete(File f) async {
    try {
      await f.delete();
    } catch (_) {}
  }
}

class _ProcessInstance implements XrayInstance {
  _ProcessInstance(this._process) {
    for (final stream in [_process.stdout, _process.stderr]) {
      stream.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(_log);
    }
    _process.exitCode.then((code) {
      _hasExited = true;
      _exited.complete();
    });
  }

  final Process _process;
  final _lines = <String>[];
  final _exited = Completer<void>();
  bool _hasExited = false;
  String? _lastOutbound;

  @override
  String? get lastOutboundTag => _lastOutbound;

  void _log(String line) {
    if (line.trim().isEmpty) return;
    final tag = outboundTagIn(line);
    if (tag != null) {
      _lastOutbound = tag;
      return; // access lines aren't errors worth keeping
    }
    _lines.add(line);
    if (_lines.length > 40) _lines.removeAt(0);
    if (kDebugMode) debugPrint('xray[${_process.pid}] $line');
  }

  @override
  Future<void> get exited => _exited.future;

  @override
  bool get hasExited => _hasExited;

  @override
  int get pid => _process.pid;

  @override
  String get logTail {
    // Prefer the core's own error lines over start-up chatter.
    final errors = _lines.where((l) => RegExp(r'error|failed|invalid|unknown|prohibited', caseSensitive: false).hasMatch(l));
    final source = errors.isNotEmpty ? errors.toList() : _lines;
    return source.skip(source.length > 3 ? source.length - 3 : 0).join('\n');
  }

  @override
  Future<void> stop() async {
    if (_hasExited) return;
    _process.kill();
    await exited.timeout(const Duration(seconds: 3), onTimeout: () {
      _process.kill(ProcessSignal.sigkill);
    });
  }
}

/// Runs the core inside the app process through libv2ray (Android), see
/// XrayTester.kt. Used for delay tests; the VPN itself runs in the
/// flutter_v2ray service.
class ChannelXrayRunner implements XrayRunner {
  static const _channel = MethodChannel('ir_net/xray');

  /// The folder libv2ray (and flutter_v2ray's VPN service) read .dat files
  /// from: the app's external files "assets" directory.
  static Future<String?> assetDir() async {
    try {
      return await _channel.invokeMethod<String>('assetDir');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<XrayInstance> start(String config, {String label = 'core'}) async {
    try {
      final id = await _channel.invokeMethod<int>('start', {'config': config});
      return _ChannelInstance(id!);
    } on PlatformException catch (e) {
      throw XrayStartException(e.message ?? 'The Xray core failed to start');
    } on MissingPluginException {
      throw const XrayStartException('The Xray core is not available in this build');
    }
  }
}

class _ChannelInstance implements XrayInstance {
  _ChannelInstance(this.id);
  final int id;
  final _exited = Completer<void>();

  @override
  Future<void> get exited => _exited.future;

  @override
  bool get hasExited => _exited.isCompleted;

  @override
  String get logTail => '';

  @override
  int? get pid => null;

  @override
  String? get lastOutboundTag => null;

  @override
  Future<void> stop() async {
    if (_exited.isCompleted) return;
    try {
      await ChannelXrayRunner._channel.invokeMethod('stop', {'id': id});
    } catch (_) {}
    _exited.complete();
  }
}

/// Loopback port helpers.
class LocalPorts {
  LocalPorts._();

  static Future<bool> isFree(int port) async {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// [count] distinct ports the OS reports free right now.
  static Future<List<int>> free(int count) async {
    final sockets = <ServerSocket>[];
    try {
      for (var i = 0; i < count; i++) {
        sockets.add(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
      }
      return sockets.map((s) => s.port).toList();
    } finally {
      for (final s in sockets) {
        await s.close();
      }
    }
  }

  /// [preferred] when free, else any free port not in [avoid].
  static Future<int> pick(int preferred, {Set<int> avoid = const {}}) async {
    if (!avoid.contains(preferred) && await isFree(preferred)) return preferred;
    while (true) {
      final port = (await free(1)).first;
      if (!avoid.contains(port)) return port;
    }
  }

  /// Waits until something accepts connections on [port], the core exits,
  /// or [timeout] passes. Returns whether the port came up.
  static Future<bool> waitFor(int port, XrayInstance instance, {Duration timeout = const Duration(seconds: 8)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (instance.hasExited) return false;
      try {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(milliseconds: 300));
        s.destroy();
        return true;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 120));
      }
    }
    return false;
  }
}

// Xray writes ">>" for the default route, "->" for a routing rule (the
// balancer's catch-all) and "==>" for a forced outbound.
final _accessTag = RegExp(r'(?:>>|->|==>) (proxy-\d+)\]');

/// "… accepted tcp:1.2.3.4:443 [tun -> proxy-3]" → "proxy-3".
String? outboundTagIn(String line) => _accessTag.allMatches(line).lastOrNull?.group(1);
