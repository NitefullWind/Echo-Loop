import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_io/io.dart';
import 'package:echo_loop/services/external_retell_evaluator.dart';
import 'package:echo_loop/services/openai_compatible_ai_client.dart';
import 'package:echo_loop/services/transcription_api_client.dart';

void main() {
  Future<Object?> evaluate(
    ExternalRetellEvaluator evaluator,
    CancelToken token,
  ) => evaluator.evaluate(
    audioFile: File('recording.m4a'),
    originalText: 'Practice daily.',
    targetLanguage: 'zh',
    cancelToken: token,
  );

  test('空转录不调用文本模型', () async {
    var calls = 0;
    final evaluator = ExternalRetellEvaluator(
      transcribe:
          ({
            required audioFile,
            required language,
            required cancelToken,
          }) async => const TranscriptResult(sentences: [], fullText: '  '),
      completeJson:
          ({required systemPrompt, required userPrompt, cancelToken}) async {
            calls++;
            return {};
          },
    );
    await expectLater(
      evaluate(evaluator, CancelToken()),
      throwsA(isA<ExternalAiResponseException>()),
    );
    expect(calls, 0);
  });

  test('识别错误原样传播且不请求文本模型', () async {
    final error = StateError('speech unavailable');
    var calls = 0;
    final evaluator = ExternalRetellEvaluator(
      transcribe:
          ({
            required audioFile,
            required language,
            required cancelToken,
          }) async => throw error,
      completeJson:
          ({required systemPrompt, required userPrompt, cancelToken}) async {
            calls++;
            return {};
          },
    );
    await expectLater(evaluate(evaluator, CancelToken()), throwsA(same(error)));
    expect(calls, 0);
  });

  test('识别期间取消后迟到结果不启动文本请求', () async {
    final speech = Completer<TranscriptResult>();
    final started = Completer<void>();
    var calls = 0;
    final token = CancelToken();
    final evaluator = ExternalRetellEvaluator(
      transcribe:
          ({required audioFile, required language, required cancelToken}) {
            started.complete();
            return speech.future;
          },
      completeJson:
          ({required systemPrompt, required userPrompt, cancelToken}) async {
            calls++;
            return {};
          },
    );
    final result = evaluate(evaluator, token);
    final check = expectLater(
      result,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await started.future;
    token.cancel();
    speech.complete(
      const TranscriptResult(sentences: [], fullText: 'Practice daily.'),
    );
    await check;
    expect(calls, 0);
  });

  test('无效完整评价拒绝半成品', () async {
    final evaluator = ExternalRetellEvaluator(
      transcribe:
          ({
            required audioFile,
            required language,
            required cancelToken,
          }) async => const TranscriptResult(
            sentences: [],
            fullText: 'Practice daily.',
          ),
      completeJson:
          ({required systemPrompt, required userPrompt, cancelToken}) async => {
            'summary': 'ok',
            'rating': 'good',
          },
    );
    await expectLater(
      evaluate(evaluator, CancelToken()),
      throwsA(isA<ExternalAiResponseException>()),
    );
  });
}
