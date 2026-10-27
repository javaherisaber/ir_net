import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:ir_net/data/call_quality.dart';

import 'quality_probes.dart';

enum CallTestPhase { voice, download, upload }

class CallTestProgress {
  const CallTestProgress(this.phase, this.fraction);
  final CallTestPhase phase;

  /// Whole test, 0–1.
  final double fraction;
}

/// Simulates a call: voice-sized UDP packets every 20 ms (what a voice codec
/// sends) to a STUN server, then a short download + upload for video.
///
/// Unlike the background probes (one every few seconds), the burst sees the
/// short dropouts and delay spikes that make calls stutter.
class CallTester {
  CallTester({
    this.targets = defaultStunTargets,
    this.packets = 400,
    this.spacing = const Duration(milliseconds: 20),
    this.packetBytes = 160,
    this.lateAfter = const Duration(milliseconds: 120),
    this.lossTimeout = const Duration(seconds: 1),
    this.downloadUrl = 'https://speed.cloudflare.com/__down?bytes=2500000',
    this.uploadUrl = 'https://speed.cloudflare.com/__up',
    this.uploadBytes = 1500000,
    this.transferTimeout = const Duration(seconds: 8),
    this.proxy,
    HostLookup? lookup,
    HttpClient Function()? clientFactory,
    Random? random,
  })  : _lookup = lookup ?? ((host) => InternetAddress.lookup(host, type: InternetAddressType.IPv4)),
        _clientFactory = clientFactory ?? HttpClient.new,
        _random = random ?? Random.secure();

  final List<StunTarget> targets;

  /// 400 × 20 ms = an 8-second call.
  final int packets;
  final Duration spacing;

  /// Size of each request (a 20 ms voice frame with RTP/UDP framing).
  final int packetBytes;

  /// A reply this much slower than the median misses a call's playout
  /// buffer (~60 ms each way) and counts as lost for the call.
  final Duration lateAfter;
  final Duration lossTimeout;
  final String downloadUrl;
  final String uploadUrl;
  final int uploadBytes;
  final Duration transferTimeout;

  /// System HTTP proxy for the bandwidth part. Calls' UDP doesn't use HTTP
  /// proxies, so the voice part always goes direct.
  final String? Function()? proxy;
  final HostLookup _lookup;
  final HttpClient Function() _clientFactory;
  final Random _random;

  Future<CallTestResult> run({required String server, void Function(CallTestProgress)? onProgress}) async {
    final voice = await _voiceBurst(onProgress);
    final client = _clientFactory();
    final p = proxy?.call();
    if (p != null) client.findProxy = (_) => 'PROXY $p';
    client.connectionTimeout = transferTimeout;
    double? down;
    double? up;
    try {
      onProgress?.call(const CallTestProgress(CallTestPhase.download, 0.62));
      down = await _download(client);
      onProgress?.call(const CallTestProgress(CallTestPhase.upload, 0.82));
      up = await _upload(client);
    } finally {
      client.close(force: true);
    }
    onProgress?.call(const CallTestProgress(CallTestPhase.upload, 1));
    return voice.toResult(server: server, downMbps: down, upMbps: up);
  }

  Future<_BurstStats> _voiceBurst(void Function(CallTestProgress)? onProgress) async {
    final (socket, address, port) = await _pickTarget();
    final clock = Stopwatch()..start();
    final sentAt = List<int?>.filled(packets, null);
    final rtt = List<double?>.filled(packets, null);
    final salt = Uint8List.fromList(List.generate(8, (_) => _random.nextInt(256)));
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = socket.receive()) != null) {
        final id = stunResponseTransactionId(d!.data);
        if (id == null || !_sameSalt(id, salt)) continue;
        final seq = ByteData.sublistView(id).getUint32(0);
        final at = seq < packets ? sentAt[seq] : null;
        if (at == null || rtt[seq] != null) continue;
        final ms = (clock.elapsedMicroseconds - at) / 1000;
        if (ms <= lossTimeout.inMilliseconds) rtt[seq] = ms;
      }
    });
    try {
      for (var seq = 0; seq < packets; seq++) {
        sentAt[seq] = clock.elapsedMicroseconds;
        try {
          socket.send(_request(seq, salt), address, port);
        } on SocketException {
          // Counts as lost, like a dropped frame.
        }
        if (seq % 25 == 0) onProgress?.call(CallTestProgress(CallTestPhase.voice, 0.6 * seq / packets));
        final next = (seq + 1) * spacing.inMicroseconds;
        final wait = next - clock.elapsedMicroseconds;
        if (wait > 0) await Future<void>.delayed(Duration(microseconds: wait));
      }
      await Future<void>.delayed(lossTimeout);
    } finally {
      socket.close();
    }
    return _BurstStats.from(rtt, lateAfterMs: lateAfter.inMicroseconds / 1000);
  }

  /// The first server that answers; UDP being blocked shows up as a burst
  /// with no replies at all.
  Future<(RawDatagramSocket, InternetAddress, int)> _pickTarget() async {
    final RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } on SocketException catch (e) {
      throw ProbeUnavailable('UDP socket unavailable: ${e.osError?.message ?? e.message}');
    }
    (InternetAddress, int)? fallback;
    for (final target in targets) {
      InternetAddress? address;
      try {
        final found = await _lookup(target.host).timeout(const Duration(seconds: 3));
        if (found.isNotEmpty) address = found.first;
      } catch (_) {}
      if (address == null) continue;
      fallback ??= (address, target.port);
      final resolved = address;
      final single = StunProber(
        targets: [target],
        timeout: const Duration(seconds: 1),
        lookup: (_) async => [resolved],
      );
      final double? answer;
      try {
        answer = await single.probe();
      } finally {
        single.close();
      }
      if (answer != null) return (socket, resolved, target.port);
    }
    if (fallback == null) {
      socket.close();
      throw const ProbeUnavailable('No call-test server could be resolved (DNS failed)');
    }
    return (socket, fallback.$1, fallback.$2);
  }

  Uint8List _request(int seq, Uint8List salt) {
    // STUN Binding Request padded with a SOFTWARE attribute (optional, so
    // servers ignore it) to the size of a voice packet.
    final pad = max(0, packetBytes - 24);
    final bytes = Uint8List(24 + pad);
    final view = ByteData.sublistView(bytes);
    view.setUint16(0, 0x0001);
    view.setUint16(2, 4 + pad);
    view.setUint32(4, 0x2112A442);
    view.setUint32(8, seq);
    bytes.setRange(12, 20, salt);
    view.setUint16(20, 0x8022);
    view.setUint16(22, pad);
    bytes.fillRange(24, bytes.length, 0x20);
    return bytes;
  }

  static bool _sameSalt(Uint8List id, Uint8List salt) {
    for (var i = 0; i < 8; i++) {
      if (id[4 + i] != salt[i]) return false;
    }
    return true;
  }

  /// Mbps from the first byte to the end (or the time limit).
  Future<double?> _download(HttpClient client) async {
    try {
      final request = await client.getUrl(Uri.parse(downloadUrl)).timeout(transferTimeout);
      final response = await request.close().timeout(transferTimeout);
      if (response.statusCode != 200) {
        await response.drain<void>().catchError((_) {});
        return null;
      }
      var bytes = 0;
      final watch = Stopwatch();
      final done = Completer<void>();
      late StreamSubscription<List<int>> sub;
      sub = response.listen(
        (chunk) {
          if (!watch.isRunning) watch.start();
          bytes += chunk.length;
          if (watch.elapsed > transferTimeout && !done.isCompleted) {
            sub.cancel();
            done.complete();
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        },
        cancelOnError: true,
      );
      await done.future.timeout(transferTimeout * 2);
      final micros = watch.elapsedMicroseconds;
      return micros <= 0 || bytes < 64 * 1024 ? null : bytes * 8 / micros;
    } catch (_) {
      return null;
    }
  }

  Future<double?> _upload(HttpClient client) async {
    try {
      final watch = Stopwatch()..start();
      final request = await client.postUrl(Uri.parse(uploadUrl)).timeout(transferTimeout);
      request.headers.contentType = ContentType.binary;
      request.contentLength = uploadBytes;
      final chunk = Uint8List(64 * 1024);
      for (var sent = 0; sent < uploadBytes; sent += chunk.length) {
        request.add(sent + chunk.length > uploadBytes ? chunk.sublist(0, uploadBytes - sent) : chunk);
      }
      final response = await request.close().timeout(transferTimeout);
      await response.drain<void>();
      if (response.statusCode != 200) return null;
      return uploadBytes * 8 / watch.elapsedMicroseconds;
    } catch (_) {
      return null;
    }
  }
}

/// Loss / jitter analysis of one burst.
class _BurstStats {
  _BurstStats({
    required this.sent,
    required this.received,
    required this.late,
    required this.maxBurst,
    required this.burstRatio,
    this.median,
    this.p95,
    this.jitter,
  });

  final int sent;
  final int received;
  final int late;
  final int maxBurst;
  final double burstRatio;
  final double? median;
  final double? p95;
  final double? jitter;

  factory _BurstStats.from(List<double?> rtt, {required double lateAfterMs}) {
    final replies = rtt.whereType<double>().toList()..sort();
    final median = replies.isEmpty ? null : replies[replies.length ~/ 2];
    final p95 = replies.isEmpty ? null : replies[min(replies.length - 1, (replies.length * 0.95).floor())];
    // A packet is bad for the call if it never came back or came back
    // after the playout buffer gave up on it.
    final bad = [for (final r in rtt) r == null || (median != null && r > median + lateAfterMs)];
    final badCount = bad.where((b) => b).length;
    final late = badCount - (rtt.length - replies.length);
    var bursts = 0, burstPackets = 0, run = 0, maxRun = 0;
    for (final b in bad) {
      if (b) {
        run++;
        maxRun = max(maxRun, run);
      } else if (run > 0) {
        bursts++;
        burstPackets += run;
        run = 0;
      }
    }
    if (run > 0) {
      bursts++;
      burstPackets += run;
    }
    // G.113 burst ratio: observed mean burst length over the mean expected
    // for random loss at the same rate (1 / (1 − p)).
    final p = rtt.isEmpty ? 0.0 : badCount / rtt.length;
    final burstRatio = bursts == 0 || p >= 1 ? 1.0 : max(1.0, burstPackets / bursts * (1 - p));
    double? jitter;
    double? prev;
    var sum = 0.0, n = 0;
    for (final r in rtt) {
      if (r == null) continue;
      if (prev != null) {
        sum += (r - prev).abs();
        n++;
      }
      prev = r;
    }
    if (n > 0) jitter = sum / n;
    return _BurstStats(
      sent: rtt.length,
      received: replies.length,
      late: late,
      maxBurst: maxRun,
      burstRatio: burstRatio,
      median: median,
      p95: p95,
      jitter: jitter,
    );
  }

  CallTestResult toResult({required String server, double? downMbps, double? upMbps}) {
    final effectiveLoss = sent == 0 ? 0.0 : (sent - received + late) * 100 / sent;
    CallQuality quality(CallKind kind) => received == 0
        ? CallQuality(kind: kind, mos: 1, rFactor: 0)
        : CallQuality.estimate(
            kind: kind,
            rttMs: median!,
            jitterMs: jitter ?? 0,
            lossPercent: effectiveLoss,
            burstRatio: burstRatio,
          );
    return CallTestResult(
      at: DateTime.now(),
      server: server,
      sent: sent,
      received: received,
      late: late,
      maxBurst: maxBurst,
      burstRatio: burstRatio,
      rttMedian: median,
      rttP95: p95,
      jitter: jitter,
      voice: quality(CallKind.voice),
      video: quality(CallKind.video),
      downMbps: downMbps,
      upMbps: upMbps,
    );
  }
}

/// The burst analysis without sockets.
@visibleForTesting
CallTestResult analyzeBurstForTest(List<double?> rtt,
        {double lateAfterMs = 120, double? downMbps, double? upMbps}) =>
    _BurstStats.from(rtt, lateAfterMs: lateAfterMs).toResult(server: 't', downMbps: downMbps, upMbps: upMbps);
