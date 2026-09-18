import 'package:flutter_test/flutter_test.dart';
import 'package:echo_loop/models/external_speech_config.dart';

void main() {
  test('阿里和豆包默认配置要求各自 TLS 地址与凭据', () {
    expect(
      const ExternalSpeechConfig(
        provider: ExternalSpeechProvider.aliyun,
        apiKey: 'key',
      ).isConfigured,
      isTrue,
    );
    expect(
      const ExternalSpeechConfig(
        provider: ExternalSpeechProvider.doubao,
        apiKey: 'key',
      ).isConfigured,
      isTrue,
    );
    expect(
      const ExternalSpeechConfig(
        provider: ExternalSpeechProvider.disabled,
        apiKey: 'key',
      ).isConfigured,
      isFalse,
    );
    expect(
      const ExternalSpeechConfig(
        provider: ExternalSpeechProvider.aliyun,
        apiKey: 'key',
        endpoint: 'http://example.test',
      ).isConfigured,
      isFalse,
    );
  });
}
