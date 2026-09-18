/// 句子级 AI 助手入口按钮（AppBar action）。
///
/// 句子详情页与各学习任务页（逐句精听/难句跟读/难句复习/收藏复习）共用的
/// 单一入口来源：显隐开关、图标、ChatbotConfig 组装都集中在此，避免多处复制。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../l10n/app_localizations.dart';
import '../../../config/external_services_config.dart';
import '../../../screens/external_ai_settings_screen.dart';
import '../../../providers/external_ai_settings_provider.dart';
import '../../remote_config/remote_config.dart';
import '../../remote_config/remote_config_providers.dart';
import '../chatbot_flags.dart';
import '../chatbot_sheet.dart';
import '../models/chatbot_config.dart';

/// 外部服务独立开放入口；Echo Loop 服务仍遵循编译与远程开关。
bool shouldShowAiChatAssistantEntry({
  required bool chatbotEnabled,
  required bool remoteEnabled,
  bool externalProviderConfigured = false,
}) {
  return externalServicesOnly ||
      externalProviderConfigured ||
      (chatbotEnabled && remoteEnabled);
}

/// 构造句子级聊天配置；AppBar 与文本选区入口必须复用同一会话身份。
ChatbotConfig sentenceChatbotConfig(BuildContext context, String sentenceText) {
  final l10n = AppLocalizations.of(context)!;
  return ChatbotConfig(
    // 用完整句子做内存会话 key，避免 hash 碰撞，也让同句跨页面复用会话。
    sessionId: 'sentence:$sentenceText',
    endpoint: '/api/v1/stream/chat/sentence',
    context: {'sentence': sentenceText},
    title: l10n.chatSentenceTitle,
    inputPlaceholder: l10n.chatInputPlaceholder,
    contextSummary: sentenceText,
  );
}

/// 打开句子级 AI Sheet；[initialQuote] 只进入引用待发送区，不自动提问。
Future<void> showSentenceChatbotSheet({
  required BuildContext context,
  required String sentenceText,
  String? initialQuote,
}) {
  if (externalServicesOnly &&
      !ProviderScope.containerOf(
        context,
        listen: false,
      ).read(externalAiSettingsProvider).isConfigured) {
    return openExternalAiSettings(context);
  }
  return showChatbotSheet(
    context: context,
    config: sentenceChatbotConfig(context, sentenceText),
    initialQuote: initialQuote,
  );
}

/// 句子 AI 助手入口按钮。
///
/// 开关关闭或 [sentenceText] 为空（句子未就绪）时自隐藏（渲染空 widget），
/// 调用方无需判空。点击时先执行 [onBeforeOpen]（任务页用来暂停自动推进，
/// 语义同各页设置按钮），再以 bottom sheet 打开 chatbot。
class SentenceChatButton extends ConsumerWidget {
  /// 当前句子文本；会话按句子内容归属（相同句子跨页面复用同一会话）。
  final String sentenceText;

  /// 打开面板前回调（可选）：任务页在此暂停自动推进/等待用户。
  final VoidCallback? onBeforeOpen;

  const SentenceChatButton({
    super.key,
    required this.sentenceText,
    this.onBeforeOpen,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = shouldShowAiChatAssistantEntry(
      externalProviderConfigured: ref
          .watch(externalAiSettingsProvider)
          .isConfigured,
      chatbotEnabled: kChatbotEnabled,
      remoteEnabled: ref.watch(
        remoteFeatureEnabledProvider(RemoteFeature.aiChatAssistant),
      ),
    );
    if (!show || sentenceText.isEmpty) return const SizedBox.shrink();

    return IconButton(
      // 渐变多色图标，保留原始配色不做 colorFilter 染色。
      icon: SvgPicture.asset(
        'assets/icon/chat/use-ai-chat.svg',
        width: 24,
        height: 24,
      ),
      tooltip: AppLocalizations.of(context)!.chatOpenTooltip,
      onPressed: () {
        onBeforeOpen?.call();
        showSentenceChatbotSheet(context: context, sentenceText: sentenceText);
      },
    );
  }
}
