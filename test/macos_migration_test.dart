import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/utils/macos_migration.dart';

// What `plutil -convert xml1` prints for the sandboxed app's preferences.
const _xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSWindow Frame main</key>
	<string>0 0 100 100</string>
	<key>flutter.empty</key>
	<string></string>
	<key>flutter.kerioIP</key>
	<string>172.18.18.1:4080</string>
	<key>flutter.list</key>
	<array>
		<string>a&amp;b</string>
		<string>&lt;c&gt;</string>
		<string></string>
	</array>
	<key>flutter.qualityInterval</key>
	<integer>5</integer>
	<key>flutter.ratio</key>
	<real>0.25</real>
	<key>flutter.usageTracking</key>
	<false/>
	<key>flutter.v2ray.v1</key>
	<string>{"a":"x&lt;y"}</string>
</dict>
</plist>
''';

void main() {
  test('reads the flutter.* values of a plist, unprefixed and unescaped', () {
    expect(parseFlutterPrefs(_xml), {
      'empty': '',
      'kerioIP': '172.18.18.1:4080',
      'list': ['a&b', '<c>', ''],
      'qualityInterval': 5,
      'ratio': 0.25,
      'usageTracking': false,
      'v2ray.v1': '{"a":"x<y"}',
    });
  });
}
