import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android registers the Paddle custom deep link', () async {
    final content = await File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsString();

    expect(content, contains('android:scheme="echo-loop"'));
    expect(content, contains('android:host="paddle-success"'));
    expect(content, contains('android:name="flutter_deeplinking_enabled"'));
    expect(content, contains('android:value="false"'));
  });

  test('iOS registers the Paddle custom URL scheme', () async {
    final content = await File('ios/Runner/Info.plist').readAsString();

    expect(content, contains('<key>CFBundleURLTypes</key>'));
    expect(content, contains('<key>CFBundleURLSchemes</key>'));
    expect(content, contains('<string>echo-loop</string>'));
  });

  test('macOS registers the Paddle custom URL scheme', () async {
    final content = await File('macos/Runner/Info.plist').readAsString();

    expect(content, contains('<key>CFBundleURLTypes</key>'));
    expect(content, contains('<key>CFBundleURLSchemes</key>'));
    expect(content, contains('<string>echo-loop</string>'));
  });
}
