/// SentenceChatButton 测试：开关显隐规则 + 组件渲染 + onBeforeOpen 回调。
library;

import 'package:echo_loop/features/chatbot/widgets/sentence_chat_button.dart';
import 'package:echo_loop/features/remote_config/remote_config.dart';
import 'package:echo_loop/features/remote_config/remote_config_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chatbot_widget_harness.dart';

void main() {
  group('shouldShowAiChatAssistantEntry', () {
    test('外部模型已配置时不依赖内部服务开关', () {
      expect(
        shouldShowAiChatAssistantEntry(
          chatbotEnabled: false,
          remoteEnabled: false,
          externalProviderConfigured: true,
        ),
        true,
      );
    });
    test('编译期开关和远程开关都开启时显示入口', () {
      expect(
        shouldShowAiChatAssistantEntry(
          chatbotEnabled: true,
          remoteEnabled: true,
        ),
        isTrue,
      );
    });

    test('远程关闭时隐藏入口', () {
      expect(
        shouldShowAiChatAssistantEntry(
          chatbotEnabled: true,
          remoteEnabled: false,
        ),
        isFalse,
      );
    });

    test('编译期开关关闭时始终隐藏入口', () {
      expect(
        shouldShowAiChatAssistantEntry(
          chatbotEnabled: false,
          remoteEnabled: true,
        ),
        isFalse,
      );
    });
  });

  group('SentenceChatButton', () {
    /// 覆盖远程开关为指定值。
    List<Override> remoteOverride({required bool enabled}) => [
      remoteFeatureEnabledProvider(
        RemoteFeature.aiChatAssistant,
      ).overrideWithValue(enabled),
    ];

    testWidgets('远程开关开启且句子非空时渲染按钮', (tester) async {
      await pumpChatWidget(
        tester,
        const SentenceChatButton(sentenceText: 'Hello world.'),
        overrides: remoteOverride(enabled: true),
      );
      expect(find.byType(IconButton), findsOneWidget);
    });

    testWidgets('远程开关关闭时不渲染按钮', (tester) async {
      await pumpChatWidget(
        tester,
        const SentenceChatButton(sentenceText: 'Hello world.'),
        overrides: remoteOverride(enabled: false),
      );
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('句子为空（未就绪）时不渲染按钮', (tester) async {
      await pumpChatWidget(
        tester,
        const SentenceChatButton(sentenceText: ''),
        overrides: remoteOverride(enabled: true),
      );
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('点击时先触发 onBeforeOpen（任务页借此暂停自动推进）', (tester) async {
      var beforeOpenCalled = false;
      await pumpChatWidget(
        tester,
        SentenceChatButton(
          sentenceText: 'Hello world.',
          onBeforeOpen: () => beforeOpenCalled = true,
        ),
        overrides: remoteOverride(enabled: true),
      );
      // 只验证回调时序，不 pump sheet 内容（ChatView 依赖网络/订阅一整套 provider）。
      await tester.tap(find.byType(IconButton));
      expect(beforeOpenCalled, isTrue);
    });
  });
}
