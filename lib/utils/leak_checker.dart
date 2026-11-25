import 'dart:async';
import 'dart:io';

import 'package:ir_net/data/leak_item.dart';

class LeakCheckResult {
  const LeakCheckResult.reachable(this.ms) : failure = null;
  const LeakCheckResult.failed(LeakFailure this.failure) : ms = null;

  final int? ms;
  final LeakFailure? failure;

  bool get ok => failure == null;
}

/// Checks that a monitored site answers, and says why when it doesn't.
/// Redirects are followed by hand so a jump to Iran's filtering page is
/// caught without loading it; servers that refuse HEAD get a one-byte GET.
class LeakChecker {
  LeakChecker({this.timeout = const Duration(seconds: 10), this.maxRedirects = 5});

  final Duration timeout;
  final int maxRedirects;

  /// [proxy] is "host:port" (or "user:pass@host:port") or null for direct.
  Future<LeakCheckResult> check(String url, {String? proxy}) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = 'IRNet';
    client.findProxy = proxy == null ? (_) => 'DIRECT' : (_) => 'PROXY $proxy';
    final deadline = DateTime.now().add(timeout);
    final watch = Stopwatch()..start();
    try {
      var uri = Uri.parse(url);
      var method = 'HEAD';
      for (var hop = 0;; hop++) {
        final left = deadline.difference(DateTime.now());
        if (left <= Duration.zero) throw TimeoutException('leak check');
        final request = await client.openUrl(method, uri).timeout(left);
        request.followRedirects = false;
        if (method == 'GET') request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
        final response = await request.close().timeout(left);
        await response.drain<void>().timeout(deadline.difference(DateTime.now()));
        final status = response.statusCode;
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (const {301, 302, 303, 307, 308}.contains(status) && location != null) {
          final next = uri.resolve(location);
          if (LeakFailure.isFilterPage(next)) return LeakCheckResult.failed(LeakFailure.filtered(next));
          if (hop >= maxRedirects) return LeakCheckResult.failed(LeakFailure.http(status, 'Too many redirects'));
          uri = next;
          continue;
        }
        // Some servers don't answer HEAD; ask for one byte instead.
        if ((status == 405 || status == 501) && method == 'HEAD') {
          method = 'GET';
          continue;
        }
        if (status >= 200 && status < 300) return LeakCheckResult.reachable(watch.elapsedMilliseconds);
        return LeakCheckResult.failed(LeakFailure.http(status, response.reasonPhrase));
      }
    } catch (e) {
      return LeakCheckResult.failed(LeakFailure.from(e));
    } finally {
      client.close(force: true);
    }
  }
}
