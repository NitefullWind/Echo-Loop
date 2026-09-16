import 'package:flutter_test/flutter_test.dart';
import 'package:echo_loop/analytics/models/event_names.dart';

void main() {
  group('Events 常量', () {
    test('所有事件名不为空', () {
      const events = [
        Events.screenView,
        Events.loginMethodSelected,
        Events.learningStart,
        Events.learningEnd,
        Events.blindListenStart,
        Events.blindListenComplete,
        Events.blindListenDifficultySet,
        Events.intensiveListenStart,
        Events.intensiveListenComplete,
        Events.listenRepeatStart,
        Events.listenRepeatComplete,
        Events.retellStart,
        Events.retellComplete,
        Events.difficultPracticeStart,
        Events.difficultPracticeComplete,
        Events.firstLearnComplete,
        Events.stageAdvance,
        Events.collectionCreate,
        Events.audioUpload,
        Events.translationRequested,
        Events.analysisRequested,
        Events.senseGroupRequested,
        Events.subtitleUploaded,
        Events.transcriptionStarted,
        Events.transcriptionComplete,
        Events.subtitleEditorOpened,
        Events.bookmarkReviewStart,
        Events.bookmarkReviewComplete,
        Events.flashcardStart,
        Events.flashcardComplete,
        Events.recordingComplete,
        Events.wordLookup,
        Events.reminderUpdated,
        Events.asrSettingChanged,
        Events.studyTimeViewed,
        Events.subscriptionPageViewed,
      ];

      for (final name in events) {
        expect(name, isNotEmpty, reason: '事件名不能为空');
      }
    });

    test('所有事件名不重复', () {
      const events = [
        Events.screenView,
        Events.loginMethodSelected,
        Events.learningStart,
        Events.learningEnd,
        Events.blindListenStart,
        Events.blindListenComplete,
        Events.blindListenDifficultySet,
        Events.intensiveListenStart,
        Events.intensiveListenComplete,
        Events.listenRepeatStart,
        Events.listenRepeatComplete,
        Events.retellStart,
        Events.retellComplete,
        Events.difficultPracticeStart,
        Events.difficultPracticeComplete,
        Events.firstLearnComplete,
        Events.stageAdvance,
        Events.collectionCreate,
        Events.audioUpload,
        Events.translationRequested,
        Events.analysisRequested,
        Events.senseGroupRequested,
        Events.subtitleUploaded,
        Events.transcriptionStarted,
        Events.transcriptionComplete,
        Events.subtitleEditorOpened,
        Events.bookmarkReviewStart,
        Events.bookmarkReviewComplete,
        Events.flashcardStart,
        Events.flashcardComplete,
        Events.recordingComplete,
        Events.wordLookup,
        Events.reminderUpdated,
        Events.asrSettingChanged,
        Events.studyTimeViewed,
        Events.subscriptionPageViewed,
      ];

      final unique = events.toSet();
      expect(unique.length, events.length, reason: '存在重复的事件名');
    });

    test('自定义事件名符合命名规范（小写下划线连接）', () {
      // 排除 PostHog 官方保留名（$screen 等以 $ 开头）
      const events = [
        Events.learningStart,
        Events.loginMethodSelected,
        Events.learningEnd,
        Events.blindListenStart,
        Events.blindListenComplete,
        Events.blindListenDifficultySet,
        Events.intensiveListenStart,
        Events.intensiveListenComplete,
        Events.listenRepeatStart,
        Events.listenRepeatComplete,
        Events.retellStart,
        Events.retellComplete,
        Events.difficultPracticeStart,
        Events.difficultPracticeComplete,
        Events.firstLearnComplete,
        Events.stageAdvance,
        Events.collectionCreate,
        Events.audioUpload,
        Events.translationRequested,
        Events.analysisRequested,
        Events.senseGroupRequested,
        Events.subtitleUploaded,
        Events.transcriptionStarted,
        Events.transcriptionComplete,
        Events.subtitleEditorOpened,
        Events.bookmarkReviewStart,
        Events.bookmarkReviewComplete,
        Events.flashcardStart,
        Events.flashcardComplete,
        Events.recordingComplete,
        Events.wordLookup,
        Events.reminderUpdated,
        Events.asrSettingChanged,
        Events.studyTimeViewed,
        Events.subscriptionPageViewed,
      ];

      final pattern = RegExp(r'^[a-z][a-z0-9_]*$');
      for (final name in events) {
        expect(pattern.hasMatch(name), isTrue, reason: '"$name" 不符合小写下划线命名规范');
      }
    });

    test('复述跳过事件常量正确', () {
      expect(Events.retellToggleChanged, 'retell_toggle_changed');
      expect(Events.retellSkipped, 'retell_skipped');
    });

    test('复述参数常量正确', () {
      expect(EventParams.enabled, 'enabled');
      expect(EventParams.source, 'source');
    });
  });

  group('EventParams 常量', () {
    test('所有参数名不为空', () {
      const params = [
        EventParams.audioId,
        EventParams.stage,
        EventParams.durationMs,
        EventParams.screenName,
        EventParams.previousScreen,
        EventParams.method,
        EventParams.isFreePractice,
        EventParams.difficulty,
        EventParams.passNumber,
        EventParams.totalSentences,
        EventParams.difficultCount,
        EventParams.totalParagraphs,
        EventParams.totalDurationMs,
        EventParams.fromStage,
        EventParams.toStage,
        EventParams.mode,
        EventParams.score,
        EventParams.word,
        EventParams.reminderEnabled,
        EventParams.reminderTime,
        EventParams.asrEnabled,
        EventParams.asrBackend,
        EventParams.totalCards,
        EventParams.totalSentencesCount,
      ];

      for (final name in params) {
        expect(name, isNotEmpty, reason: '参数名不能为空');
      }
    });

    test('所有参数名不重复', () {
      const params = [
        EventParams.audioId,
        EventParams.stage,
        EventParams.durationMs,
        EventParams.screenName,
        EventParams.previousScreen,
        EventParams.method,
        EventParams.isFreePractice,
        EventParams.difficulty,
        EventParams.passNumber,
        EventParams.totalSentences,
        EventParams.difficultCount,
        EventParams.totalParagraphs,
        EventParams.totalDurationMs,
        EventParams.fromStage,
        EventParams.toStage,
        EventParams.mode,
        EventParams.score,
        EventParams.word,
        EventParams.reminderEnabled,
        EventParams.reminderTime,
        EventParams.asrEnabled,
        EventParams.asrBackend,
        EventParams.totalCards,
        EventParams.totalSentencesCount,
      ];

      final unique = params.toSet();
      expect(unique.length, params.length, reason: '存在重复的参数名');
    });
  });
}
