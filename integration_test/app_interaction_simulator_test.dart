/// 通用 App 交互模拟器 smoke test。
///
/// 该测试只验证模拟器能启动一个最小可交互页面、执行交互并采集日志，不验证某个
/// 业务功能；具体业务测试可以将同一个模拟器复用到真实 App 页面。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/app_interaction_simulator.dart';
import 'helpers/test_main_setup.dart';

void main() {
  setupIntegrationTestBinding();
  registerCommonSetUpAll();

  testWidgets('通用交互模拟器可执行点击并采集日志', (tester) async {
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final simulator = AppInteractionSimulator(tester);
    await simulator.launch(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: FilledButton(
              key: const ValueKey('simulator-action'),
              onPressed: () {},
              child: const Text('Simulator action'),
            ),
          ),
        ),
      ),
    );

    await simulator.tap(
      find.byKey(const ValueKey('simulator-action')),
      action: 'tap_visible_target',
    );

    expect(
      simulator.logsSinceLaunch.any(
        (entry) =>
            entry.tag == 'IntegrationSimulator' &&
            entry.message == 'event=tap_visible_target',
      ),
      isTrue,
    );
  });
}
