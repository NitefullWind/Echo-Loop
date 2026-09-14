/// 通用集成测试交互模拟器。
///
/// 只封装稳定的用户交互原语和有界等待，不包含任何具体业务页面断言；业务测试
/// 可以在此基础上组合点击、输入、滚动和日志核验。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:echo_loop/services/app_logger.dart';

/// 面向真实 App 集成测试的最小交互封装。
final class AppInteractionSimulator {
  AppInteractionSimulator(this.tester);

  final WidgetTester tester;
  int _logStartIndex = 0;

  /// 启动 App 并等待首屏异步任务进入稳定状态。
  Future<void> launch(Widget app) async {
    _logStartIndex = AppLogger.instance.entries.length;
    AppLogger.log('IntegrationSimulator', 'event=launch');
    await tester.pumpWidget(app);
    await settle();
  }

  /// 点击指定目标；目标不存在时立即失败，避免静默跳过交互步骤。
  Future<void> tap(Finder target, {String action = 'tap'}) async {
    if (target.evaluate().isEmpty) {
      throw StateError('交互目标不存在: $action');
    }
    AppLogger.log('IntegrationSimulator', 'event=$action');
    await tester.tap(target.first);
    await settle();
  }

  /// 从候选目标中点击第一个当前可见的目标。
  Future<void> tapFirstVisible(
    Iterable<Finder> candidates, {
    String action = 'tap_first_visible',
  }) async {
    for (final candidate in candidates) {
      if (candidate.evaluate().isNotEmpty) {
        await tap(candidate, action: action);
        return;
      }
    }
    throw StateError('交互目标不存在: $action');
  }

  /// 向目标输入文本。
  Future<void> enterText(Finder target, String text) async {
    if (target.evaluate().isEmpty) {
      throw StateError('文本输入目标不存在');
    }
    AppLogger.log('IntegrationSimulator', 'event=enter_text');
    await tester.enterText(target.first, text);
    await settle();
  }

  /// 在可滚动目标上执行一次拖动。
  Future<void> scroll(
    Finder target,
    Offset offset, {
    String action = 'scroll',
  }) async {
    if (target.evaluate().isEmpty) {
      throw StateError('滚动目标不存在: $action');
    }
    AppLogger.log('IntegrationSimulator', 'event=$action');
    await tester.drag(target.first, offset);
    await settle();
  }

  /// 等待目标在限定时间内出现；不会无限等待或引入固定长延时。
  Future<void> waitFor(
    Finder target, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (target.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    if (target.evaluate().isEmpty) {
      throw StateError('等待目标超时');
    }
  }

  /// 有界地推进 Flutter 异步任务。
  Future<void> settle({Duration timeout = const Duration(seconds: 5)}) async {
    try {
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        timeout,
      );
    } on Exception {
      // LiveTest 中持续动画不应让通用交互工具无限阻塞；调用方仍可继续做
      // 明确的目标和日志断言。
    }
  }

  /// 获取本次启动之后产生的日志快照，供业务测试核对事件顺序和值。
  List<LogEntry> get logsSinceLaunch {
    final entries = AppLogger.instance.entries;
    if (_logStartIndex >= entries.length) return const [];
    return entries.sublist(_logStartIndex);
  }
}
