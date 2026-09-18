/// 用户自带的 OpenAI 兼容模型配置。
library;

import 'package:flutter/foundation.dart';

/// 连接一个兼容 OpenAI Chat Completions 协议的模型服务所需的配置。
///
/// API Key 只在内存中的配置对象里短暂流转，持久化由
/// 设置控制器负责写入系统安全存储。
@immutable
class ExternalAiConfig {
  /// 设置页展示的服务名称。
  final String providerLabel;

  /// OpenAI 兼容 API 的 base URL，例如 `https://api.openai.com/v1`。
  final String baseUrl;

  /// 模型名称，例如 `gpt-4o-mini` 或 `deepseek-chat`。
  final String model;

  /// 用户自己的 API Key。
  final String apiKey;

  const ExternalAiConfig({
    required this.providerLabel,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
  });

  /// 接受 API 根路径或完整 Chat Completions 地址，保留服务商自定义前缀。
  String get normalizedBaseUrl {
    var value = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (value.endsWith('/chat/completions')) {
      value = value.substring(0, value.length - '/chat/completions'.length);
    }
    return '$value/';
  }

  /// 校验地址、模型和凭据，避免把用户输入当作相对路径或含凭据的 URL。
  bool get isValid {
    final uri = Uri.tryParse(normalizedBaseUrl);
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        model.trim().isNotEmpty &&
        apiKey.trim().isNotEmpty;
  }
}
