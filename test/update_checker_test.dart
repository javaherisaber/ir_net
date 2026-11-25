import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ir_net/utils/update_checker.dart';

void main() {
  test('versions compare by their numbers, not as text', () {
    expect(UpdateChecker.isNewer('1.7.0', '1.6.0'), isTrue);
    expect(UpdateChecker.isNewer('v1.10.0', '1.9.2+13'), isTrue);
    expect(UpdateChecker.isNewer('1.6.1', '1.6'), isTrue);
    expect(UpdateChecker.isNewer('1.6.0', '1.6.0+13'), isFalse, reason: 'the build number doesn\'t count');
    expect(UpdateChecker.isNewer('1.5.9', '1.6.0'), isFalse);
    expect(UpdateChecker.isNewer('1.7.0', '1.7.0-beta'), isTrue, reason: 'a release beats its pre-release');
    expect(UpdateChecker.isNewer('1.7.0-beta', '1.7.0'), isFalse);
  });

  group('the latest GitHub release', () {
    late Map<String, dynamic> release;
    late int status;
    final requests = <http.Request>[];

    UpdateChecker checker() => UpdateChecker(
          client: MockClient((request) async {
            requests.add(request);
            return http.Response(jsonEncode(release), status, headers: {'content-type': 'application/json'});
          }),
        );

    setUp(() {
      requests.clear();
      status = 200;
      release = {
        'tag_name': '1.7.0',
        'name': '1.7.0',
        'html_url': 'https://github.com/javaherisaber/ir_net/releases/tag/1.7.0',
        'draft': false,
        'prerelease': false,
      };
    });

    test('a newer release comes back with its page', () async {
      final info = await checker().newerThan('1.6.0');
      expect(info!.version, '1.7.0');
      expect(info.url, 'https://github.com/javaherisaber/ir_net/releases/tag/1.7.0');
      expect(requests.single.url.toString(), 'https://api.github.com/repos/javaherisaber/ir_net/releases/latest');
      expect(requests.single.headers['User-Agent'], 'IRNet', reason: 'GitHub requires one');
    });

    test('nothing when up to date, or when the newest is a pre-release', () async {
      expect(await checker().newerThan('1.7.0'), isNull);
      release['prerelease'] = true;
      expect(await checker().newerThan('1.6.0'), isNull);
    });

    test('a link that isn\'t GitHub\'s falls back to the releases page', () async {
      release['html_url'] = 'https://example.com/fake';
      expect((await checker().newerThan('1.6.0'))!.url, UpdateChecker.releasesPage);
    });

    test('a refusal (e.g. rate limit) is an error, not "up to date"', () async {
      status = 403;
      release = {'message': 'API rate limit exceeded'};
      expect(checker().newerThan('1.6.0'), throwsA(isA<http.ClientException>()));
    });
  });
}
