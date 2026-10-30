import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ir_net/data/quality.dart';

import 'quality_probes.dart';
import 'time_utils.dart';

/// Continuously probes the connection and aggregates the results per minute
/// and per exit IP ("server").
///
/// Every [interval] one UDP probe is sent; every [httpEvery]-th tick an HTTPS
/// probe as well. Results are attributed to the server that was current when
/// the probe was sent, so switching VPN servers starts a new series.
///
/// System sleep is not measured: probes in flight when the system sleeps are
/// dropped, and after waking, results are held back while the network and
/// the VPN reconnect. They are dropped once the connection holds again, or
/// kept as a real outage when it is still failing after [wakeGrace].
class QualityMonitor {
  QualityMonitor({
    required this.udp,
    required this.http,
    this.interval = const Duration(seconds: 2),
    this.httpEvery = 5,
    this.onRecovered,
    this.skipUdp,
    this.wakeGrace = const Duration(minutes: 2),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final RttProber udp;
  final RttProber http;
  Duration interval;
  final int httpEvery;

  /// When this returns true, UDP probes are not sent and HTTPS is probed
  /// every other tick instead. Used while a system HTTP proxy is set: UDP
  /// would bypass the proxy and measure the direct path, not the VPN.
  final bool Function()? skipUdp;

  /// Called when connectivity comes back after an outage: a good moment to
  /// re-check the public IP, since VPN clients reconnect on server switches.
  final VoidCallback? onRecovered;

  /// How long after waking the connection may take to come back before
  /// failures count as a real outage.
  final Duration wakeGrace;
  final DateTime Function() _clock;

  /// How much raw history the live chart can show.
  static const sampleRetention = Duration(minutes: 15);

  /// Minute windows stay in memory this long so late replies still land in
  /// the window of the tick that sent them.
  static const _windowRetention = Duration(minutes: 3);

  /// A gap between ticks (or a tick taking) this much longer than usual
  /// means the process was suspended: the system slept.
  static const _suspendGap = Duration(seconds: 30);

  /// Consecutive ticks with connectivity that end the wake-up phase.
  static const _settledTicks = 3;

  String _server = '';
  Timer? _timer;
  int _tickCount = 0;
  int _consecutiveDown = 0;
  bool? _lastHttpOk;
  bool _httpBusy = false;
  String? _udpUnavailable;
  double? _lastUdpRtt;
  double? _lastHttpRtt;
  DateTime? _startedAt;
  DateTime? _lastTickAt;

  /// Set between the sleep and wake notifications.
  DateTime? _sleptAt;

  /// Deadline of the wake-up phase; null when not waking up.
  DateTime? _settleUntil;
  final _held = <_TickResult>[];
  int _upStreak = 0;

  /// Bumped to discard ticks still in flight from before a sleep.
  int _epoch = 0;

  final _samples = <ProbeSample>[];
  final _ticks = <({DateTime time, String server, bool down})>[];
  final _windows = <String, QualityWindow>{};
  final _changes = StreamController<void>.broadcast();

  /// Fires after every probe result and server change.
  Stream<void> get changes => _changes.stream;

  bool get isRunning => _timer != null;
  String get server => _server;

  /// Why UDP probes can't be sent (e.g. the sandbox refuses the socket);
  /// null while they work. HTTPS takes over meanwhile.
  String? get udpUnavailable => _udpUnavailable;
  DateTime? get startedAt => _startedAt;

  /// Just woke from sleep: results are held until the connection is back.
  bool get settling => _settleUntil != null;
  List<ProbeSample> get samples => List.unmodifiable(_samples);

  void start() {
    if (_timer != null) return;
    _startedAt = _clock();
    _lastTickAt = null;
    _timer = Timer.periodic(interval, (_) => runTick());
    runTick();
    _notify();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _startedAt = null;
    _notify();
  }

  /// Applies a new probe interval; restarts the schedule when running.
  void setInterval(Duration value) {
    if (value == interval) return;
    interval = value;
    if (isRunning) {
      stop();
      start();
    }
  }

  /// Sets the public IP new probes are attributed to.
  void setServer(String ip) {
    if (ip == _server) return;
    _server = ip;
    // Jitter compares consecutive replies on the same path only.
    _lastUdpRtt = null;
    _lastHttpRtt = null;
    _notify();
  }

  /// The network changed: drop sockets and connections bound to the old path.
  void onNetworkChanged() {
    udp.reset();
    http.reset();
    _lastUdpRtt = null;
    _lastHttpRtt = null;
  }

  /// The system is about to sleep: drop probes in flight and stop counting
  /// until [onWake].
  void onSleep() {
    _sleptAt = _clock();
    _epoch++;
    _endSettling();
    _notify();
  }

  /// The system woke up: hold results until the connection is back.
  void onWake() {
    _sleptAt = null;
    _beginSettling();
    _notify();
  }

  void _beginSettling() {
    _epoch++;
    _held.clear();
    _upStreak = 0;
    _settleUntil = _clock().add(wakeGrace);
    // Connections and the last HTTPS result are from before the sleep.
    _lastHttpOk = null;
    onNetworkChanged();
  }

  void _endSettling() {
    _held.clear();
    _upStreak = 0;
    _settleUntil = null;
  }

  /// One monitoring step. Public so tests can drive the monitor without
  /// timers; completes once this tick's probes have finished.
  Future<void> runTick() async {
    final sentAt = _clock();
    if (_sleptAt != null) {
      // Asleep; a tick long after the sleep means the wake event was missed.
      if (sentAt.difference(_sleptAt!) < _suspendGap) return;
      onWake();
    } else if (_lastTickAt != null && sentAt.difference(_lastTickAt!) > interval + _suspendGap) {
      // Woke without a notification (or the platform has none).
      _beginSettling();
    }
    _lastTickAt = sentAt;
    final epoch = _epoch;
    final server = _server;
    final seconds = interval.inMicroseconds / 1e6;

    final probeUdp = skipUdp?.call() != true;
    final udpAlone = !probeUdp || _udpUnavailable != null;
    // One HTTPS probe at a time: a slow one (cold connection + timeouts)
    // can outlast the gap to the next.
    final probeHttp = !_httpBusy && _tickCount % (udpAlone ? 2 : httpEvery) == 0;
    _tickCount++;

    final udpFuture = probeUdp ? _probeUdp() : Future<(double?, bool)>.value((null, false));
    Future<double?> httpFuture = Future<double?>.value(null);
    if (probeHttp) {
      _httpBusy = true;
      httpFuture = http.probe().whenComplete(() => _httpBusy = false);
    }

    final (udpRtt, udpSent) = await udpFuture;
    final httpRtt = await httpFuture;
    if (epoch != _epoch) return; // the system slept meanwhile
    if (_clock().difference(sentAt) > _suspendGap) {
      // Suspended mid-probe without a sleep notification.
      _beginSettling();
      _notify();
      return;
    }
    if (probeHttp) _lastHttpOk = httpRtt != null;

    // Down = nothing gets through: the UDP probe is lost and HTTPS (this
    // tick's, or the latest one) fails too. UDP alone failing is just loss,
    // or a VPN that does not carry UDP.
    final down = udpRtt == null && _lastHttpOk != true;
    final result = _TickResult(
      sentAt: sentAt,
      server: server,
      seconds: seconds,
      udpRtt: udpSent ? udpRtt : null,
      udpSent: udpSent,
      httpRtt: httpRtt,
      httpProbed: probeHttp,
      down: down,
    );
    if (_settleUntil == null) {
      _apply(result);
    } else {
      _settle(result);
    }

    if (down) {
      _consecutiveDown++;
    } else {
      if (_consecutiveDown >= 2) onRecovered?.call();
      _consecutiveDown = 0;
    }
    _trim();
    _notify();
  }

  /// Holds [result] while waking up. Once the connection has held for a few
  /// ticks, those are kept and what came before is dropped as reconnect
  /// noise; if it is still failing at the deadline, everything is kept.
  void _settle(_TickResult result) {
    _held.add(result);
    _upStreak = result.down ? 0 : _upStreak + 1;
    final List<_TickResult> keep;
    if (_upStreak >= _settledTicks) {
      keep = _held.sublist(_held.length - _upStreak);
    } else if (!result.sentAt.isBefore(_settleUntil!)) {
      keep = List.of(_held);
    } else {
      return;
    }
    _endSettling();
    keep.forEach(_apply);
  }

  void _apply(_TickResult t) {
    final window = _windowFor(t.sentAt, t.server);
    window.ticks++;
    window.seconds += t.seconds;
    window.dirty = true;
    if (t.udpSent) _record(window, ProbeKind.udp, t.sentAt, t.server, t.udpRtt);
    if (t.httpProbed) _record(window, ProbeKind.http, t.sentAt, t.server, t.httpRtt);
    if (t.down) window.downTicks++;
    _ticks.add((time: t.sentAt, server: t.server, down: t.down));
  }

  /// (rtt, whether a probe actually went out).
  Future<(double?, bool)> _probeUdp() async {
    try {
      final rtt = await udp.probe();
      if (_udpUnavailable != null) {
        _udpUnavailable = null;
        _notify();
      }
      return (rtt, true);
    } on ProbeUnavailable catch (e) {
      _udpUnavailable = e.message;
      return (null, false);
    }
  }

  void _record(QualityWindow window, ProbeKind kind, DateTime sentAt, String server, double? rtt) {
    final series = kind == ProbeKind.udp ? window.udp : window.http;
    // Replies from before a server switch don't feed the new server's jitter.
    final sameServer = server == _server;
    if (rtt == null) {
      series.addLost();
    } else if (kind == ProbeKind.udp) {
      series.addReply(rtt, previous: sameServer ? _lastUdpRtt : null);
      if (sameServer) _lastUdpRtt = rtt;
    } else {
      series.addReply(rtt, previous: sameServer ? _lastHttpRtt : null);
      if (sameServer) _lastHttpRtt = rtt;
    }
    window.dirty = true;
    _samples.add(ProbeSample(sentAt, kind, rtt, server: server));
  }

  QualityWindow _windowFor(DateTime time, String server) {
    final start = minuteStart(time);
    return _windows.putIfAbsent('$start|$server', () => QualityWindow(start, server));
  }

  /// Windows changed since the last call (marked clean). Old, already
  /// persisted windows are evicted from memory.
  List<QualityWindow> takeDirtyWindows() {
    final dirty = _windows.values.where((w) => w.dirty).toList();
    for (final w in dirty) {
      w.dirty = false;
    }
    // Held ticks may still land in older minutes once waking up ends.
    if (_settleUntil != null) return dirty;
    final cutoff = minuteStart(_clock().subtract(_windowRetention));
    _windows.removeWhere((_, w) => !w.dirty && w.start < cutoff);
    return dirty;
  }

  /// Stats from in-memory samples over the last [span] for [server]
  /// (defaults to the current one).
  QualityStats recentStats(Duration span, {String? server}) {
    final target = server ?? _server;
    final since = _clock().subtract(span);
    final stats = QualityStats();
    double? prevUdp;
    double? prevHttp;
    for (final s in _samples) {
      if (s.time.isBefore(since) || s.server != target) continue;
      final series = s.kind == ProbeKind.udp ? stats.udp : stats.http;
      if (s.rtt == null) {
        series.addLost();
        continue;
      }
      if (s.kind == ProbeKind.udp) {
        series.addReply(s.rtt!, previous: prevUdp);
        prevUdp = s.rtt;
      } else {
        series.addReply(s.rtt!, previous: prevHttp);
        prevHttp = s.rtt;
      }
    }
    for (final t in _ticks) {
      if (t.time.isBefore(since) || t.server != target) continue;
      stats.ticks++;
      if (t.down) stats.downTicks++;
    }
    return stats;
  }

  void _trim() {
    final cutoff = _clock().subtract(sampleRetention);
    _samples.removeWhere((s) => s.time.isBefore(cutoff));
    _ticks.removeWhere((t) => t.time.isBefore(cutoff));
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void dispose() {
    stop();
    udp.close();
    http.close();
    _changes.close();
  }
}

/// One tick's probe outcomes, applied to its minute once it counts.
class _TickResult {
  const _TickResult({
    required this.sentAt,
    required this.server,
    required this.seconds,
    required this.udpRtt,
    required this.udpSent,
    required this.httpRtt,
    required this.httpProbed,
    required this.down,
  });

  final DateTime sentAt;
  final String server;
  final double seconds;
  final double? udpRtt;
  final bool udpSent;
  final double? httpRtt;
  final bool httpProbed;
  final bool down;
}
