/// 收藏词汇闪卡复习状态与控制器（本步仅实现正面）。
///
/// 会话状态机复用通用调度引擎 `ScheduledFlashcardController<FlashcardItem>`
/// （`lib/features/scheduled_flashcard/`），机制与 `BookmarkReview`
/// （收藏句复习）完全一致；区别只在于：
/// - 正面重播调用的是词汇收藏列表同款的 `textPlaybackProvider`
///   （离线发音库优先，回退 TTS），不是收藏句用的前台音频引擎；
/// - 本步翻到背面只做状态流转（`face` 置为 back），不取 preview、不接评分，
///   反面内容留待后续任务。
/// 所有播放操作都用 generation 隔离，切卡、翻面和退出后，旧异步回调不能恢复
/// 播放或污染状态。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../database/app_database.dart';
import '../../database/providers.dart';
import '../../features/memory_scheduler/domain/memory_rating.dart';
import '../../features/memory_scheduler/domain/memory_scheduler_results.dart';
import '../../features/memory_scheduler/providers/memory_scheduler_providers.dart';
import '../../features/scheduled_flashcard/application/scheduled_flashcard_controller.dart';
import '../../features/scheduled_flashcard/domain/scheduled_flashcard.dart';
import '../../features/scheduled_flashcard/domain/review_session_summary.dart';
import '../../models/flashcard_item.dart';
import '../../models/study_stage.dart';
import '../../services/app_logger.dart';
import '../../services/study_session_timer.dart';
import '../favorite_review_settings_provider.dart';
import '../favorite_vocabulary_lifecycle_provider.dart';
import '../pronunciation/pronunciation_providers.dart';
import '../short_audio_player_provider.dart';
import '../tts/tts_controller_provider.dart';
import 'favorite_vocabulary_deck_source.dart';
import '../../services/pronunciation/source_sentence_player.dart';

part 'favorite_vocabulary_review_provider.g.dart';

enum FavoriteVocabularyReviewFace { front, back }

enum FavoriteVocabularyReviewPlaybackState { idle, loading, playing, failed }

@immutable
class FavoriteVocabularyReviewState {
  const FavoriteVocabularyReviewState({
    this.currentCard,
    this.initialTotal = 0,
    this.remainingCount = 0,
    this.face = FavoriteVocabularyReviewFace.front,
    this.wordPlaybackState = FavoriteVocabularyReviewPlaybackState.idle,
    this.sourcePlaybackState = FavoriteVocabularyReviewPlaybackState.idle,
    this.isRemoving = false,
    this.mediaError,
    this.removeError,
    this.preview,
    this.isSubmittingRating = false,
    this.reviewedCount = 0,
    this.completionSummary,
  });

  final FlashcardItem? currentCard;
  final int initialTotal;
  final int remainingCount;
  final FavoriteVocabularyReviewFace face;
  final FavoriteVocabularyReviewPlaybackState wordPlaybackState;
  final FavoriteVocabularyReviewPlaybackState sourcePlaybackState;
  final bool isRemoving;
  final String? mediaError;
  final String? removeError;
  final MemoryRatingPreviewSet? preview;
  final bool isSubmittingRating;
  final int reviewedCount;
  final ReviewSessionSummary? completionSummary;

  double get progress =>
      initialTotal == 0 ? 0 : (initialTotal - remainingCount) / initialTotal;

  FavoriteVocabularyReviewState copyWith({
    FlashcardItem? currentCard,
    bool clearCurrentCard = false,
    int? initialTotal,
    int? remainingCount,
    FavoriteVocabularyReviewFace? face,
    FavoriteVocabularyReviewPlaybackState? wordPlaybackState,
    FavoriteVocabularyReviewPlaybackState? sourcePlaybackState,
    bool? isRemoving,
    String? mediaError,
    bool clearMediaError = false,
    String? removeError,
    bool clearRemoveError = false,
    MemoryRatingPreviewSet? preview,
    bool clearPreview = false,
    bool? isSubmittingRating,
    int? reviewedCount,
    ReviewSessionSummary? completionSummary,
    bool clearCompletionSummary = false,
  }) => FavoriteVocabularyReviewState(
    currentCard: clearCurrentCard ? null : currentCard ?? this.currentCard,
    initialTotal: initialTotal ?? this.initialTotal,
    remainingCount: remainingCount ?? this.remainingCount,
    face: face ?? this.face,
    wordPlaybackState: wordPlaybackState ?? this.wordPlaybackState,
    sourcePlaybackState: sourcePlaybackState ?? this.sourcePlaybackState,
    isRemoving: isRemoving ?? this.isRemoving,
    mediaError: clearMediaError ? null : mediaError ?? this.mediaError,
    removeError: clearRemoveError ? null : removeError ?? this.removeError,
    preview: clearPreview ? null : preview ?? this.preview,
    isSubmittingRating: isSubmittingRating ?? this.isSubmittingRating,
    reviewedCount: reviewedCount ?? this.reviewedCount,
    completionSummary: clearCompletionSummary
        ? null
        : completionSummary ?? this.completionSummary,
  );
}

@Riverpod(keepAlive: true)
class FavoriteVocabularyReview extends _$FavoriteVocabularyReview {
  int _generation = 0;
  bool _hasSourcePlayback = false;
  late final AppLifecycleListener _lifecycleListener;
  StudySessionTimer? _studySessionTimer;
  ScheduledFlashcardController<FlashcardItem>? _controller;
  ReviewSessionSummary _summary = const ReviewSessionSummary();

  /// 当前收藏词汇复习会话的前台有效时长。
  Duration get elapsed => _studySessionTimer?.elapsed ?? Duration.zero;

  @override
  FavoriteVocabularyReviewState build() {
    final playback = ref.read(textPlaybackProvider.notifier);
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (value) {
        if (value == AppLifecycleState.paused ||
            value == AppLifecycleState.hidden ||
            value == AppLifecycleState.detached) {
          unawaited(interruptPlayback());
        }
      },
    );
    ref.onDispose(() {
      _generation++;
      _lifecycleListener.dispose();
      _controller?.dispose();
      unawaited(playback.stop());
      unawaited(_studySessionTimer?.dispose());
    });
    return const FavoriteVocabularyReviewState();
  }

  /// 建立只含 FSRS 到期收藏词汇（单词 + 意群）的本次复习快照。
  Future<void> initialize(
    List<SavedWord> words,
    List<SavedSenseGroup> phrases,
  ) async {
    await _studySessionTimer?.dispose();
    _studySessionTimer = null;
    _summary = const ReviewSessionSummary();
    _generation++;
    unawaited(ref.read(textPlaybackProvider.notifier).stop());

    _controller?.dispose();
    final scheduler = ref.read(memorySchedulerProvider);
    final controller = ScheduledFlashcardController<FlashcardItem>(
      deckSource: FavoriteVocabularyDeckSource(
        words: words,
        phrases: phrases,
        scheduler: scheduler,
        settings: ref.read(favoriteReviewSettingsProvider),
      ),
      ratingPort: MemorySchedulerFlashcardRatingPort(scheduler),
      operationIdGenerator: ref.read(memoryIdGeneratorProvider),
      logger: (message) => AppLogger.log('FavoriteVocabularyReview', message),
    );
    _controller = controller;
    await controller.load();
    if (!identical(_controller, controller)) return;
    final completionSummary =
        controller.state.phase == ScheduledFlashcardPhase.completed
        ? _summary.complete(elapsed: Duration.zero, reviewedCount: 0)
        : null;
    state = _stateFromController(
      controller,
      completionSummary: completionSummary,
    );
    if (completionSummary != null) return;
    // 每次新建复习快照都创建新的计时会话，避免复用已停止的 timer。
    _studySessionTimer = StudySessionTimer(
      studyTimeService: ref.read(studyTimeServiceProvider),
      stage: StudyStage.savedVocabularyReview,
      activityGate: ref.read(studyActivityGateProvider),
      logScope: 'SavedVocabularyReviewTimer',
    );
    _studySessionTimer!.start();
  }

  /// 仅在共享偏好开启时自动播放正面；手动重播不受该偏好影响。
  Future<void> startCurrentCard() async {
    if (ref.read(favoriteReviewSettingsProvider).autoPlayFront) {
      await replayCurrent();
    }
  }

  /// 立即废弃旧播放，重新朗读当前词汇（离线发音库优先，回退 TTS）。
  Future<void> replayCurrent() async {
    final card = state.currentCard;
    if (card == null) return;
    final generation = ++_generation;
    final player = ref.read(textPlaybackProvider.notifier);
    await player.stop();
    if (!_isCurrent(generation, card)) return;
    state = state.copyWith(
      wordPlaybackState: FavoriteVocabularyReviewPlaybackState.loading,
      sourcePlaybackState: FavoriteVocabularyReviewPlaybackState.idle,
      clearMediaError: true,
    );
    try {
      if (!_isCurrent(generation, card)) return;
      state = state.copyWith(
        wordPlaybackState: FavoriteVocabularyReviewPlaybackState.playing,
      );
      // 与查词弹窗和收藏词汇列表共用同一默认朗读入口：多发音时播稳定排序后的第一条。
      await player.speak(card.displayText, key: card.dbKey);
      if (!_isCurrent(generation, card)) return;
      state = state.copyWith(
        wordPlaybackState: FavoriteVocabularyReviewPlaybackState.idle,
      );
    } catch (error, stackTrace) {
      if (!_isCurrent(generation, card)) return;
      AppLogger.log(
        'FavoriteVocabularyReview',
        'playback failed error=$error\n$stackTrace',
      );
      state = state.copyWith(
        wordPlaybackState: FavoriteVocabularyReviewPlaybackState.failed,
        mediaError: 'audio_unavailable',
      );
    }
  }

  Future<void> toggleCurrentPlayback() async {
    final playbackState = state.wordPlaybackState;
    if (playbackState == FavoriteVocabularyReviewPlaybackState.loading ||
        playbackState == FavoriteVocabularyReviewPlaybackState.playing) {
      await interruptPlayback();
      return;
    }
    await replayCurrent();
  }

  /// 翻到背面后预取三档评分结果，评分语义与收藏句保持一致。
  Future<void> revealBack() async {
    final controller = _controller;
    final card = state.currentCard;
    if (controller == null ||
        card == null ||
        state.face != FavoriteVocabularyReviewFace.front) {
      return;
    }
    await interruptPlayback();
    controller.revealAnswer();
    state = state.copyWith(
      face: FavoriteVocabularyReviewFace.back,
      clearPreview: true,
    );
    await controller.preview();
    if (!identical(_controller, controller)) return;
    if (state.currentCard == card &&
        state.face == FavoriteVocabularyReviewFace.back) {
      state = state.copyWith(preview: controller.state.preview);
      if (ref.read(favoriteReviewSettingsProvider).autoPlayBack) {
        unawaited(playSourceSentence());
      }
    }
  }

  /// 按收藏词汇列表同一契约播放来源句：原音区间优先，失败才回退 TTS。
  Future<void> playSourceSentence() async {
    final card = state.currentCard;
    if (card == null ||
        state.face != FavoriteVocabularyReviewFace.back ||
        card.sentenceText?.trim().isEmpty != false) {
      return;
    }
    final generation = ++_generation;
    const playbackKey = 'favorite-vocabulary-review-source';
    await interruptPlayback();
    if (!_isCurrent(generation + 1, card)) return;
    final player = SourceSentencePlayer(
      audioItemDao: ref.read(audioItemDaoProvider),
      audioClipPlayer: ref.read(shortAudioPlayerProvider),
      speak: (text, key) =>
          ref.read(ttsControllerProvider.notifier).speak(text, key: key),
    );
    try {
      _hasSourcePlayback = true;
      state = state.copyWith(
        wordPlaybackState: FavoriteVocabularyReviewPlaybackState.idle,
        sourcePlaybackState: FavoriteVocabularyReviewPlaybackState.playing,
      );
      await player.play(
        audioItemId: card.audioItemId,
        sentenceIndex: card.sentenceIndex,
        sentenceText: card.sentenceText,
        sentenceStartMs: card.sentenceStartMs,
        sentenceEndMs: card.sentenceEndMs,
        playbackKey: playbackKey,
      );
    } catch (error, stackTrace) {
      AppLogger.log(
        'FavoriteVocabularyReview',
        'source playback failed error=$error\n$stackTrace',
      );
    } finally {
      if (_isCurrent(generation + 1, card)) {
        _hasSourcePlayback = false;
        state = state.copyWith(
          sourcePlaybackState: FavoriteVocabularyReviewPlaybackState.idle,
        );
      }
    }
  }

  /// 切换当前来源句播放；播放中再次点击会停止，空闲时从头播放。
  Future<void> toggleSourcePlayback() async {
    final playbackState = state.sourcePlaybackState;
    if (playbackState == FavoriteVocabularyReviewPlaybackState.loading ||
        playbackState == FavoriteVocabularyReviewPlaybackState.playing) {
      await interruptPlayback();
      return;
    }
    await playSourceSentence();
  }

  /// 提交评分前先中断单词、来源句和 TTS 播放，避免最后一张卡进入完成页后
  /// 仍有共享播放器继续运行；成功后推进队列，失败保留当前背面以便重试。
  Future<void> selectRating(MemoryRating rating) async {
    final controller = _controller;
    final card = state.currentCard;
    if (controller == null ||
        card == null ||
        state.face != FavoriteVocabularyReviewFace.back ||
        state.isSubmittingRating ||
        state.preview == null) {
      return;
    }
    state = state.copyWith(isSubmittingRating: true);
    // 评分是当前卡片生命周期的终点，不能依赖下一张卡的自动播放间接停止旧媒体。
    try {
      await interruptPlayback();
    } catch (error, stackTrace) {
      AppLogger.log(
        'FavoriteVocabularyReview',
        'interrupt playback before rating failed error=$error\n$stackTrace',
      );
      state = state.copyWith(isSubmittingRating: false);
      return;
    }
    if (!identical(_controller, controller) ||
        !identical(state.currentCard, card) ||
        state.face != FavoriteVocabularyReviewFace.back) {
      return;
    }
    await controller.submitRating(rating);
    if (!identical(_controller, controller)) return;
    final phase = controller.state.phase;
    if (phase == ScheduledFlashcardPhase.prompt ||
        phase == ScheduledFlashcardPhase.completed) {
      final subjectId = card.memorySubjectId;
      if (subjectId != null) {
        _summary = _summary.recordRating(subjectId: subjectId, rating: rating);
      }
      final completionSummary = _completionSummaryIfFinished(controller);
      state = _stateFromController(
        controller,
        completionSummary: completionSummary,
      );
      if (controller.state.current != null) unawaited(startCurrentCard());
    } else {
      AppLogger.log(
        'FavoriteVocabularyReview',
        'rating submission failed error=${controller.state.error}',
      );
      state = state.copyWith(isSubmittingRating: false);
    }
  }

  /// 取消收藏并归档当前调度卡，成功后移除当前卡并进入下一张。
  ///
  /// 此流程与收藏句复习保持一致：先停止媒体，再软删除收藏记录，归档仍 active
  /// 的 FSRS 调度快照，最后由通用控制器推进队列；任一持久化步骤失败均保留当前卡。
  Future<void> removeCurrentVocabulary() async {
    final controller = _controller;
    final card = state.currentCard;
    if (controller == null || card == null || state.isRemoving) return;
    await interruptPlayback();
    state = state.copyWith(isRemoving: true, clearRemoveError: true);
    try {
      switch (card) {
        case FlashcardWordItem():
          await ref
              .read(favoriteVocabularyLifecycleProvider)
              .removeWord(card.dbKey);
        case FlashcardPhraseItem():
          await ref
              .read(favoriteVocabularyLifecycleProvider)
              .removeSenseGroup(card.dbKey);
      }
      if (!identical(_controller, controller)) return;
      controller.removeCurrent();
      state = _stateFromController(
        controller,
        completionSummary: _completionSummaryIfFinished(controller),
      );
      if (controller.state.current != null) unawaited(startCurrentCard());
    } catch (error, stackTrace) {
      AppLogger.log(
        'FavoriteVocabularyReview',
        'unsave failed error=$error\n$stackTrace',
      );
      state = state.copyWith(isRemoving: false, removeError: 'unsave_failed');
    }
  }

  Future<void> interruptPlayback() async {
    _generation++;
    if (state.wordPlaybackState != FavoriteVocabularyReviewPlaybackState.idle ||
        state.sourcePlaybackState !=
            FavoriteVocabularyReviewPlaybackState.idle) {
      state = state.copyWith(
        wordPlaybackState: FavoriteVocabularyReviewPlaybackState.idle,
        sourcePlaybackState: FavoriteVocabularyReviewPlaybackState.idle,
      );
    }
    await ref.read(textPlaybackProvider.notifier).stop();
    if (_hasSourcePlayback) {
      _hasSourcePlayback = false;
      await ref.read(shortAudioPlayerProvider).stop();
      await ref.read(ttsControllerProvider.notifier).stop();
    }
  }

  Future<void> disposeSession() async {
    await interruptPlayback();
    await _studySessionTimer?.stop();
    _controller?.dispose();
    _controller = null;
    state = const FavoriteVocabularyReviewState();
  }

  /// 将通用会话的当前项和计数映射为页面所需的最小状态。
  FavoriteVocabularyReviewState _stateFromController(
    ScheduledFlashcardController<FlashcardItem> controller, {
    ReviewSessionSummary? completionSummary,
  }) => FavoriteVocabularyReviewState(
    currentCard: controller.state.current?.content,
    initialTotal: controller.state.initialTotal,
    remainingCount: controller.state.remainingCount,
    reviewedCount: controller.state.reviewedCount,
    completionSummary: completionSummary,
  );

  /// 调度器没有下一张可展示卡时，统一产出本次会话的完成快照。
  ///
  /// 评分结束和取消最后一张收藏词汇都会走这里；取消收藏本身不写入 [_summary]。
  ReviewSessionSummary? _completionSummaryIfFinished(
    ScheduledFlashcardController<FlashcardItem> controller,
  ) {
    if (controller.state.phase != ScheduledFlashcardPhase.completed) {
      return null;
    }
    unawaited(_studySessionTimer?.stop());
    return _summary.complete(
      elapsed: _studySessionTimer?.elapsed ?? Duration.zero,
      reviewedCount: controller.state.reviewedCount,
    );
  }

  bool _isCurrent(int generation, FlashcardItem card) =>
      generation == _generation && identical(state.currentCard, card);
}
