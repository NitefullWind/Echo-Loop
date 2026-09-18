/// OpenAI Chat Completions 兼容客户端。
library;

import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';

import '../features/chatbot/models/chat_message.dart';
import '../features/chatbot/services/chat_api_client.dart';
import '../features/chatbot/services/ndjson_text_stream.dart';
import '../models/external_ai_config.dart';
import 'app_logger.dart';

/// 外部 AI 响应无法解析为预期 JSON 时抛出的异常。
class ExternalAiResponseException implements Exception {
  final String message;
  final int? statusCode;

  const ExternalAiResponseException(this.message, {this.statusCode});

  @override
  String toString() => 'ExternalAiResponseException: $message';
}

/// 直接调用 OpenAI / DeepSeek / 其它 OpenAI 兼容服务。
class OpenAiCompatibleAiClient {
  final ExternalAiConfig config;
  final Dio _dio;

  OpenAiCompatibleAiClient(this.config, {HttpClientAdapter? adapter})
    : _dio = Dio(
        BaseOptions(
          baseUrl: config.normalizedBaseUrl,
          followRedirects: false,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 90),
          headers: {
            'Authorization': 'Bearer ${config.apiKey}',
            'Content-Type': 'application/json',
          },
        ),
      ) {
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  /// 测试用构造函数。
  OpenAiCompatibleAiClient.withDio(this.config, this._dio);

  /// 请求一次结构化 JSON 响应。
  Future<Map<String, Object?>> completeJson({
    required String systemPrompt,
    required String userPrompt,
    CancelToken? cancelToken,
  }) async {
    _validateConfiguration();
    try {
      try {
        return await _completeJson(
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          cancelToken: cancelToken,
          requestJsonMode: true,
        );
      } on DioException catch (error) {
        // 只有服务明确拒绝 response_format 时才重试，避免重复扣费或掩盖配置错误。
        final status = error.response?.statusCode;
        if ((status != 400 && status != 422) ||
            !(error.response?.data.toString().contains('response_format') ??
                false)) {
          rethrow;
        }
        return await _completeJson(
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          cancelToken: cancelToken,
          requestJsonMode: false,
        );
      }
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) rethrow;
      throw _requestFailure(error);
    }
  }

  Future<Map<String, Object?>> _completeJson({
    required String systemPrompt,
    required String userPrompt,
    required CancelToken? cancelToken,
    required bool requestJsonMode,
  }) async {
    final data = <String, Object?>{
      'model': config.model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
      if (requestJsonMode) 'response_format': {'type': 'json_object'},
    };
    final response = await _dio.post<Object?>(
      'chat/completions',
      data: data,
      cancelToken: cancelToken,
    );
    final responseMap = _asStringMap(response.data);
    if (responseMap == null) {
      throw const ExternalAiResponseException('响应不是 JSON 对象');
    }
    final choices = responseMap['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const ExternalAiResponseException('响应缺少 choices');
    }
    final firstChoice = _asStringMap(choices.first);
    final finishReason = firstChoice?['finish_reason'];
    if (finishReason != null && finishReason != 'stop') {
      throw const ExternalAiResponseException(
        'The model did not finish its response.',
      );
    }
    final message = firstChoice == null
        ? null
        : _asStringMap(firstChoice['message']);
    final content = message == null ? null : _contentText(message['content']);
    if (content == null || content.trim().isEmpty) {
      throw const ExternalAiResponseException('响应缺少 message.content');
    }
    return _decodeJsonObject(content);
  }

  /// 请求普通文本并按 SSE 流式返回累计全文。
  Stream<ChatTextFrame> streamText({
    required List<Map<String, Object?>> messages,
    CancelToken? cancelToken,
  }) async* {
    _validateConfiguration();
    try {
      yield* _streamText(messages: messages, cancelToken: cancelToken);
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) rethrow;
      throw _requestFailure(error);
    } on TimeoutException {
      throw const ExternalAiResponseException(
        'AI response timed out. Please retry.',
      );
    } on FormatException {
      throw const ExternalAiResponseException('Invalid streaming response.');
    }
  }

  /// 解码 SSE 增量；只有非空且完整结束的响应才能作为成功结果。
  Stream<ChatTextFrame> _streamText({
    required List<Map<String, Object?>> messages,
    CancelToken? cancelToken,
  }) async* {
    final response = await _dio.post<ResponseBody>(
      'chat/completions',
      data: {'model': config.model, 'messages': messages, 'stream': true},
      options: Options(
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
      ),
      cancelToken: cancelToken,
    );
    final body = response.data;
    final status = response.statusCode ?? 0;
    if (body == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
      );
    }
    if (status < 200 || status >= 300) {
      await body.stream.drain<void>();
      throw DioException(
        requestOptions: response.requestOptions,
        response: Response<Object?>(
          requestOptions: response.requestOptions,
          statusCode: status,
        ),
        type: DioExceptionType.badResponse,
      );
    }

    final buffer = StringBuffer();
    await for (final line
        in utf8.decoder
            .bind(body.stream.timeout(const Duration(seconds: 90)))
            .transform(const LineSplitter())) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;
      final payload = trimmed.substring('data:'.length).trim();
      if (payload.isEmpty) continue;
      final cancellation = cancelToken?.cancelError;
      if (cancellation != null) throw cancellation;
      if (payload == '[DONE]') {
        if (buffer.isEmpty) {
          throw const ExternalAiResponseException(
            'The model returned no text.',
          );
        }
        yield ChatTextFrame(text: buffer.toString(), isFinal: true);
        return;
      }
      Map<String, Object?>? event;
      try {
        event = _asStringMap(jsonDecode(payload));
      } on FormatException {
        throw const ExternalAiResponseException('Invalid streaming JSON.');
      }
      if (event == null) continue;
      if (event.containsKey('error')) {
        throw const ExternalAiResponseException(
          'The AI provider reported a stream error.',
        );
      }
      final choices = event['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final choice = _asStringMap(choices.first);
      final finishReason = choice?['finish_reason'];
      if (finishReason != null && finishReason != 'stop') {
        throw const ExternalAiResponseException(
          'The model did not finish its response.',
        );
      }
      final delta = choice == null ? null : _asStringMap(choice['delta']);
      final content = delta == null ? null : _contentText(delta['content']);
      if (content == null || content.isEmpty) continue;
      buffer.write(content);
      yield ChatTextFrame(text: buffer.toString(), isFinal: false);
    }
    throw const ExternalAiResponseException(
      'The AI stream ended before completion.',
    );
  }

  /// 释放 HTTP 资源。
  void dispose() => _dio.close(force: true);

  void _validateConfiguration() {
    if (!config.isValid) {
      throw const ExternalAiResponseException(
        'Invalid AI settings. Check the Base URL, model and API key.',
      );
    }
  }

  /// 仅记录状态码和错误类型；不传播含 Key、请求正文或供应商回显的 Dio 异常。
  ExternalAiResponseException _requestFailure(DioException error) {
    final status = error.response?.statusCode;
    AppLogger.log('ExternalAI', '请求失败 status=$status type=${error.type.name}');
    final message = switch (status) {
      401 || 403 => 'AI provider authentication failed. Check your API key.',
      402 =>
        'AI provider balance is insufficient. Check your provider account.',
      429 => 'AI provider rate limit reached. Please retry later.',
      _ =>
        'AI request failed${status == null ? '' : ' (HTTP $status)'}. Check the Base URL and model.',
    };
    return ExternalAiResponseException(message, statusCode: status);
  }

  static Map<String, Object?>? _asStringMap(Object? value) =>
      value is Map<String, Object?> ? value : null;

  static String? _contentText(Object? value) {
    if (value is String) return value;
    if (value is! List) return null;
    final parts = <String>[];
    for (final item in value) {
      final map = _asStringMap(item);
      final text = map == null ? null : map['text'];
      if (text is String) parts.add(text);
    }
    return parts.isEmpty ? null : parts.join();
  }

  static Map<String, Object?> _decodeJsonObject(String content) {
    var text = content.trim();
    const fence = '\u0060\u0060\u0060';
    if (text.startsWith(fence)) {
      final firstLineEnd = text.indexOf('\n');
      if (firstLineEnd >= 0) text = text.substring(firstLineEnd + 1);
      if (text.endsWith(fence)) text = text.substring(0, text.length - 3);
      text = text.trim();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const ExternalAiResponseException(
        'The model returned invalid JSON.',
      );
    }
    final result = _asStringMap(decoded);
    if (result == null) {
      throw const ExternalAiResponseException('模型返回的内容不是 JSON 对象');
    }
    return result;
  }
}

/// 使用外部模型的聊天实现。
class OpenAiCompatibleChatApi implements ChatApi, ExternalChatApi {
  final OpenAiCompatibleAiClient _client;

  OpenAiCompatibleChatApi(ExternalAiConfig config)
    : _client = OpenAiCompatibleAiClient(config);

  /// 测试用构造函数，允许复用已注入 Dio 的外部客户端。
  OpenAiCompatibleChatApi.withClient(this._client);

  @override
  bool get usesExternalProvider => true;

  @override
  Stream<ChatTextFrame> streamChat({
    required String endpoint,
    required List<ChatMessage> history,
    required Map<String, Object?> context,
    required String followUpInstruction,
    String? targetLanguage,
    required String accessToken,
    CancelToken? cancelToken,
  }) {
    final contextText = context.isEmpty
        ? ''
        : '\nContext: ${jsonEncode(context)}';
    final languageText = targetLanguage == null
        ? ''
        : '\nAnswer in the learner\'s language: $targetLanguage.';
    final messages = <Map<String, Object?>>[
      {
        'role': 'system',
        'content':
            'You are an English learning assistant. Explain English clearly, give useful examples, and keep the answer focused.$languageText$contextText',
      },
      for (final message in history)
        message.toWire(instruction: followUpInstruction),
    ];
    return _client.streamText(messages: messages, cancelToken: cancelToken);
  }

  @override
  void dispose() => _client.dispose();
}
