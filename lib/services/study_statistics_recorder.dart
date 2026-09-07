import 'dart:async';

import '../models/study_stage.dart';
import 'app_logger.dart';
import 'learned_vocabulary_tracker.dart';
import 'study_time_service.dart';

/// 统计基础设施的统一异步写入模块。
///
/// 播放、录音和前台时长均通过独立事件写入，不依赖学习任务完成状态。
final class StudyStatisticsRecorder {
  StudyStatisticsRecorder({
    required StudyTimeService studyTimeService,
    LearnedVocabularyTracker? vocabularyTracker,
  }) : _studyTimeService = studyTimeService,
       _vocabularyTracker = vocabularyTracker;

  final StudyTimeService _studyTimeService;
  final LearnedVocabularyTracker? _vocabularyTracker;

  /// 记录句子播放完成。
  Future<void> recordSentencePlayback({
    required Duration duration,
    required int heardWordCount,
    required String text,
    StudyStage? stage,
    DateTime? date,
  }) async {
    await _studyTimeService.addInputDuration(duration, date: date, stage: stage);
    if (heardWordCount > 0) {
      await _studyTimeService.addInputWords(heardWordCount, date: date);
    }
    if (text.trim().isNotEmpty) {
      await _vocabularyTracker?.recordSentence(text, learnedAt: date);
    }
  }

  /// 记录词汇播放完成；短于一秒的播放仍然会记录词数。
  Future<void> recordVocabularyPlayback({
    required Duration duration,
    String? wordForm,
    StudyStage? stage,
    DateTime? date,
  }) => recordSentencePlayback(
    duration: duration,
    heardWordCount: 1,
    text: wordForm ?? '',
    stage: stage,
    date: date,
  );

  /// 记录录音识别完成。
  Future<void> recordSpeechRecognition({
    required Duration duration,
    int producedWordCount = 0,
    StudyStage? stage,
    DateTime? date,
  }) async {
    await _studyTimeService.addOutputDuration(duration, date: date, stage: stage);
    if (producedWordCount > 0) {
      await _studyTimeService.addOutputWords(producedWordCount, date: date);
    }
  }

  /// 记录前台有效学习时长。
  Future<void> recordActiveDuration(
    Duration duration, {
    StudyStage? stage,
    DateTime? date,
  }) => _studyTimeService.addStudyDuration(duration, date: date, stage: stage);

  /// 安全地异步提交统计，避免后台事件产生未处理异常。
  void recordAsync(Future<void> operation) {
    unawaited(operation.catchError((Object error, StackTrace stackTrace) {
      AppLogger.log('StudyStatistics', 'write.failed error=$error\n$stackTrace');
    }));
  }
}
