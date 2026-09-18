/// ChatApi 单例 provider。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart' show Ref;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../config/api_config.dart';
import '../../../config/external_services_config.dart';
import '../../auth/providers/auth_providers.dart';
import '../../../providers/package_info_provider.dart';
import '../../../providers/external_ai_settings_provider.dart';
import '../chatbot_flags.dart';
import '../services/chat_api_client.dart';
import '../services/fake_chat_api_client.dart';
import '../../../services/openai_compatible_ai_client.dart';

part 'chat_api_client_provider.g.dart';

/// ChatApi 单例（keepAlive）。
///
/// 已配置外部模型时直连用户服务；否则 kChatbotUseFakeApi=true（仅 debug 联调）时
/// 返回假实现，默认构造 Echo Loop 真实网络客户端。
@Riverpod(keepAlive: true)
ChatApi chatApiClient(Ref ref) {
  final settings = ref.watch(externalAiSettingsProvider);
  final error = settings.requestError;
  if (error != null) return UnavailableChatApi(error);
  final externalConfig = settings.configOrNull;
  if (externalConfig != null) {
    final client = OpenAiCompatibleChatApi(externalConfig);
    ref.onDispose(client.dispose);
    return client;
  }
  if (externalServicesOnly) {
    return UnavailableChatApi('请先在设置中配置外部文本 AI');
  }
  if (kChatbotUseFakeApi) return const FakeChatApiClient();
  final client = ChatApiClient(
    baseUrl: apiBaseUrl,
    appVersion: readAppVersion(ref),
    tokenCoordinator: ref.read(supabaseTokenCoordinatorProvider),
  );
  ref.onDispose(client.dispose);
  return client;
}
