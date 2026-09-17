import 'package:echo_loop/services/app_window_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('移动端不调用桌面窗口激活插件', () async {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      debugDefaultTargetPlatformOverride = platform;
      final activator = WindowManagerAppWindowActivator();

      await activator.initialize();
      await activator.activate();
    }
  });
}
