import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'ip_tools.dart';

/// What is known about a remote address.
class IpDetails {
  const IpDetails({
    required this.ip,
    required this.kind,
    required this.updatedAt,
    this.host,
    this.countryCode,
    this.country,
    this.org,
  });

  final String ip;
  final IpKind kind;

  /// Reverse DNS name.
  final String? host;
  final String? countryCode;
  final String? country;

  /// Network owner, e.g. "Cloudflare, Inc.".
  final String? org;
  final DateTime updatedAt;

  String get domainKey => domainKeyFor(kind: kind, host: host, org: org, ip: ip);

  IpDetails withHost(String? value) => IpDetails(
        ip: ip,
        kind: kind,
        updatedAt: updatedAt,
        host: value,
        countryCode: countryCode,
        country: country,
        org: org,
      );

  Map<String, Object?> toRow() => {
        'ip': ip,
        'kind': kind.index,
        'domain_key': domainKey,
        'host': host,
        'country_code': countryCode,
        'country': country,
        'org': org,
        'updated_at': updatedAt.millisecondsSinceEpoch ~/ 1000,
      };

  factory IpDetails.fromRow(Map<String, Object?> row) {
    final kindIndex = (row['kind'] as num?)?.toInt() ?? 0;
    return IpDetails(
      ip: row['ip'] as String,
      kind: IpKind.values[kindIndex.clamp(0, IpKind.values.length - 1)],
      host: row['host'] as String?,
      countryCode: row['country_code'] as String?,
      country: row['country'] as String?,
      org: row['org'] as String?,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(((row['updated_at'] as num?)?.toInt() ?? 0) * 1000),
    );
  }

  /// One entry of a geojs.io lookup.
  static IpDetails fromGeoJs(Map<String, dynamic> json, DateTime now) {
    String? s(String k) {
      final v = json[k];
      final text = v == null ? '' : '$v'.trim();
      return (text.isEmpty || text == 'Unknown' || text == 'nil') ? null : text;
    }

    final ip = s('ip') ?? '';
    return IpDetails(
      ip: ip,
      kind: classifyIp(ip),
      updatedAt: now,
      countryCode: s('country_code'),
      country: s('country'),
      org: s('organization_name'),
    );
  }
}

/// Resolves batches of addresses to their details.
typedef IpBatchLookup = Future<IpBatchResult> Function(List<String> ips);

class IpBatchResult {
  const IpBatchResult(this.details, {this.retryAfter});
  final List<IpDetails> details;

  /// Rate-limit hint from the service.
  final Duration? retryAfter;
}

/// Reverse DNS for one address, or null.
typedef ReverseLookup = Future<String?> Function(String ip);

/// Reverse DNS through the system resolver (the lookup service doesn't do
/// reverse lookups).
Future<String?> systemReverseLookup(String ip) async {
  final address = InternetAddress.tryParse(ip);
  if (address == null) return null;
  try {
    final result = await address.reverse().timeout(const Duration(seconds: 4));
    return result.host == ip ? null : result.host;
  } catch (_) {
    return null;
  }
}

/// geojs.io lookups over HTTPS, many addresses per request. Only the
/// addresses are sent.
IpBatchLookup geoJsBatchLookup(http.Client Function() client) {
  return (ips) async {
    final uri = Uri.https('get.geojs.io', '/v1/ip/geo.json', {'ip': ips.join(',')});
    final c = client();
    try {
      final response = await c.get(uri).timeout(const Duration(seconds: 20));
      if (response.statusCode == 429) {
        return const IpBatchResult([], retryAfter: Duration(minutes: 1));
      }
      if (response.statusCode != 200) throw Exception('HTTP ${response.statusCode}');
      final decoded = jsonDecode(response.body);
      final list = decoded is List ? decoded : [decoded];
      final now = DateTime.now();
      return IpBatchResult([
        for (final e in list.whereType<Map>()) IpDetails.fromGeoJs(e.cast<String, dynamic>(), now),
      ]);
    } finally {
      c.close();
    }
  };
}

/// Looks up destination addresses in the background, at most one batch every
/// [minGap], and remembers the answers.
class IpEnricher {
  IpEnricher({
    required this.lookup,
    required this.onResolved,
    this.reverse,
    this.batchSize = 50,
    this.minGap = const Duration(seconds: 5),
    this.refreshAfter = const Duration(days: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final IpBatchLookup lookup;

  /// Optional reverse-DNS step for each looked-up address.
  final ReverseLookup? reverse;

  /// Receives every newly learned set of details (to persist them).
  final void Function(List<IpDetails> details) onResolved;
  final int batchSize;
  final Duration minGap;
  final Duration refreshAfter;
  final DateTime Function() _clock;

  /// When false, public addresses are not sent anywhere.
  bool enabled = true;

  final _known = <String, IpDetails>{};
  final _queue = <String>{}; // insertion-ordered
  Timer? _timer;
  bool _busy = false;
  DateTime _notBefore = DateTime.fromMillisecondsSinceEpoch(0);

  IpDetails? operator [](String ip) => _known[ip];
  int get pending => _queue.length;

  /// Forgets everything looked up (history was cleared).
  void clear() {
    _known.clear();
    _queue.clear();
  }

  void preload(Iterable<IpDetails> details) {
    for (final d in details) {
      _known[d.ip] = d;
    }
  }

  /// Notes an address seen in traffic. Local / special ranges are classified
  /// on the spot; public ones are queued for lookup.
  void enqueue(String ip) {
    if (ip.isEmpty || _queue.contains(ip)) return;
    final known = _known[ip];
    final kind = known?.kind ?? classifyIp(ip);
    if (kind != IpKind.public) {
      if (known == null) {
        final details = IpDetails(ip: ip, kind: kind, updatedAt: _clock());
        _known[ip] = details;
        onResolved([details]);
      }
      return;
    }
    final fresh = known != null &&
        (known.countryCode != null || known.org != null) &&
        _clock().difference(known.updatedAt) < refreshAfter;
    if (fresh || !enabled) return;
    // A failed lookup is retried, but not more than once an hour.
    if (known != null && _clock().difference(known.updatedAt) < const Duration(hours: 1)) return;
    _queue.add(ip);
    _schedule(Duration.zero);
  }

  void _schedule(Duration delay) {
    if (_timer != null || _queue.isEmpty) return;
    final wait = _notBefore.difference(_clock());
    _timer = Timer(wait > delay ? wait : delay, () {
      _timer = null;
      _runBatch();
    });
  }

  /// Runs one batch now. Public for tests.
  Future<void> runBatch() => _runBatch();

  Future<void> _runBatch() async {
    if (_busy || _queue.isEmpty || !enabled) return;
    _busy = true;
    final batch = _queue.take(batchSize).toList();
    try {
      final result = await lookup(batch);
      final now = _clock();
      _notBefore = now.add(result.retryAfter ?? minGap);
      // Rate limited: nothing was answered, the batch stays queued.
      if (result.details.isEmpty && result.retryAfter != null) return;
      final byIp = {for (final d in result.details) d.ip: d};
      final learned = <IpDetails>[];
      for (final ip in batch) {
        // Unanswered addresses are remembered as "looked up, nothing known"
        // so they aren't retried right away.
        final details = byIp[ip] ?? IpDetails(ip: ip, kind: IpKind.public, updatedAt: now);
        _known[ip] = details;
        learned.add(details);
        _queue.remove(ip);
      }
      await _addReverseNames(learned);
      onResolved(learned);
    } catch (_) {
      _notBefore = _clock().add(const Duration(seconds: 30));
    } finally {
      _busy = false;
      _schedule(minGap);
    }
  }

  /// Resolves host names a few at a time, updating [details] in place.
  Future<void> _addReverseNames(List<IpDetails> details) async {
    final reverse = this.reverse;
    if (reverse == null) return;
    const parallel = 8;
    for (var start = 0; start < details.length; start += parallel) {
      final end = (start + parallel).clamp(0, details.length);
      await Future.wait([
        for (var i = start; i < end; i++)
          reverse(details[i].ip).then((host) {
            if (host == null) return;
            details[i] = details[i].withHost(host);
            _known[details[i].ip] = details[i];
          }),
      ]);
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
