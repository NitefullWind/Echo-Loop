/// 外部语音服务来源；禁用时由调用方提示配置。
enum ExternalSpeechProvider { disabled, aliyun, doubao }

/// 服务商的默认安全接口地址。
String externalSpeechDefaultEndpoint(ExternalSpeechProvider provider) =>
    switch (provider) {
      ExternalSpeechProvider.disabled => '',
      ExternalSpeechProvider.aliyun =>
        'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
      ExternalSpeechProvider.doubao =>
        'https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash',
    };

/// 默认实时识别模型或录音识别资源 ID。
String externalSpeechDefaultModel(ExternalSpeechProvider provider) =>
    switch (provider) {
      ExternalSpeechProvider.disabled => '',
      ExternalSpeechProvider.aliyun => 'paraformer-realtime-v2',
      ExternalSpeechProvider.doubao => 'volc.bigasr.auc_turbo',
    };

/// 用户自行配置的语音服务凭据；不得输出到日志。
class ExternalSpeechConfig {
  final ExternalSpeechProvider provider;
  final String apiKey;
  final String appId;
  final String model;
  final String endpoint;

  const ExternalSpeechConfig({
    required this.provider,
    this.apiKey = '',
    this.appId = '',
    this.model = '',
    this.endpoint = '',
  });

  String get resolvedEndpoint => endpoint.trim().isEmpty
      ? externalSpeechDefaultEndpoint(provider)
      : endpoint.trim();
  String get resolvedModel => model.trim().isEmpty
      ? externalSpeechDefaultModel(provider)
      : model.trim();

  /// 凭据齐全且仅允许 TLS 接口，不在本地判断凭据真实性。
  bool get isConfigured {
    final uri = Uri.tryParse(resolvedEndpoint);
    return provider != ExternalSpeechProvider.disabled &&
        apiKey.trim().isNotEmpty &&
        uri != null &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        uri.scheme ==
            (provider == ExternalSpeechProvider.aliyun ? 'wss' : 'https');
  }
}
