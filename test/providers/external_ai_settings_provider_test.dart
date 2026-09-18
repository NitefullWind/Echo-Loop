import 'package:echo_loop/providers/external_ai_settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Echo Loop 默认模式不生成外部配置', () {
    const settings = ExternalAiSettings();

    expect(settings.isConfigured, isFalse);
    expect(settings.configOrNull, isNull);
  });

  test('DeepSeek 配置生成去空白后的兼容客户端配置', () {
    const settings = ExternalAiSettings(
      provider: ExternalAiProvider.deepSeek,
      baseUrl: ' https://api.deepseek.com/v1/ ',
      model: ' deepseek-chat ',
      apiKey: ' key ',
    );

    expect(settings.isConfigured, isTrue);
    expect(settings.configOrNull?.baseUrl, 'https://api.deepseek.com/v1/');
    expect(settings.configOrNull?.model, 'deepseek-chat');
    expect(settings.configOrNull?.apiKey, 'key');
  });

  test('预设服务提供稳定的地址和模型默认值', () {
    expect(defaultBaseUrlFor(ExternalAiProvider.openAi), defaultOpenAiBaseUrl);
    expect(defaultModelFor(ExternalAiProvider.openAi), defaultOpenAiModel);
    expect(
      defaultBaseUrlFor(ExternalAiProvider.deepSeek),
      defaultDeepSeekBaseUrl,
    );
    expect(defaultModelFor(ExternalAiProvider.deepSeek), defaultDeepSeekModel);
    expect(defaultBaseUrlFor(ExternalAiProvider.custom), isEmpty);
    expect(defaultModelFor(ExternalAiProvider.custom), isEmpty);
  });
}
