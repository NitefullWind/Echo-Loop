/// 外部 AI 服务选项和不可变设置快照。
library;

import 'external_ai_config.dart';

const defaultOpenAiBaseUrl = 'https://api.openai.com/v1';
const defaultOpenAiModel = 'gpt-4o-mini';
const defaultDeepSeekBaseUrl = 'https://api.deepseek.com/v1';
const defaultDeepSeekModel = 'deepseek-chat';

/// 可选的 AI 服务。
enum ExternalAiProvider {
  /// Echo Loop 自有后端，保持原有登录和会员策略。
  echoLoop,

  /// OpenAI / ChatGPT API。
  openAi,

  /// DeepSeek API。
  deepSeek,

  /// 其它遵循 OpenAI Chat Completions 协议的服务。
  custom,
}

extension ExternalAiProviderPresentation on ExternalAiProvider {
  /// 服务的短名称，设置页可直接展示。
  String get label => switch (this) {
    ExternalAiProvider.echoLoop => 'Echo Loop',
    ExternalAiProvider.openAi => 'OpenAI / ChatGPT',
    ExternalAiProvider.deepSeek => 'DeepSeek',
    ExternalAiProvider.custom => '自定义兼容服务',
  };
}

/// AI 服务设置快照。
class ExternalAiSettings {
  final ExternalAiProvider provider;
  final String baseUrl;
  final String model;
  final String apiKey;
  final bool isLoading;
  final String? loadError;

  const ExternalAiSettings({
    this.provider = ExternalAiProvider.echoLoop,
    this.baseUrl = defaultOpenAiBaseUrl,
    this.model = defaultOpenAiModel,
    this.apiKey = '',
    this.isLoading = false,
    this.loadError,
  });

  /// 当前是否已填写足够信息来启用外部服务。
  bool get isConfigured =>
      !isLoading &&
      loadError == null &&
      provider != ExternalAiProvider.echoLoop &&
      (configOrNull?.isValid ?? false);

  /// 配置未就绪时明确阻止请求，禁止悄悄回退到内部服务。
  String? get requestError =>
      isLoading ? 'AI settings are still loading. Please retry.' : loadError;

  /// 仅选择 Echo Loop 时返回 null；不完整的外部配置由网络层明确报错。
  ExternalAiConfig? get configOrNull {
    if (provider == ExternalAiProvider.echoLoop) return null;
    return ExternalAiConfig(
      providerLabel: provider.label,
      baseUrl: baseUrl.trim(),
      model: model.trim(),
      apiKey: apiKey.trim(),
    );
  }
}

/// 预设服务的默认地址。
String defaultBaseUrlFor(ExternalAiProvider provider) => switch (provider) {
  ExternalAiProvider.openAi => defaultOpenAiBaseUrl,
  ExternalAiProvider.deepSeek => defaultDeepSeekBaseUrl,
  ExternalAiProvider.echoLoop || ExternalAiProvider.custom => '',
};

/// 预设服务的默认模型。
String defaultModelFor(ExternalAiProvider provider) => switch (provider) {
  ExternalAiProvider.openAi => defaultOpenAiModel,
  ExternalAiProvider.deepSeek => defaultDeepSeekModel,
  ExternalAiProvider.echoLoop || ExternalAiProvider.custom => '',
};
