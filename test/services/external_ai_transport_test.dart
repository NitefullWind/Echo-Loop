import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/models/external_ai_config.dart';
import 'package:echo_loop/services/app_logger.dart';
import 'package:echo_loop/services/openai_compatible_ai_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/external_ai_adapter.dart';

const config = ExternalAiConfig(
  providerLabel: 'Custom',
  baseUrl: 'https://provider.example/prefix/v1/chat/completions/',
  model: 'custom-model',
  apiKey: 'private-test-key',
);

void main() {
  test('真实 Dio 保留自定义地址前缀，只发送用户 Key，不添加内部鉴权或重定向', () async {
    final adapter = ExternalAiTestAdapter(
      (_) async => externalCompletion({'ok': true}),
    );
    final client = OpenAiCompatibleAiClient(config, adapter: adapter);
    addTearDown(client.dispose);
    expect(
      await client.completeJson(systemPrompt: 'Return JSON', userPrompt: 'Hi'),
      {'ok': true},
    );
    final request = adapter.requests.single;
    expect(
      request.uri.toString(),
      'https://provider.example/prefix/v1/chat/completions',
    );
    expect(request.headers['Authorization'], 'Bearer private-test-key');
    expect(request.followRedirects, false);
    expect(request.headers.containsKey('x-app-version'), false);
  });

  for (final status in [401, 402, 429, 500]) {
    test('外部 HTTP $status 不携带 Key 或响应体，也不暴露为内部额度错误', () async {
      AppLogger.instance.clear();
      final adapter = ExternalAiTestAdapter(
        (_) async =>
            externalJson({'error': 'private-test-key'}, status: status),
      );
      final client = OpenAiCompatibleAiClient(config, adapter: adapter);
      addTearDown(client.dispose);
      await expectLater(
        client.completeJson(systemPrompt: 'JSON', userPrompt: 'Hi'),
        throwsA(
          isA<ExternalAiResponseException>()
              .having((e) => e.statusCode, 'status', status)
              .having(
                (e) => e.toString(),
                'safe error',
                isNot(contains('private-test-key')),
              ),
        ),
      );
      expect(adapter.requests.length, 1);
      expect(
        AppLogger.instance.entries.join(),
        isNot(contains('private-test-key')),
      );
    });
  }

  test('预先取消不会发送请求', () async {
    final adapter = ExternalAiTestAdapter(
      (_) async => externalCompletion({'ok': true}),
    );
    final client = OpenAiCompatibleAiClient(config, adapter: adapter);
    addTearDown(client.dispose);
    final token = CancelToken()..cancel();
    await expectLater(
      client.completeJson(
        systemPrompt: 'JSON',
        userPrompt: 'Hi',
        cancelToken: token,
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(adapter.requests, isEmpty);
  });

  for (final ending in [
    '',
    'data: {"error":"failure"}\n\n',
    'data: {"choices":[{"finish_reason":"length"}]}\n\ndata: [DONE]\n\n',
  ]) {
    test('断流、流内错误或截断不能伪装完成 $ending', () async {
      final bytes = utf8.encode(
        'data: {"choices":[{"delta":{"content":"你好"}}]}\n\n$ending',
      );
      final adapter = ExternalAiTestAdapter(
        (_) async => ResponseBody(
          Stream.fromIterable(bytes.map((byte) => Uint8List.fromList([byte]))),
          200,
        ),
      );
      final client = OpenAiCompatibleAiClient(config, adapter: adapter);
      addTearDown(client.dispose);
      var finalSeen = false;
      await expectLater(() async {
        await for (final frame in client.streamText(messages: const [])) {
          finalSeen |= frame.isFinal;
        }
      }(), throwsA(isA<ExternalAiResponseException>()));
      expect(finalSeen, false);
    });
  }
}
