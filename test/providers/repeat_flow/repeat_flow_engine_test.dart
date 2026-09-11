import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:echo_loop/models/sentence.dart';
import 'package:echo_loop/models/sentence_playback_result.dart';
import 'package:echo_loop/providers/repeat_flow/repeat_flow_engine.dart';
import 'package:echo_loop/providers/repeat_flow/repeat_flow_phase.dart';
import 'package:echo_loop/providers/repeat_flow/repeat_flow_state.dart';

void main() {
  test('无评分但有录音文件时保留录音并继续流程', () async {
    var clearRecordingCalls = 0;
    RepeatFlowState? latestState;
    final engine = RepeatFlowEngine(
      onStateChanged: (state) => latestState = state,
      callbacks: RepeatFlowCallbacks(
        pauseAudio: () {},
        playSentence: (_, _) async => SentencePlaybackResult.completed,
        startRecording:
            ({
              required promptId,
              required referenceText,
              required maxDuration,
              referenceDuration,
            }) {},
        cancelRecording: () async {},
        stopAndEvaluate: ({required referenceText}) async {},
        clearRecording: () => clearRecordingCalls += 1,
        setMaxRecordingDuration: (_) {},
        hasDetectedSpeech: () => true,
      ),
    );
    engine.prepare(
      sentences: [
        Sentence(
          index: 0,
          text: 'Practice this sentence.',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
        ),
      ],
      config: RepeatFlowConfig(
        audioItemId: 'audio-1',
        getRepeatCount: (_) => 1,
        getIntervalDuration: (_) => const Duration(seconds: 30),
        isManualMode: () => false,
      ),
    );

    await engine.startPlaying();
    expect(latestState?.phase, isA<Recording>());

    engine.onRecordingFinished('/tmp/recording.m4a', null);

    expect(latestState?.recordingPath, '/tmp/recording.m4a');
    expect(latestState?.recordingScore, isNull);
    expect(latestState?.phase, isA<WaitingInterval>());
    expect(clearRecordingCalls, 0);
  });

  test('播放被取消时不进入录音', () async {
    var recordingStarts = 0;
    final engine = RepeatFlowEngine(
      onStateChanged: (_) {},
      callbacks: RepeatFlowCallbacks(
        pauseAudio: () {},
        playSentence: (_, _) async => SentencePlaybackResult.cancelled,
        startRecording:
            ({
              required promptId,
              required referenceText,
              required maxDuration,
              referenceDuration,
            }) => recordingStarts += 1,
        cancelRecording: () async {},
        stopAndEvaluate: ({required referenceText}) async {},
        clearRecording: () {},
        setMaxRecordingDuration: (_) {},
        hasDetectedSpeech: () => false,
      ),
    );
    engine.prepare(
      sentences: [
        Sentence(
          index: 0,
          text: 'Cancelled prompt.',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
        ),
      ],
      config: RepeatFlowConfig(
        audioItemId: 'audio-1',
        getRepeatCount: (_) => 1,
        getIntervalDuration: (_) => Duration.zero,
        isManualMode: () => false,
      ),
    );

    await engine.startPlaying();

    expect(recordingStarts, 0);
    expect(engine.state.phase, isA<WaitingForUser>());
  });

  test('重播会等待录音清理完成后才开始下一次播放', () async {
    final clearGate = Completer<void>();
    var playCalls = 0;
    final engine = RepeatFlowEngine(
      onStateChanged: (_) {},
      callbacks: RepeatFlowCallbacks(
        pauseAudio: () {},
        playSentence: (_, _) async {
          playCalls += 1;
          return SentencePlaybackResult.completed;
        },
        startRecording:
            ({
              required promptId,
              required referenceText,
              required maxDuration,
              referenceDuration,
            }) {},
        cancelRecording: () async {},
        stopAndEvaluate: ({required referenceText}) async {},
        clearRecording: () => clearGate.future,
        setMaxRecordingDuration: (_) {},
        hasDetectedSpeech: () => false,
      ),
    );
    engine.prepare(
      sentences: [
        Sentence(
          index: 0,
          text: 'Practice this sentence.',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
        ),
      ],
      config: RepeatFlowConfig(
        audioItemId: 'audio-1',
        getRepeatCount: (_) => 1,
        getIntervalDuration: (_) => Duration.zero,
        isManualMode: () => false,
      ),
    );

    await engine.startPlaying();
    expect(playCalls, 1);
    final replay = engine.replayCurrentSentence();
    await Future<void>.value();
    expect(playCalls, 1);

    clearGate.complete();
    await replay;
    expect(playCalls, 2);
  });
}
