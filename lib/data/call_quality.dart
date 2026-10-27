import 'dart:math' as math;

import 'quality.dart';

/// Pieces of the ITU-T G.107 E-model, the standard model for voice-call
/// quality. R (0–100) combines delay and loss impairments; MOS (1–4.5) is
/// the familiar "call quality" scale Teams, Zoom and VoIP monitors report.
class EModel {
  EModel._();

  /// R with no impairments (default Ro − Is).
  static const baseR = 93.2;

  /// Delay impairment Id for a one-way mouth-to-ear delay in ms
  /// (the usual G.107 approximation by Cole & Rosenbluth).
  static double delayImpairment(double oneWayMs) {
    final d = math.max(0.0, oneWayMs);
    return 0.024 * d + (d > 177.3 ? 0.11 * (d - 177.3) : 0);
  }

  /// Effective equipment impairment Ie,eff for [lossPercent] packet loss.
  /// [ie] is the codec's own impairment, [bpl] its loss robustness and
  /// [burstRatio] how clustered the losses are (1 = random).
  static double lossImpairment(double lossPercent, {double ie = 0, double bpl = 25.1, double burstRatio = 1}) {
    final p = lossPercent.clamp(0.0, 100.0);
    return ie + (95 - ie) * p / (p / math.max(1.0, burstRatio) + bpl);
  }

  /// R → MOS (G.107 Annex B).
  static double mosFromR(double r) {
    if (r <= 0) return 1;
    if (r >= 100) return 4.5;
    return 1 + 0.035 * r + 7e-6 * r * (r - 60) * (100 - r);
  }
}

enum CallKind { voice, video }

extension CallKindLabel on CallKind {
  String get label => this == CallKind.voice ? 'Voice call' : 'Video call';
}

/// Estimated quality of a voice or video call over the measured path.
class CallQuality {
  const CallQuality({
    required this.kind,
    required this.mos,
    required this.rFactor,
    this.viaTcp = false,
  });

  final CallKind kind;

  /// Mean opinion score, 1 (bad) – 4.5 (best possible).
  final double mos;
  final double rFactor;

  /// UDP doesn't get through, so call apps fall back to TCP relays; the
  /// estimate is then based on the HTTPS probes.
  final bool viaTcp;

  QualityGrade get grade => gradeOfMos(mos);

  /// G.107 user-satisfaction bands (R 90 / 80 / 70 / 60).
  static QualityGrade gradeOfMos(double mos) {
    if (mos >= 4.34) return QualityGrade.excellent;
    if (mos >= 4.03) return QualityGrade.good;
    if (mos >= 3.60) return QualityGrade.fair;
    if (mos >= 3.10) return QualityGrade.poor;
    return QualityGrade.bad;
  }

  /// Codec packetisation + algorithmic delay added on top of the network.
  static const codecDelayMs = 25.0;

  /// Estimates call quality from round-trip time, jitter and loss.
  ///
  /// One-way delay is half the RTT plus the codec delay plus a jitter
  /// buffer sized like an adaptive one (twice the jitter, at least 20 ms).
  /// Voice uses the E-model's reference loss robustness (Bpl 25.1, a codec
  /// with packet-loss concealment). Video calls freeze and drop frames on
  /// losses that voice concealment hides, so video is modelled with a lower
  /// robustness (Bpl 10) — an estimate, not a standardised video score.
  static CallQuality estimate({
    required CallKind kind,
    required double rttMs,
    required double jitterMs,
    required double lossPercent,
    double burstRatio = 1,
    bool viaTcp = false,
  }) {
    final buffer = math.max(20.0, 2 * jitterMs);
    final oneWay = rttMs / 2 + buffer + codecDelayMs;
    final r = (EModel.baseR -
            EModel.delayImpairment(oneWay) -
            EModel.lossImpairment(lossPercent, bpl: kind == CallKind.voice ? 25.1 : 10, burstRatio: burstRatio))
        .clamp(0.0, 100.0);
    return CallQuality(kind: kind, mos: EModel.mosFromR(r), rFactor: r, viaTcp: viaTcp);
  }
}

extension QualityStatsCalls on QualityStats {
  /// Call quality estimated from the regular probes: the UDP series when UDP
  /// gets through (calls use UDP), otherwise HTTPS (TCP fallback).
  CallQuality? call(CallKind kind) {
    final viaTcp = udp.received == 0 && http.received > 0;
    final series = viaTcp ? http : udp;
    if (series.sent == 0) return null;
    if (series.received == 0) {
      return CallQuality(kind: kind, mos: 1, rFactor: 0, viaTcp: viaTcp);
    }
    return CallQuality.estimate(
      kind: kind,
      rttMs: series.avgRtt!,
      jitterMs: series.jitter ?? 0,
      lossPercent: series.lossPercent ?? 0,
      viaTcp: viaTcp,
    );
  }
}

/// Video resolution a link can carry, from typical 1:1 call requirements
/// (Zoom / Meet: ~0.6 Mbps for SD, ~1.2 Mbps for 720p, ~3 Mbps for 1080p,
/// each direction).
enum VideoTier {
  fullHd('Full HD 1080p', 3.0),
  hd('HD 720p', 1.2),
  sd('SD 360p', 0.6),
  audioOnly('Audio only', 0);

  const VideoTier(this.label, this.minMbps);

  final String label;
  final double minMbps;

  static VideoTier of(double downMbps, double upMbps) {
    final slowest = math.min(downMbps, upMbps);
    return VideoTier.values.firstWhere((t) => slowest >= t.minMbps);
  }
}

/// Outcome of a simulated call: a burst of voice-sized UDP packets every
/// 20 ms, then a short bandwidth check for video.
class CallTestResult {
  const CallTestResult({
    required this.at,
    required this.server,
    required this.sent,
    required this.received,
    required this.late,
    required this.maxBurst,
    required this.burstRatio,
    required this.voice,
    required this.video,
    this.rttMedian,
    this.rttP95,
    this.jitter,
    this.downMbps,
    this.upMbps,
  });

  final DateTime at;

  /// Exit IP the test ran on.
  final String server;
  final int sent;
  final int received;

  /// Replies that came back too late for a call's playout buffer.
  final int late;

  /// Longest run of consecutive lost / late packets.
  final int maxBurst;
  final double burstRatio;
  final double? rttMedian;
  final double? rttP95;
  final double? jitter;
  final CallQuality voice;
  final CallQuality video;

  /// Null when the bandwidth check failed.
  final double? downMbps;
  final double? upMbps;

  bool get udpBlocked => sent > 0 && received == 0;
  double get lossPercent => sent == 0 ? 0 : (sent - received) * 100 / sent;
  double get latePercent => sent == 0 ? 0 : late * 100 / sent;
  VideoTier? get tier => (downMbps == null || upMbps == null) ? null : VideoTier.of(downMbps!, upMbps!);

  Map<String, Object?> toRow() => {
        'ts': at.millisecondsSinceEpoch ~/ 1000,
        'server': server,
        'sent': sent,
        'received': received,
        'late': late,
        'max_burst': maxBurst,
        'burst_ratio': burstRatio,
        'rtt_median': rttMedian,
        'rtt_p95': rttP95,
        'jitter': jitter,
        'voice_mos': voice.mos,
        'video_mos': video.mos,
        'via_tcp': voice.viaTcp ? 1 : 0,
        'down_mbps': downMbps,
        'up_mbps': upMbps,
      };

  factory CallTestResult.fromRow(Map<String, Object?> row) {
    double? d(String k) => (row[k] as num?)?.toDouble();
    int i(String k) => (row[k] as num?)?.toInt() ?? 0;
    final viaTcp = i('via_tcp') == 1;
    double mos(String k) => d(k) ?? 1;
    return CallTestResult(
      at: DateTime.fromMillisecondsSinceEpoch(i('ts') * 1000),
      server: row['server'] as String,
      sent: i('sent'),
      received: i('received'),
      late: i('late'),
      maxBurst: i('max_burst'),
      burstRatio: d('burst_ratio') ?? 1,
      rttMedian: d('rtt_median'),
      rttP95: d('rtt_p95'),
      jitter: d('jitter'),
      voice: CallQuality(kind: CallKind.voice, mos: mos('voice_mos'), rFactor: 0, viaTcp: viaTcp),
      video: CallQuality(kind: CallKind.video, mos: mos('video_mos'), rFactor: 0, viaTcp: viaTcp),
      downMbps: d('down_mbps'),
      upMbps: d('up_mbps'),
    );
  }
}
