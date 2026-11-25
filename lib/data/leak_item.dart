import 'dart:async';
import 'dart:io';

class LeakItem {
  LeakItem(this.url, {this.status});

  final String url;
  LeakStatus? status;

  /// Why the last check failed (status failed).
  LeakFailure? failure;

  /// How long the last successful check took.
  int? ms;

  static List<String> prePopulatedUrls() {
    return [
      'https://developer.android.com',
      'https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/4.1.3/gradle-4.1.3.pom',
      'https://pub.dev/api/archives/live_event-1.0.0.tar.gz'
    ];
  }
}

enum LeakStatus { failed, passed, loading }

enum LeakFailureKind { timeout, dns, reset, refused, network, tls, filtered, blocked, http, other }

/// Why a monitored site couldn't be reached, in words a user can act on:
/// [title] names it, [explanation] says what it suggests, and [detail] is
/// the technical message.
class LeakFailure {
  const LeakFailure(this.kind, this.title, this.explanation, this.detail);

  final LeakFailureKind kind;
  final String title;
  final String explanation;
  final String detail;

  static const _timeoutSeconds = 10;

  /// From an exception thrown by the check.
  factory LeakFailure.from(Object error) {
    if (error is TimeoutException) {
      return const LeakFailure(LeakFailureKind.timeout, 'Timed out',
          'No answer within $_timeoutSeconds seconds. The site may be filtered, or the connection is too slow.',
          'No response within $_timeoutSeconds s');
    }
    if (error is HandshakeException || error is TlsException) {
      return LeakFailure(LeakFailureKind.tls, 'Secure connection failed',
          'The TLS handshake failed. Something in the path may be intercepting or blocking the connection.',
          _message(error));
    }
    if (error is SocketException) {
      final msg = error.message.toLowerCase();
      final os = error.osError;
      final code = os?.errorCode;
      final osMsg = (os?.message ?? '').toLowerCase();
      final detail = _message(error);
      bool has(String s) => msg.contains(s) || osMsg.contains(s);
      if (has('failed host lookup') || has('no address associated') || has('nodename nor servname') ||
          has('name or service not known') || has('no such host')) {
        return LeakFailure(LeakFailureKind.dns, 'Couldn\'t find the site',
            'Its name didn\'t resolve. DNS may be blocked or tampered with, or there\'s no connection.', detail);
      }
      if (const {54, 104, 10054}.contains(code) || has('connection reset') || has('broken pipe')) {
        return LeakFailure(LeakFailureKind.reset, 'Connection cut',
            'The connection was reset before the site answered, which is typical of a filter in the path.',
            detail);
      }
      if (const {61, 111, 10061}.contains(code) || has('connection refused')) {
        return LeakFailure(LeakFailureKind.refused, 'Connection refused',
            'The server (or a proxy on the way) refused the connection.', detail);
      }
      if (const {50, 51, 65, 101, 113, 10050, 10051, 10065}.contains(code) ||
          has('network is unreachable') || has('no route to host') || has('host is unreachable')) {
        return LeakFailure(LeakFailureKind.network, 'No route to the site',
            'The network couldn\'t reach it. Check the internet connection.', detail);
      }
      if (const {60, 110, 10060}.contains(code) || has('timed out')) {
        return LeakFailure(LeakFailureKind.timeout, 'Timed out',
            'The connection attempt got no answer. The site may be filtered, or the connection is too slow.',
            detail);
      }
      return LeakFailure(LeakFailureKind.other, 'Connection failed', 'The site couldn\'t be reached.', detail);
    }
    return LeakFailure(LeakFailureKind.other, 'Check failed', 'The site couldn\'t be checked.', _message(error));
  }

  /// From an HTTP answer that isn't a success.
  factory LeakFailure.http(int status, String reason) {
    final detail = 'HTTP $status${reason.isEmpty ? '' : ' $reason'}';
    if (status == 403 || status == 451) {
      return LeakFailure(LeakFailureKind.blocked, 'Blocked for your location ($status)',
          'The site refuses visitors from where you appear to be (sanctions or region locks). Your traffic to it '
              'may not be going through the VPN.',
          detail);
    }
    if (status == 407) {
      return LeakFailure(
          LeakFailureKind.http, 'Proxy wants a login (407)', 'A proxy on the way asked for credentials.', detail);
    }
    if (status == 404 || status == 410) {
      return LeakFailure(LeakFailureKind.http, 'Not found ($status)',
          'The site answered, but this address doesn\'t exist anymore. Try another URL.', detail);
    }
    if (status == 429) {
      return LeakFailure(LeakFailureKind.http, 'Too many requests (429)',
          'The site is rate-limiting this address. It answered, so it isn\'t blocked.', detail);
    }
    if (status >= 500) {
      return LeakFailure(LeakFailureKind.http, 'Server error ($status)',
          'The site answered with an error of its own. Try again later.', detail);
    }
    return LeakFailure(LeakFailureKind.http, 'Unexpected answer ($status)',
        'The site answered, but not with the page.', detail);
  }

  /// Redirected to Iran's filtering page (10.10.34.x, peyvandha.ir).
  factory LeakFailure.filtered(Uri location) => LeakFailure(LeakFailureKind.filtered, 'Filtered',
      'You were sent to Iran\'s filtering page, so this site isn\'t going through the VPN.', 'Redirected to $location');

  static bool isFilterPage(Uri location) {
    final host = location.host.toLowerCase();
    return host.startsWith('10.10.34.') || host == 'peyvandha.ir' || host.endsWith('.peyvandha.ir');
  }

  static String _message(Object error) {
    final text = error.toString().trim();
    return text.length > 240 ? '${text.substring(0, 237)}…' : text;
  }
}
