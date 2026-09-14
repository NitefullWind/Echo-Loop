import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_loop/models/speech_practice_models.dart';
import 'package:echo_loop/providers/learning_settings_provider.dart';
import 'package:echo_loop/providers/offline_asr_settings_provider.dart';
import 'package:echo_loop/providers/retell_recording_controller_provider.dart';
import 'package:echo_loop/services/speech_practice_platform.dart';

import '../helpers/mock_providers.dart';

const _testAsrModel = AsrModelInfo(
  id: 'test-model',
  displayName: 'Test Model',
  type: AsrModelType.moonshine,
);

final _testAsrSettings = OfflineAsrSettingsState(
  enabled: true,
  backend: AsrBackend.platform,
  recommendedModel: _testAsrModel,
);

class _FakeOfflineAsrSettingsNotifier extends OfflineAsrSettingsNotifier {
  @override
  OfflineAsrSettingsState build() => _testAsrSettings;
}

class _FakeSpeechPracticeBackend implements SpeechPracticeBackend {
  final _controller = StreamController<SpeechPracticeEvent>.broadcast();
  String? activePromptId;
  int counter = 0;
  bool failStopSession = false;

  @override
  bool get isSupported => true;

  @override
  Stream<SpeechPracticeEvent> get events => _controller.stream;

  @override
  Future<SpeechPracticePermissionState> getPermissionStatus() async {
    return const SpeechPracticePermissionState(
      microphone: SpeechPracticePermissionStatus.granted,
      speech: SpeechPracticePermissionStatus.granted,
    );
  }

  @override
  Future<SpeechPracticePermissionState> requestPermissions({
    bool onlyMic = false,
  }) {
    return getPermissionStatus();
  }

  @override
  Future<void> warmup({String locale = 'en-US'}) async {}

  @override
  Future<int> getDeviceRamBytes() async => 0;

  @override
  Future<void> setRecognitionEnabled(bool enabled) async {}

  @override
  Future<void> shutdown() async {}

  @override
  Future<String> startSession({
    required String promptId,
    String locale = 'en-US',
  }) async {
    activePromptId = promptId;
    counter += 1;
    return '/tmp/$promptId-$counter.caf';
  }

  @override
  Future<SpeechPracticeStopResult> stopSession() async {
    if (failStopSession) {
      throw StateError('stop failed');
    }
    final promptId = activePromptId ?? 'retell:a1:0';
    scheduleMicrotask(() {
      _controller.add(
        SpeechPracticeEvent(
          type: SpeechPracticeEventType.finalTranscriptReady,
          promptId: promptId,
          transcript: 'retell transcript',
        ),
      );
    });
    return SpeechPracticeStopResult(filePath: '/tmp/$promptId-$counter.caf');
  }

  @override
  Future<void> cancelSession() async {}

  @override
  Future<void> deleteRecording(String filePath) async {}

  void emitPartial(String transcript) {
    _controller.add(
      SpeechPracticeEvent(
        type: SpeechPracticeEventType.partialTranscriptUpdated,
        promptId: activePromptId ?? 'retell:a1:0',
        transcript: transcript,
      ),
    );
  }

  void emitSpeechStarted() {
    _controller.add(
      SpeechPracticeEvent(
        type: SpeechPracticeEventType.speechStarted,
        promptId: activePromptId ?? 'retell:a1:0',
      ),
    );
  }

  void emitSilence(Duration duration) {
    _controller.add(
      SpeechPracticeEvent(
        type: SpeechPracticeEventType.silenceProgress,
        promptId: activePromptId ?? 'retell:a1:0',
        silenceDuration: duration,
      ),
    );
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> disposeTestResources({
    required RetellRecordingController controller,
    required ProviderContainer container,
    required _FakeSpeechPracticeBackend backend,
  }) async {
    // ProviderContainer.dispose() 不等待 Notifier 的异步 onDispose；先显式
    // 收尾录音会话和事件订阅，避免下一个测试与旧 RecordingService 交叠。
    await controller.fullReset();
    await backend.dispose();
    container.dispose();
  }

  test('RetellRecordingController 在停止录音后触发有效录音时长回调', () async {
    final backend = _FakeSpeechPracticeBackend();
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );
    Duration? recordedDuration;
    controller.setRecordingCompletionHandler((duration) {
      recordedDuration = duration;
    });

    await controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'ask your professor today for authorization again',
    );

    backend.emitSpeechStarted();
    backend.emitPartial('ask your professor today');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    backend.emitSilence(const Duration(milliseconds: 100));

    await controller.stopAndEvaluate(
      referenceText: 'ask your professor today for authorization again',
    );

    expect(recordedDuration, isNotNull);
    expect(
      recordedDuration,
      greaterThanOrEqualTo(const Duration(milliseconds: 900)),
    );
  });

  test('RetellRecordingController 关闭复述评级时只保留录音并跳过转录评分', () async {
    final backend = _FakeSpeechPracticeBackend();
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(retellRatingEnabled: false),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );

    await controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'ask your professor today for authorization again',
    );

    await controller.stopAndEvaluate(
      referenceText: 'ask your professor today for authorization again',
    );

    final attempt = container
        .read(retellRecordingControllerProvider)
        .currentAttempt;
    expect(attempt, isNotNull);
    expect(attempt!.filePath, isNotEmpty);
    expect(attempt.status, SpeechPracticeAttemptStatus.unavailable);
    expect(attempt.score, isNull);
    expect(attempt.finalTranscript, isNull);
    expect(attempt.transcriptSegments, isEmpty);
    expect(attempt.referenceSegments, isEmpty);
  });

  test('RetellRecordingController 取消录音不触发统计回调', () async {
    final backend = _FakeSpeechPracticeBackend();
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );
    Duration? recordedDuration;
    controller.setRecordingCompletionHandler((duration) {
      recordedDuration = duration;
    });

    await controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'ask your professor today',
    );
    await controller.cancelActiveRecording();

    expect(recordedDuration, isNull);
  });

  test('RetellRecordingController 停止录音失败不触发统计回调', () async {
    final backend = _FakeSpeechPracticeBackend()..failStopSession = true;
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );
    Duration? recordedDuration;
    controller.setRecordingCompletionHandler((duration) {
      recordedDuration = duration;
    });

    await controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'ask your professor today',
    );
    await controller.stopAndEvaluate(referenceText: 'ask your professor today');

    expect(recordedDuration, isNull);
  });
}
