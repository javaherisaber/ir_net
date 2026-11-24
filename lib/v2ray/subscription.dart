import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'share_link.dart';

class SubscriptionException implements Exception {
  const SubscriptionException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Subscription metadata from response headers and/or `#key: value` lines at
/// the top of the body (the convention Happ, Hiddify and Marzban-style
/// panels share).
class SubscriptionMeta {
  const SubscriptionMeta({
    this.title,
    this.usage,
    this.updateIntervalHours,
    this.supportUrl,
    this.webPageUrl,
    this.announce,
  });

  final String? title;
  final SubscriptionUsage? usage;
  final int? updateIntervalHours;
  final String? supportUrl;
  final String? webPageUrl;
  final String? announce;
}

class SubscriptionResult {
  const SubscriptionResult(this.links, this.meta);
  final ParsedLinks links;
  final SubscriptionMeta meta;
}

class SubscriptionClient {
  SubscriptionClient({required this.httpClient, this.userAgent = defaultUserAgent});

  /// Creates the client for one fetch (lets the caller route it through the
  /// VPN while connected).
  final http.Client Function() httpClient;
  final String userAgent;

  /// Panels pick the response format from the User-Agent. A v2rayN-style
  /// agent gets the plain base64 share-link list (plus the
  /// subscription-userinfo header) from Marzban, 3x-ui, Hiddify Manager and
  /// most others; versions before 6.40 never get Xray JSON.
  static const defaultUserAgent = 'v2rayN/6.31';

  static const timeout = Duration(seconds: 25);

  Future<SubscriptionResult> fetch(String url, {required String subscriptionId}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
      throw const SubscriptionException('Not a valid subscription URL');
    }
    final client = httpClient();
    http.Response response;
    try {
      response = await client.get(uri, headers: {
        'User-Agent': userAgent,
        'Accept': '*/*',
      }).timeout(timeout);
    } on TimeoutException {
      throw const SubscriptionException('The subscription server did not answer in time');
    } on http.ClientException catch (e) {
      throw SubscriptionException('Could not reach the subscription server (${e.message})');
    } catch (e) {
      throw SubscriptionException('Could not reach the subscription server ($e)');
    } finally {
      client.close();
    }
    if (response.statusCode != 200) {
      throw SubscriptionException('The subscription server answered HTTP ${response.statusCode}');
    }
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    return parse(body, response.headers, url: url, subscriptionId: subscriptionId);
  }

  /// Turns a downloaded subscription into configs + metadata.
  static SubscriptionResult parse(String body, Map<String, String> headers,
      {required String url, required String subscriptionId}) {
    final trimmed = body.trim();
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('<!doctype html') || lower.startsWith('<html')) {
      throw const SubscriptionException('The link opened a web page, not a subscription');
    }
    var text = trimmed;
    if (!text.contains('://')) {
      final decoded = ShareLinkParser.decodeBase64Loose(text);
      if (decoded != null) text = decoded;
    }
    final links = ShareLinkParser.parseText(text, subscriptionId: subscriptionId);
    if (links.profiles.isEmpty) {
      if (lower.startsWith('{') || lower.startsWith('[')) {
        throw const SubscriptionException('The server sent Xray/sing-box JSON, which IRNet can\'t read yet');
      }
      if (links.unsupported > 0) {
        throw const SubscriptionException('The subscription has no VLESS, VMess, Trojan or WireGuard configs');
      }
      throw const SubscriptionException('No configs found in the subscription');
    }
    return SubscriptionResult(links, parseMeta(headers, text, url: url));
  }

  /// Headers win over body directives; keys are case-insensitive.
  static SubscriptionMeta parseMeta(Map<String, String> headers, String text, {String? url}) {
    final values = <String, String>{};
    for (final line in const LineSplitter().convert(text)) {
      var l = line.trim();
      if (l.startsWith('//')) {
        l = l.substring(2);
      } else if (l.startsWith('#')) {
        l = l.substring(1);
      } else {
        continue;
      }
      final colon = l.indexOf(':');
      if (colon < 1) continue;
      final key = l.substring(0, colon).trim().toLowerCase();
      final value = l.substring(colon + 1).trim();
      if (key.isNotEmpty && value.isNotEmpty) values.putIfAbsent(key, () => value);
    }
    headers.forEach((k, v) {
      if (v.trim().isNotEmpty) values[k.toLowerCase()] = v.trim();
    });

    String? title = values['profile-title'] != null ? decodeTitle(values['profile-title']!) : null;
    if (title == null || title.isEmpty) title = _filename(values['content-disposition']);
    final interval = double.tryParse(values['profile-update-interval'] ?? '');
    return SubscriptionMeta(
      title: title == null || title.isEmpty ? null : title,
      usage: values['subscription-userinfo'] == null ? null : parseUserInfo(values['subscription-userinfo']!),
      updateIntervalHours: interval == null || interval <= 0 ? null : interval.ceil(),
      supportUrl: _url(values['support-url']),
      webPageUrl: _url(values['profile-web-page-url']),
      announce: values['announce'] == null ? null : decodeTitle(values['announce']!),
    );
  }

  /// `upload=1; download=2; total=3; expire=4` (any order, extra spaces,
  /// float values tolerated). expire=0 means it never expires.
  static SubscriptionUsage? parseUserInfo(String value) {
    final fields = <String, int>{};
    for (final part in value.split(RegExp(r'[;,]'))) {
      final eq = part.indexOf('=');
      if (eq < 0) continue;
      final n = num.tryParse(part.substring(eq + 1).trim());
      if (n != null) fields[part.substring(0, eq).trim().toLowerCase()] = n.toInt();
    }
    if (fields.isEmpty) return null;
    final expire = fields['expire'];
    return SubscriptionUsage(
      upload: fields['upload'] ?? 0,
      download: fields['download'] ?? 0,
      total: fields['total'] ?? 0,
      expire: expire == null || expire <= 0 ? null : expire,
    );
  }

  /// `base64:…` encoded titles, plain text, or percent-encoded text.
  static String decodeTitle(String value) {
    final v = value.trim();
    if (v.toLowerCase().startsWith('base64:')) {
      return (ShareLinkParser.decodeBase64Loose(v.substring(7)) ?? '').trim();
    }
    try {
      return Uri.decodeComponent(v).trim();
    } catch (_) {
      return v;
    }
  }

  /// Name for a subscription that didn't send a title.
  static String fallbackName(String url) {
    final uri = Uri.tryParse(url);
    return uri == null || uri.host.isEmpty ? 'Subscription' : uri.host;
  }

  static String? _filename(String? disposition) {
    if (disposition == null) return null;
    final star = RegExp(r"filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)").firstMatch(disposition);
    if (star != null) {
      try {
        return Uri.decodeComponent(star.group(1)!.trim());
      } catch (_) {}
    }
    final plain = RegExp(r'filename\s*=\s*"?([^";]+)"?').firstMatch(disposition);
    return plain?.group(1)?.trim();
  }

  static String? _url(String? value) {
    if (value == null) return null;
    final uri = Uri.tryParse(value.trim());
    return uri != null && uri.hasScheme ? value.trim() : null;
  }
}
