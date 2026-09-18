import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/features/chatbot/models/chat_message.dart';
import 'package:echo_loop/features/chatbot/services/chat_api_client.dart';
import 'package:echo_loop/models/external_ai_config.dart';
import 'package:echo_loop/services/openai_compatible_ai_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockDio extends Mock implements Dio {}

void main() {
  late MockDio dio;
  late ExternalAiConfig config;

  setUp(() {
    dio = MockDio();
    config = const ExternalAiConfig(
      providerLabel: 'Test',
      baseUrl: 'https://example.com/v1/',
      model: 'test-model',
      apiKey: 'secret-key',
    );
  });

  Response<Object?> jsonResponse(Object? data, {int status = 200}) =>
      Response<Object?>(
        data: data,
        statusCode: status,
        requestOptions: RequestOptions(
          path: 'chat/completions',
          method: 'POST',
        ),
      );

  Response<ResponseBody> streamResponse(String data, {int status = 200}) {
    final bytes = Uint8List.fromList(utf8.encode(data));
    return Response<ResponseBody>(
      data: ResponseBody(Stream<Uint8List>.value(bytes), status),
      statusCode: status,
      requestOptions: RequestOptions(path: 'chat/completions', method: 'POST'),
    );
  }

  test('结构化响应解析 JSON，并发送模型和 response_format', () async {
    when(
      () => dio.post<Object?>(
        'chat/completions',
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => jsonResponse({
        'choices': [
          {
            'message': {'content': '{"translation":"你好"}'},
          },
        ],
      }),
    );

    final client = OpenAiCompatibleAiClient.withDio(config, dio);
    final result = await client.completeJson(
      systemPrompt: 'system',
      userPrompt: 'user',
    );

    expect(result['translation'], '你好');
    verify(
      () => dio.post<Object?>(
        'chat/completions',
        data: {
          'model': 'test-model',
          'messages': [
            {'role': 'system', 'content': 'system'},
            {'role': 'user', 'content': 'user'},
          ],
          'response_format': {'type': 'json_object'},
        },
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
  });

  test('兼容服务不支持 response_format 时降级，并清理 markdown code fence', () async {
    var callCount = 0;
    when(
      () => dio.post<Object?>(
        'chat/completions',
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async {
      callCount += 1;
      if (callCount == 1) {
        throw DioException(
          requestOptions: RequestOptions(path: 'chat/completions'),
          response: jsonResponse({'error': 'response_format'}, status: 400),
        );
      }
      return jsonResponse({
        'choices': [
          {
            'message': {'content': '```json\n{"ok":true}\n```'},
          },
        ],
      });
    });

    final result = await OpenAiCompatibleAiClient.withDio(
      config,
      dio,
    ).completeJson(systemPrompt: 's', userPrompt: 'u');

    expect(result['ok'], true);
    expect(callCount, 2);
  });

  test('非法 JSON 返回明确外部响应异常', () async {
    when(
      () => dio.post<Object?>(
        'chat/completions',
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => jsonResponse({
        'choices': [
          {
            'message': {'content': 'not-json'},
          },
        ],
      }),
    );

    await expectLater(
      OpenAiCompatibleAiClient.withDio(
        config,
        dio,
      ).completeJson(systemPrompt: 's', userPrompt: 'u'),
      throwsA(isA<ExternalAiResponseException>()),
    );
  });

  test('SSE 流式响应累计 delta，并只在 [DONE] 发送 final', () async {
    when(
      () => dio.post<ResponseBody>(
        'chat/completions',
        data: any(named: 'data'),
        options: any(named: 'options'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => streamResponse(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': '你'},
            },
          ],
        })}\n\n'
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': '好'},
            },
          ],
        })}\n\n'
        'data: [DONE]\n\n',
      ),
    );

    final frames = await OpenAiCompatibleAiClient.withDio(
      config,
      dio,
    ).streamText(messages: const []).toList();

    expect(frames.map((frame) => frame.text), ['你', '你好', '你好']);
    expect(frames.last.isFinal, isTrue);
  });

  test('空 choices 返回明确外部响应异常', () async {
    when(
      () => dio.post<Object?>(
        'chat/completions',
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => jsonResponse({'choices': []}));

    await expectLater(
      OpenAiCompatibleAiClient.withDio(
        config,
        dio,
      ).completeJson(systemPrompt: 's', userPrompt: 'u'),
      throwsA(isA<ExternalAiResponseException>()),
    );
  });

  test('外部聊天实现把历史消息转换为 OpenAI messages，并标记外部能力', () async {
    when(
      () => dio.post<ResponseBody>(
        'chat/completions',
        data: any(named: 'data'),
        options: any(named: 'options'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => streamResponse(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': '回答'},
            },
          ],
        })}\n'
        'data: [DONE]\n',
      ),
    );

    final chat = OpenAiCompatibleChatApi.withClient(
      OpenAiCompatibleAiClient.withDio(config, dio),
    );
    final frames = await chat
        .streamChat(
          endpoint: '/unused',
          history: [
            ChatMessage.user(
              id: 'u1',
              content: '这句话是什么意思？',
              quote: 'What does it mean?',
              createdAt: DateTime(2026),
            ),
          ],
          context: const {'sentence': 'What does it mean?'},
          followUpInstruction: 'Answer clearly.',
          targetLanguage: 'zh-CN',
          accessToken: '',
        )
        .toList();

    expect(chat, isA<ExternalChatApi>());
    expect(frames.last.text, '回答');
    expect(frames.last.isFinal, isTrue);
    final payload = verify(
      () => dio.post<ResponseBody>(
        'chat/completions',
        data: captureAny(named: 'data'),
        options: any(named: 'options'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).captured.single;
    expect(payload, isA<Map<String, Object?>>());
    if (payload is Map<String, Object?>) {
      expect(payload['messages'], isA<List<Map<String, Object?>>>());
      final messages = payload['messages'];
      if (messages is List<Map<String, Object?>>) {
        expect(messages.first['content'], contains('zh-CN'));
        expect(messages.first['content'], contains('What does it mean?'));
        expect(messages.last['role'], 'user');
        expect(messages.last['content'], contains('What does it mean?'));
        expect(messages.last['content'], contains('这句话是什么意思？'));
        expect(messages.last['content'], contains('Answer clearly.'));
      }
    }
  });
}
