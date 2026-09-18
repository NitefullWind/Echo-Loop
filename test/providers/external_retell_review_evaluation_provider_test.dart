import 'package:dio/dio.dart';
import 'package:echo_loop/features/auth/providers/auth_providers.dart';
import 'package:echo_loop/providers/external_ai_settings_provider.dart';
import 'package:echo_loop/providers/external_speech_settings_provider.dart';
import 'package:echo_loop/providers/external_speech_client_provider.dart';
import 'package:echo_loop/providers/retell_review_evaluation_provider.dart';
import 'package:echo_loop/services/external_speech_client.dart';
import 'package:echo_loop/services/transcription_api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_io/io.dart';

class _Text extends ExternalAiSettingsController {
  _Text(this.value);
  final ExternalAiSettings value;
  @override
  ExternalAiSettings build() => value;
}

class _Speech extends ExternalSpeechSettingsController {
  _Speech(this.value);
  final ExternalSpeechSettings value;
  @override
  ExternalSpeechSettings build() => value;
}

class _EmptySpeech implements ExternalSpeechClient {
  var calls = 0;
  @override
  Future<TranscriptResult> transcribe({
    required File audioFile,
    required String language,
    required CancelToken cancelToken,
    void Function(double)? onProgress,
  }) async {
    calls++;
    return const TranscriptResult(sentences: [], fullText: '');
  }

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const readySpeech = ExternalSpeechSettings(
    config: ExternalSpeechConfig(
      provider: ExternalSpeechProvider.aliyun,
      apiKey: 'test',
    ),
  );
  const readyText = ExternalAiSettings(
    provider: ExternalAiProvider.custom,
    baseUrl: 'https://example.test/v1',
    model: 'test',
    apiKey: 'test',
  );
  Future<void> run(ProviderContainer c) => c
      .read(retellReviewEvaluationProvider.notifier)
      .evaluate(
        attemptKey: 'a',
        recordingPath: 'recording.m4a',
        originalText: 'Hello.',
        targetLanguage: 'zh',
      );
  ProviderContainer make(
    ExternalSpeechSettings speech,
    ExternalAiSettings text,
    _EmptySpeech client,
  ) {
    final c = ProviderContainer(
      overrides: [
        externalAiSettingsProvider.overrideWith(() => _Text(text)),
        externalSpeechSettingsProvider.overrideWith(() => _Speech(speech)),
        externalSpeechClientProvider.overrideWithValue(client),
        supabaseSessionProvider.overrideWith(
          (ref) => throw StateError(
            'External review must not access authentication',
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('外部语音可在未登录时请求，空结果不会进入官方路径', () async {
    final speech = _EmptySpeech();
    final c = make(readySpeech, readyText, speech);
    await run(c);
    expect(speech.calls, 1);
    expect(c.read(retellReviewEvaluationProvider).errorCode, 'request_failed');
  });
  test('选择外部但缺少凭据时不访问官方认证', () async {
    final speech = _EmptySpeech();
    final c = make(
      const ExternalSpeechSettings(
        config: ExternalSpeechConfig(provider: ExternalSpeechProvider.aliyun),
      ),
      readyText,
      speech,
    );
    await run(c);
    expect(speech.calls, 0);
    expect(
      c.read(retellReviewEvaluationProvider).errorCode,
      'speech_not_configured',
    );
  });
  test('缺少文本配置时不调用语音识别', () async {
    final speech = _EmptySpeech();
    final c = make(readySpeech, const ExternalAiSettings(), speech);
    await run(c);
    expect(speech.calls, 0);
    expect(
      c.read(retellReviewEvaluationProvider).errorCode,
      'text_not_configured',
    );
  });
}
