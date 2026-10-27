import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:ir_net/data/kerio.dart';

import '../data/shared_preferences.dart';

typedef _KerioAccount = ({String ip, String username, String password});

class KerioUtils {
  /// Logs in to the Kerio web interface with the saved credentials.
  static Future<void> login({http.Client Function() client = http.Client.new}) async {
    await _withAccount('login', client, _login);
  }

  /// The account's monthly balance, or null when Kerio isn't set up or the
  /// check fails.
  static Future<KerioBalance?> getAccountBalance({http.Client Function() client = http.Client.new}) {
    return _withAccount('balance check', client, _fetchBalance);
  }

  /// Runs [request] with the saved Kerio address and credentials. While any of
  /// them is missing (as on a fresh install) nothing is sent and null is
  /// returned; failures are logged and return null as well.
  static Future<T?> _withAccount<T>(
    String name,
    http.Client Function() client,
    Future<T> Function(http.Client client, _KerioAccount account) request,
  ) async {
    final ip = (await AppSharedPreferences.kerioIP)?.trim() ?? '';
    final username = await AppSharedPreferences.kerioUsername ?? '';
    final password = await AppSharedPreferences.kerioPassword ?? '';
    if (ip.isEmpty || username.isEmpty || password.isEmpty) {
      return null;
    }
    final c = client();
    try {
      return await request(c, (ip: ip, username: username, password: password));
    } catch (e) {
      // Unreachable server, rejected login or an unexpected response.
      debugPrint('Kerio $name failed: $e');
      return null;
    } finally {
      c.close();
    }
  }

  static Future<http.Response> _login(http.Client client, _KerioAccount account) {
    return client.post(
      Uri.parse('http://${account.ip}/internal/dologin.php'),
      body: {
        'kerio_username': account.username,
        'kerio_password': account.password,
      },
    );
  }

  static Future<KerioBalance> _fetchBalance(http.Client client, _KerioAccount account) async {
    final ip = account.ip;

    // Step 1: Login and extract cookie
    final loginResponse = await _login(client, account);

    final cookieHeader = loginResponse.headers['set-cookie'];
    if (cookieHeader == null || !cookieHeader.contains('TOKEN_CONTROL_WEBIFACE=')) {
      throw Exception('Login failed or TOKEN_CONTROL_WEBIFACE not found.');
    }

    final cookies = cookieHeader.split(',');
    final tokenCookie = cookies
        .map((c) => c.trim())
        .firstWhere(
          (c) => c.startsWith('TOKEN_CONTROL_WEBIFACE='),
      orElse: () => throw Exception('TOKEN_CONTROL_WEBIFACE not found in cookies'),
    );

    final token = tokenCookie.split('=')[1].split(';')[0];

    final rawCookies = cookieHeader.split(',');
    final cookieMap = <String, String>{};
    for (var cookie in rawCookies) {
      final parts = cookie.split(';')[0].trim(); // Take only key=value part
      final kv = parts.split('=');
      if (kv.length == 2) {
        cookieMap[kv[0]] = kv[1];
      }
    }
    final cookieHeaderValue = cookieMap.entries.map((e) => '${e.key}=${e.value}').join('; ');

    // Step 2: Prepare headers
    final balanceUrl = 'http://$ip/lib/api/jsonrpc/';
    final headers = {
      'Accept': '*/*',
      'Accept-Language': 'en-US,en;q=0.9,fa;q=0.8',
      'Connection': 'keep-alive',
      'Content-Type': 'application/json',
      'Origin': 'http://$ip',
      'Referer': 'http://$ip/',
      'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
      'X-Requested-With': 'XMLHttpRequest',
      'X-Token': token,
      'Cookie': cookieHeaderValue
    };

    // Step 3: Body
    final body = jsonEncode({
      "jsonrpc": "2.0",
      "id": 1,
      "method": "Batch.run",
      "params": {
        "commandList": [
          {"method": "MyAccount.get"},
          {"method": "MyAccount.getRasIntefaces"}
        ]
      }
    });

    // Step 4: Send request
    final balanceResponse = await client.post(
      Uri.parse(balanceUrl),
      headers: headers,
      body: body,
    );

    if (balanceResponse.statusCode != 200) {
      throw Exception('Failed to fetch balance data');
    }

    final data = jsonDecode(balanceResponse.body);
    final quota = data['result'][0]['result']['quota']['month'];

    final total = int.parse(quota['value']);
    final down = int.parse(quota['down']);
    final up = int.parse(quota['up']);
    final remaining = total - (down + up);

    return KerioBalance(total, remaining);
  }

  static String formatBytes(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;

    if (bytes >= gb) {
      return '${(bytes / gb).toStringAsFixed(2)} GB';
    } else if (bytes >= mb) {
      return '${(bytes / mb).toStringAsFixed(2)} MB';
    } else if (bytes >= kb) {
      return '${(bytes / kb).toStringAsFixed(2)} KB';
    } else {
      return '$bytes B';
    }
  }
}