// Kerio is optional: until its address, username and password are all saved
// (a fresh install only has the default address) the login and balance checks
// must not send anything, and a failing server shows the "--" balance instead
// of throwing. Any uncaught error from those checks fails the test.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ir_net/bloc.dart';
import 'package:ir_net/data/kerio.dart';
import 'package:ir_net/data/shared_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _gb = 1024 * 1024 * 1024;

void main() {
  late List<http.Request> requests;
  late MockClientHandler server;

  setUpAll(() {
    // AppBloc creates a system-tray window handle on construction.
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter/system_tray/app_window'), (call) async => null);
    // Only once: AppSharedPreferences keeps the first instance it gets.
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() async {
    await (await SharedPreferences.getInstance()).clear();
    requests = [];
    server = (_) async => http.Response('', 200);
  });

  AppBloc newBloc() => AppBloc()
    ..kerioClient = () => MockClient((request) {
          requests.add(request);
          return server(request);
        });

  Future<void> saveAccount({required String ip}) async {
    await AppSharedPreferences.setKerioIP(ip);
    await AppSharedPreferences.setKerioUsername('user');
    await AppSharedPreferences.setKerioPassword('secret');
  }

  group('sends no Kerio requests and shows "--"', () {
    test('on a fresh install (no username or password)', () async {
      await AppSharedPreferences.setKerioIP('172.18.18.1:4080'); // main.dart's default
      final bloc = newBloc();

      bloc.onKerioLoginClick();

      expect(await bloc.kerioBalance.first, same(KerioBalance.none));
      expect(requests, isEmpty);
    });

    test('with a blank address', () async {
      await saveAccount(ip: '  ');
      final bloc = newBloc();

      bloc.onKerioLoginClick();

      expect(await bloc.kerioBalance.first, same(KerioBalance.none));
      expect(requests, isEmpty);
    });
  });

  test('shows the balance, then "--" once the server fails', () async {
    await saveAccount(ip: '172.18.18.1:4080');
    server = (request) async => request.url.path == '/internal/dologin.php'
        ? http.Response('', 200, headers: {
            'set-cookie': 'TOKEN_CONTROL_WEBIFACE=t0k3n; path=/, SESSION_CONTROL_WEBIFACE=s1; path=/',
          })
        : http.Response(
            jsonEncode({
              'result': [
                {
                  'result': {
                    'quota': {
                      'month': {'value': '${10 * _gb}', 'down': '${_gb * 3 ~/ 4}', 'up': '${_gb ~/ 4}'},
                    },
                  },
                },
              ],
            }),
            200);
    final bloc = newBloc();

    bloc.onKerioLoginClick();

    final balance = await bloc.kerioBalance.first;
    expect(balance.total, 10 * _gb);
    expect(balance.remaining, 9 * _gb);
    expect(requests.map((r) => r.url.toString()), [
      'http://172.18.18.1:4080/internal/dologin.php', // the login itself
      'http://172.18.18.1:4080/internal/dologin.php', // the balance check's session
      'http://172.18.18.1:4080/lib/api/jsonrpc/',
    ]);
    expect(requests.first.bodyFields, {'kerio_username': 'user', 'kerio_password': 'secret'});
    expect(requests.last.headers['X-Token'], 't0k3n');

    server = (_) async => throw http.ClientException('Connection refused');
    final next = bloc.kerioBalance.skip(1).first; // skips the balance shown now

    bloc.onKerioLoginClick();

    expect(await next, same(KerioBalance.none));
  });
}
