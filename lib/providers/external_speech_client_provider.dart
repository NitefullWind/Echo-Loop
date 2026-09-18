/// 外部语音客户端 Provider。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/external_speech_client.dart';
import 'external_speech_settings_provider.dart';

/// 仅在配置完整时创建客户端；独立构建未配置时返回 null，由界面提示配置。
final externalSpeechClientProvider = Provider<ExternalSpeechClient?>((ref) {
  final settings = ref.watch(externalSpeechSettingsProvider);
  if (!settings.isConfigured) return null;
  final client = createExternalSpeechClient(settings.config);
  ref.onDispose(client.dispose);
  return client;
});
