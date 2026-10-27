import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ir_net/data/usage.dart';
import 'package:path_provider/path_provider.dart';

import 'app_names.dart';
import 'process_path_stub.dart' if (dart.library.ffi) 'process_path_native.dart';
import 'windows_usage_helper.dart';

/// What the user has to do before a collector can run.
class UsageSetup {
  const UsageSetup(this.message, {this.actionLabel});
  final String message;

  /// Button that opens the place to fix it, if there is one.
  final String? actionLabel;
}

/// Traffic of one app in one period (an hour or a day), as recorded by the
/// OS before tracking started.
class PastAppUsage {
  const PastAppUsage(this.start, this.app, this.rx, this.tx);
  final DateTime start;
  final String app;
  final int rx;
  final int tx;
}

/// A source of per-app, per-destination traffic deltas.
abstract class UsageCollector {
  /// Short name of the data source shown in the UI, e.g. "nettop".
  String get source;

  /// Whether deltas carry remote addresses (enables domains and countries).
  bool get hasDestinations => true;

  /// Null when the collector can run, otherwise what's missing.
  Future<UsageSetup?> checkSetup() async => null;

  /// Opens whatever lets the user complete [checkSetup].
  Future<void> requestSetup() async {}

  /// Per-app usage the OS kept from before tracking started.
  Future<List<PastAppUsage>> pastUsage({required DateTime until, int days = 30}) async => const [];

  /// Emits the traffic seen since the previous emission. The stream reports
  /// an error and closes when the collector cannot run.
  Stream<List<FlowDelta>> start();

  Future<void> stop();
}

/// The collector for this OS, or null when per-app traffic isn't observable.
UsageCollector? createPlatformCollector() {
  if (kIsWeb) return null;
  if (Platform.isMacOS) return NettopCollector();
  if (Platform.isLinux) return SsCollector();
  if (Platform.isAndroid) return AndroidUsageCollector();
  if (Platform.isWindows) return WindowsEtwCollector();
  return null;
}

/// Why per-app usage is unavailable on this platform, or null when it is.
String? usageUnsupportedReason() {
  if (kIsWeb) return 'Per-app usage needs the desktop or Android app.';
  if (Platform.isIOS) return 'iOS doesn\'t let apps see other apps\' traffic.';
  return null;
}

// ───────────────────────────── macOS: nettop ─────────────────────────────

class NettopFlow {
  const NettopFlow({
    required this.pid,
    required this.process,
    required this.protocol,
    required this.remoteIp,
    required this.interface,
    required this.rx,
    required this.tx,
    this.remotePort,
    this.localPort,
  });

  final int pid;
  final String process;
  final String protocol;
  final String remoteIp;
  final int? remotePort;
  final int? localPort;
  final String interface;
  final int rx;
  final int tx;
}

class NettopSample {
  NettopSample(this.time);

  final DateTime time;
  final flows = <NettopFlow>[];

  /// Per pid: name and the process-level counters, used to catch bytes of
  /// flows that closed and vanished before they could be listed.
  final processes = <int, ({String name, int rx, int tx})>{};
}

/// Incremental parser for
/// `nettop -L 0 -d -n -x -t external -J interface,state,bytes_in,bytes_out`.
///
/// Each sample starts with a header line, then a row per process ("name.pid")
/// followed by rows for its sockets ("tcp4 local<->remote"). In delta mode the
/// first sample holds totals since each socket opened; later ones hold the
/// bytes moved since the previous sample.
class NettopParser {
  NettopParser({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  NettopSample? _current;
  int? _pid;
  String? _process;

  static final _flowId = RegExp(r'^(tcp|udp|quic)(4|6) (.+)<->(.+)$');

  /// Feeds one output line. Returns the previous sample once [line] starts
  /// the next one.
  NettopSample? addLine(String line) {
    if (line.trim().isEmpty) return null;
    if (line.contains('bytes_in') && line.contains('bytes_out')) {
      final done = _current;
      _current = NettopSample(_clock());
      _pid = null;
      _process = null;
      return done;
    }
    final current = _current;
    if (current == null) return null;
    final row = _splitRow(line);
    if (row == null) return null;

    final flowMatch = _flowId.firstMatch(row.id);
    if (flowMatch == null) {
      final dot = row.id.lastIndexOf('.');
      final pid = dot > 0 ? int.tryParse(row.id.substring(dot + 1)) : null;
      if (pid == null) return null;
      _pid = pid;
      _process = row.id.substring(0, dot);
      current.processes[pid] = (name: _process!, rx: row.rx, tx: row.tx);
      return null;
    }
    if (_pid == null) return null;
    final v6 = flowMatch.group(2) == '6';
    final (ip, port) = splitEndpoint(flowMatch.group(4)!, v6: v6);
    current.flows.add(NettopFlow(
      pid: _pid!,
      process: _process!,
      protocol: flowMatch.group(1)!,
      remoteIp: ip,
      remotePort: port,
      localPort: splitEndpoint(flowMatch.group(3)!, v6: v6).$2,
      interface: row.iface,
      rx: row.rx,
      tx: row.tx,
    ));
    return null;
  }

  /// The sample in progress, e.g. when the output ended.
  NettopSample? flush() {
    final current = _current;
    _current = null;
    return current;
  }

  /// Columns are split from the right, so commas inside process names are kept.
  static ({String id, String iface, int rx, int tx})? _splitRow(String line) {
    var parts = line.split(',');
    if (parts.isNotEmpty && parts.last.isEmpty) parts = parts.sublist(0, parts.length - 1);
    if (parts.length < 5) return null;
    final n = parts.length;
    return (
      id: parts.sublist(0, n - 4).join(','),
      iface: parts[n - 4],
      rx: int.tryParse(parts[n - 2]) ?? 0,
      tx: int.tryParse(parts[n - 1]) ?? 0,
    );
  }

  /// Splits nettop's "17.1.2.3:443" (IPv4) or "2001:db8::1.443" (IPv6)
  /// notation. Wildcards ("*:*", "*.*") give an empty address.
  static (String, int?) splitEndpoint(String text, {required bool v6}) {
    final sep = v6 ? text.lastIndexOf('.') : text.lastIndexOf(':');
    var host = sep > 0 ? text.substring(0, sep) : text;
    final port = sep > 0 ? int.tryParse(text.substring(sep + 1)) : null;
    if (host == '*') host = '';
    if (host.startsWith('::ffff:') && host.contains('.')) host = host.substring(7);
    final zone = host.indexOf('%');
    if (zone >= 0) host = host.substring(0, zone);
    return (host, port);
  }
}

/// Turns a parsed sample into deltas, attributing each pid to an app.
List<FlowDelta> nettopDeltas(NettopSample sample, Map<int, String> appNames) {
  final deltas = <FlowDelta>[];
  final flowSums = <int, (int, int)>{};
  for (final f in sample.flows) {
    final sum = flowSums[f.pid] ?? (0, 0);
    flowSums[f.pid] = (sum.$1 + f.rx, sum.$2 + f.tx);
    if (f.rx <= 0 && f.tx <= 0) continue;
    deltas.add(FlowDelta(
      app: appNames[f.pid] ?? friendlyProcessName(f.process),
      remoteIp: f.remoteIp,
      remotePort: f.remotePort,
      localPort: f.localPort,
      iface: interfaceKindOf(f.interface),
      rx: f.rx,
      tx: f.tx,
    ));
  }
  sample.processes.forEach((pid, p) {
    final sum = flowSums[pid] ?? (0, 0);
    final rx = math.max(0, p.rx - sum.$1);
    final tx = math.max(0, p.tx - sum.$2);
    if (rx == 0 && tx == 0) return;
    deltas.add(FlowDelta(
      app: appNames[pid] ?? friendlyProcessName(p.name),
      remoteIp: '',
      iface: InterfaceKind.other,
      rx: rx,
      tx: tx,
    ));
  });
  return deltas;
}

/// Resolves pids to app names from their executable paths, caching the
/// result. Uses `proc_pidpath` (allowed in the App Sandbox), then `ps` for
/// anything it couldn't answer; falls back to nettop's 15-character names.
///
/// The cache is keyed by pid *and* nettop's process name, so a pid the
/// system reuses for another program is looked up again.
class MacAppNames {
  MacAppNames({
    String? Function(int pid)? pathOf,
    Future<ProcessResult> Function(List<int> pids)? runPs,
  })  : _pathOf = pathOf ?? processPath,
        _runPs = runPs ?? _defaultPs;

  final String? Function(int pid) _pathOf;
  final Future<ProcessResult> Function(List<int> pids) _runPs;
  final _cache = <(int, String), String>{};
  bool _pathWorks = true;
  bool _psWorks = true;

  static Future<ProcessResult> _defaultPs(List<int> pids) =>
      Process.run('/bin/ps', ['-o', 'pid=,comm=', '-p', pids.join(',')]);

  /// [processes] maps pid → the (truncated) name nettop reported.
  Future<Map<int, String>> resolve(Map<int, String> processes) async {
    var missing = [
      for (final e in processes.entries)
        if (!_cache.containsKey((e.key, e.value))) e.key,
    ];
    final resolved = <int, String>{};
    if (missing.isNotEmpty && _pathWorks) {
      try {
        for (final pid in missing) {
          final path = _pathOf(pid);
          if (path != null && path.isNotEmpty) resolved[pid] = appNameFromPath(path);
        }
      } catch (_) {
        _pathWorks = false;
      }
      missing = missing.where((p) => !resolved.containsKey(p)).toList();
    }
    // Only when proc_pidpath is unavailable: a pid it can't answer is
    // usually a process that already exited, which ps can't see either.
    if (missing.isNotEmpty && !_pathWorks && _psWorks) {
      try {
        final result = await _runPs(missing);
        for (final line in const LineSplitter().convert('${result.stdout}')) {
          final m = RegExp(r'^\s*(\d+)\s+(.+)$').firstMatch(line);
          if (m != null) resolved[int.parse(m.group(1)!)] = appNameFromPath(m.group(2)!.trim());
        }
      } catch (_) {
        _psWorks = false;
      }
    }
    if (_cache.length > 4000) _cache.clear();
    resolved.forEach((pid, name) {
      final process = processes[pid];
      if (process != null) _cache[(pid, process)] = name;
    });
    return {
      for (final e in processes.entries)
        if (_cache[(e.key, e.value)] != null) e.key: _cache[(e.key, e.value)]!,
    };
  }
}

class NettopCollector extends UsageCollector {
  NettopCollector({
    this.interval = const Duration(seconds: 5),
    this.executable = '/usr/bin/nettop',
    this.restartDelay = const Duration(seconds: 2),
    MacAppNames? names,
  }) : _names = names ?? MacAppNames();

  final Duration interval;
  final String executable;

  /// Pause before restarting nettop after it exits on its own (grows with
  /// each consecutive restart).
  final Duration restartDelay;
  final MacAppNames _names;

  StreamController<List<FlowDelta>>? _controller;
  Process? _process;
  bool _stopped = false;
  int _restarts = 0;

  @override
  String get source => 'nettop';

  List<String> get arguments => [
        '-L', '0', '-d', '-n', '-x', //
        '-s', '${interval.inSeconds}',
        '-t', 'external',
        '-J', 'interface,state,bytes_in,bytes_out',
      ];

  /// nettop polls stdin for its interactive keys and busy-loops (~150% CPU)
  /// once stdin is at EOF, and it would outlive the app if the app died. So it
  /// runs under a small shell tied to our stdin pipe:
  /// * nettop reads the pipe, which never carries data, so it just waits
  ///   (fd 3 carries the pipe past `&`, which would otherwise give /dev/null);
  /// * a watcher `cat`s the same pipe and kills nettop once it closes, i.e.
  ///   when we stop the collector or the app exits for any reason;
  /// * the shell itself waits for nettop, so nettop dying on its own ends the
  ///   shell too (and the watcher is killed first, so it can never signal a
  ///   reused pid).
  static const lifeline = r'''
exec 3<&0
"$0" "$@" <&3 3<&- &
pid=$!
(cat <&3 >/dev/null 2>&1; kill $pid 2>/dev/null) >/dev/null 2>&1 &
watcher=$!
exec 3<&-
wait $pid
code=$?
kill $watcher 2>/dev/null
exit $code
''';

  @override
  Stream<List<FlowDelta>> start() {
    _stopped = false;
    _restarts = 0;
    final controller = _controller = StreamController<List<FlowDelta>>();
    _spawn();
    return controller.stream;
  }

  Future<void> _spawn() async {
    final controller = _controller;
    if (controller == null || _stopped) return;
    final Process process;
    try {
      process = _process = await Process.start('/bin/sh', ['-c', lifeline, executable, ...arguments]);
    } catch (e) {
      controller.addError(Exception('Could not start nettop: $e'));
      await controller.close();
      return;
    }
    final parser = NettopParser();
    var baseline = true;
    final startedAt = DateTime.now();
    process.stderr.drain<void>().catchError((_) {});
    process.stdout
        // nettop cuts names at 15 bytes, which can split a UTF-8 character.
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      final sample = parser.addLine(line);
      if (sample == null) return;
      if (baseline) {
        // The first sample is "everything since each socket opened".
        baseline = false;
        return;
      }
      _emit(sample);
    }, onError: (Object _) {});
    final code = await process.exitCode;
    // Lets the orphaned watcher `cat` of this run see EOF and exit.
    await process.stdin.close().catchError((_) {});
    if (_stopped) return;
    // nettop exited on its own. Restart a few times, then give up.
    final ranLong = DateTime.now().difference(startedAt) > const Duration(minutes: 1);
    if (ranLong) _restarts = 0;
    if (_restarts++ < 3) {
      await Future<void>.delayed(restartDelay * _restarts);
      return _spawn();
    }
    controller.addError(Exception('nettop exited with code $code'));
    await controller.close();
  }

  Future<void> _emit(NettopSample sample) async {
    final active = <int>{
      for (final f in sample.flows)
        if (f.rx > 0 || f.tx > 0) f.pid,
      for (final e in sample.processes.entries)
        if (e.value.rx > 0 || e.value.tx > 0) e.key,
    };
    if (active.isEmpty) return;
    final names = await _names.resolve({
      for (final pid in active) pid: sample.processes[pid]?.name ?? '',
    });
    final deltas = nettopDeltas(sample, names);
    final controller = _controller;
    if (deltas.isNotEmpty && controller != null && !controller.isClosed) controller.add(deltas);
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    final process = _process;
    _process = null;
    if (process != null) {
      // Closing the lifeline makes the wrapper kill nettop and exit.
      await process.stdin.close().catchError((_) {});
      await process.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
        process.kill();
        return -1;
      });
    }
    final controller = _controller;
    _controller = null;
    if (controller != null && !controller.isClosed) await controller.close();
  }
}

// ───────────────────────────── Linux: ss ─────────────────────────────

/// One TCP socket from `ss -tinpeH`.
class SsSocket {
  const SsSocket({
    required this.key,
    required this.localIp,
    required this.remoteIp,
    required this.remotePort,
    required this.rx,
    required this.tx,
    this.localPort,
    this.process,
    this.pid,
  });

  /// Stable identity across polls (socket inode, else the address pair).
  final String key;
  final String localIp;
  final int? localPort;
  final String remoteIp;
  final int? remotePort;
  final String? process;
  final int? pid;

  /// Cumulative bytes received / sent on the socket.
  final int rx;
  final int tx;
}

/// Parses `ss -tinpeH` output: a line per socket, then an indented line of
/// TCP info carrying `bytes_received` and `bytes_sent`/`bytes_acked`.
List<SsSocket> parseSsOutput(String output) {
  final sockets = <SsSocket>[];
  final lines = const LineSplitter().convert(output);
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty || line.startsWith(' ') || line.startsWith('\t')) continue;
    final info = (i + 1 < lines.length && lines[i + 1].startsWith(RegExp(r'\s'))) ? lines[i + 1] : '';
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 5) continue;
    final local = splitSsEndpoint(fields[3]);
    final remote = splitSsEndpoint(fields[4]);
    if (local == null || remote == null) continue;

    final rx = _ssNumber(info, 'bytes_received') ?? 0;
    final tx = _ssNumber(info, 'bytes_sent') ?? _ssNumber(info, 'bytes_acked') ?? 0;
    final user = RegExp(r'users:\(\("((?:[^"\\]|\\.)*)",pid=(\d+)').firstMatch(line);
    final inode = RegExp(r'\bino:(\d+)').firstMatch(line)?.group(1);
    final key = (inode != null && inode != '0') ? 'ino:$inode' : '${fields[3]}>${fields[4]}';
    sockets.add(SsSocket(
      key: key,
      localIp: local.$1,
      localPort: local.$2,
      remoteIp: remote.$1,
      remotePort: remote.$2,
      rx: rx,
      tx: tx,
      process: user?.group(1),
      pid: user == null ? null : int.tryParse(user.group(2)!),
    ));
  }
  return sockets;
}

int? _ssNumber(String info, String name) {
  final m = RegExp('\\b$name:(\\d+)').firstMatch(info);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// "10.0.0.2:443", "[2001:db8::1]:443", "[::ffff:1.2.3.4]:80", "1.2.3.4%eth0:22".
(String, int?)? splitSsEndpoint(String text) {
  final sep = text.lastIndexOf(':');
  if (sep <= 0) return null;
  var host = text.substring(0, sep);
  final port = int.tryParse(text.substring(sep + 1));
  if (host.startsWith('[') && host.endsWith(']')) host = host.substring(1, host.length - 1);
  final zone = host.indexOf('%');
  if (zone >= 0) host = host.substring(0, zone);
  if (host.startsWith('::ffff:') && host.contains('.')) host = host.substring(7);
  if (host == '*') host = '';
  return (host, port);
}

/// Turns successive `ss` snapshots into deltas. The first snapshot is only a
/// baseline; sockets that appear later count from zero.
class SsDeltaTracker {
  Map<String, SsSocket>? _previous;

  List<SsSocket> update(List<SsSocket> sockets) {
    final previous = _previous;
    _previous = {for (final s in sockets) s.key: s};
    if (previous == null) return const [];
    final deltas = <SsSocket>[];
    for (final s in sockets) {
      final before = previous[s.key];
      var rx = s.rx - (before?.rx ?? 0);
      var tx = s.tx - (before?.tx ?? 0);
      // Counters went backwards: the key was reused by a new socket.
      if (rx < 0 || tx < 0) {
        rx = s.rx;
        tx = s.tx;
      }
      if (rx == 0 && tx == 0) continue;
      deltas.add(SsSocket(
        key: s.key,
        localIp: s.localIp,
        localPort: s.localPort,
        remoteIp: s.remoteIp,
        remotePort: s.remotePort,
        rx: rx,
        tx: tx,
        process: s.process,
        pid: s.pid,
      ));
    }
    return deltas;
  }
}

/// Polls `ss` for TCP sockets. Linux exposes byte counters for TCP only, and
/// process names only for the current user's sockets.
class SsCollector extends UsageCollector {
  SsCollector({
    this.interval = const Duration(seconds: 5),
    Future<ProcessResult> Function()? runSs,
    Future<Map<String, String>> Function()? localInterfaces,
  })  : _runSs = runSs ?? (() => Process.run('ss', ['-tinpeH'])),
        _localInterfaces = localInterfaces ?? _listInterfaces;

  final Duration interval;
  final Future<ProcessResult> Function() _runSs;
  final Future<Map<String, String>> Function() _localInterfaces;

  var _tracker = SsDeltaTracker();
  StreamController<List<FlowDelta>>? _controller;
  Timer? _timer;
  Map<String, String> _interfaceByIp = const {};
  DateTime? _interfacesAt;

  @override
  String get source => 'ss';

  static Future<Map<String, String>> _listInterfaces() async {
    final result = <String, String>{};
    for (final inf in await NetworkInterface.list(includeLoopback: false)) {
      for (final a in inf.addresses) {
        result[a.address] = inf.name;
      }
    }
    return result;
  }

  @override
  Stream<List<FlowDelta>> start() {
    // A new baseline: counters moved while paused must not land in the
    // first minute after resuming.
    _tracker = SsDeltaTracker();
    final controller = _controller = StreamController<List<FlowDelta>>();
    _poll();
    _timer = Timer.periodic(interval, (_) => _poll());
    return controller.stream;
  }

  Future<void> _poll() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final result = await _runSs();
      if (result.exitCode != 0) throw Exception('ss exited with ${result.exitCode}: ${result.stderr}');
      await _refreshInterfaces();
      final deltas = [
        for (final s in _tracker.update(parseSsOutput('${result.stdout}')))
          FlowDelta(
            app: s.process == null ? 'System (other users)' : friendlyProcessName(s.process!),
            remoteIp: s.remoteIp,
            remotePort: s.remotePort,
            localPort: s.localPort,
            iface: interfaceKindOf(_interfaceByIp[s.localIp]),
            rx: s.rx,
            tx: s.tx,
          ),
      ];
      if (deltas.isNotEmpty && !controller.isClosed) controller.add(deltas);
    } catch (e) {
      _timer?.cancel();
      if (!controller.isClosed) {
        controller.addError(Exception('Could not read sockets with ss: $e'));
        await controller.close();
      }
    }
  }

  Future<void> _refreshInterfaces() async {
    final at = _interfacesAt;
    if (at != null && DateTime.now().difference(at) < const Duration(minutes: 1)) return;
    try {
      _interfaceByIp = await _localInterfaces();
    } catch (_) {}
    _interfacesAt = DateTime.now();
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final controller = _controller;
    _controller = null;
    if (controller != null && !controller.isClosed) await controller.close();
  }
}

// ───────────────────────────── Android ─────────────────────────────

/// One app's totals from Android's NetworkStatsManager.
class AndroidAppUsage {
  const AndroidAppUsage({required this.uid, required this.name, required this.rx, required this.tx, this.package});

  factory AndroidAppUsage.fromMap(Map<Object?, Object?> map) => AndroidAppUsage(
        uid: (map['uid'] as num).toInt(),
        name: (map['name'] as String?) ?? 'App ${map['uid']}',
        package: map['package'] as String?,
        rx: (map['rx'] as num?)?.toInt() ?? 0,
        tx: (map['tx'] as num?)?.toInt() ?? 0,
      );

  final int uid;
  final String name;
  final String? package;
  final int rx;
  final int tx;
}

/// Per-app traffic on Android from NetworkStatsManager (Wi-Fi, mobile and
/// Ethernet), polled and turned into deltas. Android doesn't say where the
/// traffic went, so there are no domains or countries.
class AndroidUsageCollector extends UsageCollector {
  AndroidUsageCollector({
    this.interval = const Duration(seconds: 30),
    MethodChannel? channel,
    DateTime Function()? clock,
  })  : _channel = channel ?? const MethodChannel('ir_net/net_usage'),
        _clock = clock ?? DateTime.now;

  final Duration interval;
  final MethodChannel _channel;
  final DateTime Function() _clock;

  /// Android keeps per-app counters in 2-hour buckets; querying from a bucket
  /// boundary keeps successive totals comparable.
  static const _bucket = Duration(hours: 2);

  StreamController<List<FlowDelta>>? _controller;
  Timer? _timer;
  DateTime? _anchor;
  Map<int, AndroidAppUsage>? _previous;

  @override
  String get source => 'Android usage stats';

  @override
  bool get hasDestinations => false;

  @override
  Future<UsageSetup?> checkSetup() async {
    final ok = await _channel.invokeMethod<bool>('hasUsageAccess') ?? false;
    return ok
        ? null
        : const UsageSetup(
            'Allow IRNet "Usage access" so Android shares how much data each app uses.',
            actionLabel: 'Open settings',
          );
  }

  @override
  Future<void> requestSetup() => _channel.invokeMethod<void>('openUsageAccessSettings');

  /// Per-app totals over `[from, to)`.
  Future<List<AndroidAppUsage>> totals(DateTime from, DateTime to) async {
    final rows = await _channel.invokeListMethod<Map<Object?, Object?>>('querySummary', {
          'start': from.millisecondsSinceEpoch,
          'end': to.millisecondsSinceEpoch,
        }) ??
        const [];
    return rows.map(AndroidAppUsage.fromMap).toList();
  }

  /// The last two days come at the OS's own 2-hour resolution (split evenly
  /// into hours) so today's and yesterday's charts have shape; older days are
  /// daily totals.
  @override
  Future<List<PastAppUsage>> pastUsage({required DateTime until, int days = 30}) async {
    final result = <PastAppUsage>[];
    void add(DateTime start, List<AndroidAppUsage> rows, {double share = 1}) {
      for (final r in rows) {
        final rx = (r.rx * share).round(), tx = (r.tx * share).round();
        if (rx > 0 || tx > 0) result.add(PastAppUsage(start, r.name, rx, tx));
      }
    }

    final ms = until.millisecondsSinceEpoch;
    final recentFrom = DateTime.fromMillisecondsSinceEpoch(
        ms - ms % _bucket.inMilliseconds - const Duration(hours: 46).inMilliseconds);
    final first = DateTime(until.year, until.month, until.day - (days - 1));
    for (var day = first; day.isBefore(recentFrom); day = DateTime(day.year, day.month, day.day + 1)) {
      final next = DateTime(day.year, day.month, day.day + 1);
      add(day, await totals(day, next.isAfter(recentFrom) ? recentFrom : next));
    }
    for (var t = recentFrom; t.isBefore(until); t = t.add(_bucket)) {
      final end = t.add(_bucket);
      if (end.isAfter(until)) {
        // The bucket in progress: everything so far, at its start.
        add(t, await totals(t, until));
      } else {
        final rows = await totals(t, end);
        add(t, rows, share: 0.5);
        add(t.add(const Duration(hours: 1)), rows, share: 0.5);
      }
    }
    return result;
  }

  @override
  Stream<List<FlowDelta>> start() {
    final now = _clock();
    final ms = now.millisecondsSinceEpoch;
    _anchor = DateTime.fromMillisecondsSinceEpoch(ms - ms % _bucket.inMilliseconds);
    _previous = null;
    final controller = _controller = StreamController<List<FlowDelta>>();
    _poll();
    _timer = Timer.periodic(interval, (_) => _poll());
    return controller.stream;
  }

  Future<void> _poll() async {
    final controller = _controller;
    final anchor = _anchor;
    if (controller == null || anchor == null) return;
    try {
      // The open-ended bucket is counted in full, so ask a little past now.
      final current = {for (final r in await totals(anchor, _clock().add(_bucket))) r.uid: r};
      final previous = _previous;
      _previous = current;
      if (previous == null) return; // baseline
      final deltas = <FlowDelta>[];
      for (final r in current.values) {
        final before = previous[r.uid];
        final rx = r.rx - (before?.rx ?? 0);
        final tx = r.tx - (before?.tx ?? 0);
        if (rx < 0 || tx < 0 || (rx == 0 && tx == 0)) continue;
        deltas.add(FlowDelta(app: r.name, remoteIp: '', iface: InterfaceKind.other, rx: rx, tx: tx));
      }
      if (deltas.isNotEmpty && !controller.isClosed) controller.add(deltas);
    } on PlatformException catch (e) {
      _timer?.cancel();
      if (!controller.isClosed) {
        controller.addError(Exception(e.code == 'NO_ACCESS'
            ? 'Usage access was turned off for IRNet'
            : 'Android usage stats failed: ${e.message}'));
        await controller.close();
      }
    }
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final controller = _controller;
    _controller = null;
    if (controller != null && !controller.isClosed) await controller.close();
  }
}

// ───────────────────────────── Windows: ETW helper ─────────────────────────────

/// Display name for a Windows process: its file description ("Google
/// Chrome"), else the executable's name.
String windowsAppName({String? name, String? exe}) {
  final n = name?.trim() ?? '';
  if (n.isNotEmpty) return friendlyProcessName(n);
  final file = (exe ?? '').split(RegExp(r'[\\/]')).last;
  final base = file.toLowerCase().endsWith('.exe') ? file.substring(0, file.length - 4) : file;
  return base.isEmpty ? 'Unknown app' : friendlyProcessName(base);
}

/// One sample file written by the helper.
List<FlowDelta> parseWindowsSample(Map<String, dynamic> json) {
  final flows = json['flows'];
  if (flows is! List) return const [];
  final deltas = <FlowDelta>[];
  for (final f in flows.whereType<Map>()) {
    final rx = (f['rx'] as num?)?.toInt() ?? 0;
    final tx = (f['tx'] as num?)?.toInt() ?? 0;
    if (rx <= 0 && tx <= 0) continue;
    deltas.add(FlowDelta(
      app: windowsAppName(name: f['name'] as String?, exe: f['exe'] as String?),
      remoteIp: (f['ip'] as String?) ?? '',
      remotePort: (f['port'] as num?)?.toInt(),
      iface: switch (f['kind']) {
        'tunnel' => InterfaceKind.tunnel,
        'physical' => InterfaceKind.physical,
        _ => InterfaceKind.other,
      },
      rx: rx,
      tx: tx,
    ));
  }
  return deltas;
}

/// Per-app traffic on Windows, from the elevated ETW helper (see
/// [windowsHelperCSharp]). IRNet itself stays a normal process: the helper
/// is started on the user's request (one admin prompt), or directly when
/// IRNet already runs as administrator.
class WindowsEtwCollector extends UsageCollector {
  WindowsEtwCollector({
    this.pollInterval = const Duration(seconds: 2),
    this.staleAfter = const Duration(seconds: 30),
    this.readyTimeout = const Duration(seconds: 30),
    Future<Directory> Function()? workDir,
    Future<bool> Function()? isElevated,
    Future<ProcessResult> Function(List<String> args)? runPowerShell,
    Future<void> Function(List<String> args)? startPowerShell,
    DateTime Function()? clock,
  })  : _workDir = workDir ?? _defaultDir,
        _isElevated = isElevated ?? _defaultElevated,
        _runPowerShell = runPowerShell ?? ((args) => Process.run('powershell.exe', args)),
        _startPowerShell = startPowerShell ??
            ((args) => Process.start('powershell.exe', args, mode: ProcessStartMode.detached)),
        _clock = clock ?? DateTime.now;

  final Duration pollInterval;

  /// No sample for this long means the helper is gone (it writes one every 5 s).
  final Duration staleAfter;
  final Duration readyTimeout;
  final Future<Directory> Function() _workDir;
  final Future<bool> Function() _isElevated;
  final Future<ProcessResult> Function(List<String> args) _runPowerShell;
  final Future<void> Function(List<String> args) _startPowerShell;
  final DateTime Function() _clock;

  StreamController<List<FlowDelta>>? _controller;
  Timer? _timer;
  DateTime _lastSample = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastError;

  @override
  String get source => 'Windows ETW helper';

  static Future<Directory> _defaultDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}usage-helper').create(recursive: true);
  }

  /// High (S-1-16-12288) or System mandatory level = running as admin.
  static Future<bool> _defaultElevated() async {
    try {
      final groups = '${(await Process.run('whoami', ['/groups'])).stdout}';
      return groups.contains('S-1-16-12288') || groups.contains('S-1-16-16384');
    } catch (_) {
      return false;
    }
  }

  File _file(Directory dir, String name) => File('${dir.path}${Platform.pathSeparator}$name');

  /// The helper is running if it said so and keeps producing samples.
  Future<bool> _helperAlive(Directory dir) async {
    final ready = _file(dir, 'ready');
    if (!await ready.exists()) return false;
    var newest = await ready.lastModified();
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.json')) {
        final modified = await e.lastModified();
        if (modified.isAfter(newest)) newest = modified;
      }
    }
    return _clock().difference(newest) < staleAfter;
  }

  @override
  Future<UsageSetup?> checkSetup() async {
    final dir = await _workDir();
    if (await _helperAlive(dir)) return null;
    if (await _isElevated()) {
      final error = await _launch(dir, elevate: false);
      if (error == null) return null;
      return UsageSetup('The usage helper could not start: $error');
    }
    final hint = _lastError == null ? '' : ' Last attempt: $_lastError';
    return UsageSetup(
      'Windows only shows per-app traffic to administrators. IRNet can run a small helper with admin '
      'rights for this; Windows asks for permission each time it starts.$hint',
      actionLabel: 'Start helper (admin)',
    );
  }

  @override
  Future<void> requestSetup() async {
    _lastError = await _launch(await _workDir(), elevate: true);
  }

  static String _encode(String command) {
    final units = command.codeUnits;
    final bytes = Uint8List(units.length * 2);
    for (var i = 0; i < units.length; i++) {
      bytes[i * 2] = units[i] & 0xff;
      bytes[i * 2 + 1] = units[i] >> 8;
    }
    return base64.encode(bytes);
  }

  static String _quote(String text) => "'${text.replaceAll("'", "''")}'";

  /// Runs the helper (elevated through the admin prompt when [elevate]) and
  /// waits until it reports ready. Returns an error message, or null.
  Future<String?> _launch(Directory dir, {required bool elevate}) async {
    for (final name in ['ready', 'error.txt', 'stop']) {
      final f = _file(dir, name);
      if (await f.exists()) await f.delete();
    }
    final script = buildWindowsHelperScript();
    final scriptFile = _file(dir, 'helper.ps1');
    await scriptFile.writeAsString(script, flush: true);
    // The elevated side runs the script only if it still has this hash, so
    // nothing can swap the file between writing it and the admin prompt.
    final hash = sha256.convert(utf8.encode(script)).toString().toUpperCase();
    final inner = [
      '\$c = [IO.File]::ReadAllText(${_quote(scriptFile.path)})',
      "\$h = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes(\$c))).Replace('-', '')",
      "if (\$h -ne '$hash') { exit 3 }",
      '& ([ScriptBlock]::Create(\$c)) -ParentPid $pid -OutDir ${_quote(dir.path)}',
    ].join('\n');
    final helperArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ${_encode(inner)}';
    try {
      if (elevate) {
        final outer = "Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList '$helperArgs'";
        final result = await _runPowerShell(
            ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', _encode(outer)]);
        if (result.exitCode != 0) {
          final text = '${result.stderr}';
          return text.contains('canceled by the user') ? 'the admin prompt was declined' : 'it could not be started';
        }
      } else {
        await _startPowerShell(helperArgs.split(' '));
      }
    } catch (e) {
      return 'PowerShell is unavailable ($e)';
    }
    final deadline = _clock().add(readyTimeout);
    while (_clock().isBefore(deadline)) {
      if (await _file(dir, 'ready').exists()) return null;
      final error = _file(dir, 'error.txt');
      if (await error.exists()) return (await error.readAsString()).trim();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return 'it did not start in time';
  }

  @override
  Stream<List<FlowDelta>> start() {
    final controller = _controller = StreamController<List<FlowDelta>>();
    _lastSample = _clock();
    _timer = Timer.periodic(pollInterval, (_) => _poll());
    return controller.stream;
  }

  Future<void> _poll() async {
    final controller = _controller;
    if (controller == null || controller.isClosed) return;
    final dir = await _workDir();
    final files = <File>[
      await for (final e in dir.list())
        if (e is File && e.path.endsWith('.json') && e.uri.pathSegments.last.startsWith('sample-')) e,
    ]..sort((a, b) => a.path.compareTo(b.path));
    final deltas = <FlowDelta>[];
    for (final f in files) {
      try {
        final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final t = DateTime.fromMillisecondsSinceEpoch((json['t'] as num?)?.toInt() ?? 0);
        // Leftovers from before this run would land in the wrong minute.
        if (_clock().difference(t) < const Duration(minutes: 2)) deltas.addAll(parseWindowsSample(json));
        _lastSample = _clock();
      } catch (_) {}
      try {
        await f.delete();
      } catch (_) {}
    }
    if (deltas.isNotEmpty) controller.add(deltas);
    if (_clock().difference(_lastSample) > staleAfter) {
      _timer?.cancel();
      final error = _file(dir, 'error.txt');
      final why = await error.exists() ? (await error.readAsString()).trim() : 'the usage helper stopped';
      controller.addError(Exception(why));
      await controller.close();
    }
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    try {
      // The helper checks for this file and exits (stopping its trace).
      await _file(await _workDir(), 'stop').writeAsString('stop');
    } catch (_) {}
    final controller = _controller;
    _controller = null;
    if (controller != null && !controller.isClosed) await controller.close();
  }
}
