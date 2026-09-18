import 'package:dio/dio.dart';
import 'package:universal_io/io.dart';
import 'package:echo_loop/models/external_ai_config.dart';
import 'package:echo_loop/services/openai_compatible_ai_client.dart';
import 'package:echo_loop/services/sentence_ai_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockDio extends Mock implements Dio {}

void main() {
  test('外部模式翻译不要求 access token，并适配结构化 JSON', () async {
    final dio = MockDio();
    when(
      () => dio.post<Object?>(
        'chat/completions',
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => Response<Object?>(
        data: {
          'choices': [
            {
              'message': {'content': '{"translation":"你好"}'},
            },
          ],
        },
        statusCode: 200,
        requestOptions: RequestOptions(path: 'chat/completions'),
      ),
    );

    final external = OpenAiCompatibleAiClient.withDio(
      const ExternalAiConfig(
        providerLabel: 'Test',
        baseUrl: 'https://example.com/v1',
        model: 'test-model',
        apiKey: 'key',
      ),
      dio,
    );
    final client = SentenceAiApiClient.withExternalClient(external);
    final frames = await client
        .translateStream('Hello', accessToken: '')
        .toList();

    expect(client.usesExternalProvider, isTrue);
    expect(frames.single.translation.translation, '你好');
  });

  test('外部模式明确拒绝音频复述评估', () async {
    final external = OpenAiCompatibleAiClient.withDio(
      const ExternalAiConfig(
        providerLabel: 'Test',
        baseUrl: 'https://example.com/v1',
        model: 'test-model',
        apiKey: 'key',
      ),
      MockDio(),
    );
    final client = SentenceAiApiClient.withExternalClient(external);

    await expectLater(
      client
          .evaluateReviewStream(
            audioFile: File('missing.m4a'),
            originalText: 'Hello',
            targetLanguage: 'zh-CN',
            accessToken: '',
          )
          .toList(),
      throwsA(
        isA<ExternalAiFeatureUnsupportedException>().having(
          (error) => error.feature,
          'feature',
          'evaluateReview',
        ),
      ),
    );
  });
}
