/// 外部语音设置的不可变状态快照。
library;

import 'external_speech_config.dart';
export 'external_speech_config.dart';

/// 配置与加载状态分离，缺失凭据时保留用户可修复的配置。
class ExternalSpeechSettings {
  const ExternalSpeechSettings({
    this.config = const ExternalSpeechConfig(
      provider: ExternalSpeechProvider.disabled,
    ),
    this.isLoading = false,
    this.loadError,
  });

  final ExternalSpeechConfig config;
  final bool isLoading;
  final String? loadError;

  bool get isConfigured =>
      !isLoading && loadError == null && config.isConfigured;
}
