/// 学习会话层 Provider
///
/// 管理学习模式状态（盲听等），进入盲听时暂停 ListeningPractice
/// 的 stream 监听，通过 BlindListenPlayer 直接操作 AudioEngine。
/// 负责：进入/退出学习模式、保存/恢复用户播放设置、监听播放完成。
library;

import 'dart:async';
import 'dart:math' show min;
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../analytics/analytics_providers.dart';
import '../../analytics/audio_event_params.dart';
import '../../analytics/models/event_names.dart';
import '../../database/enums.dart';
import '../../models/blind_listen_settings.dart';
import '../../models/difficult_practice_settings.dart';
import '../../models/intensive_listen_settings.dart';
import '../../models/learning_progress.dart';
import '../../models/audio_item.dart';
import '../../models/media_load_result.dart';
import '../../models/playback_settings.dart';
import '../../models/retell_settings.dart';
import '../../models/sentence.dart';
import '../../database/providers.dart';
import '../../models/study_stage.dart';
import '../../services/study_time_service.dart';
import '../daily_study_time_provider.dart';
import '../../services/learned_vocabulary_tracker.dart';
import '../learned_vocabulary_tracker_provider.dart';
import '../study_stats_provider.dart';
import '../study_duration_provider.dart';
import '../../services/app_logger.dart';
import '../audio_engine/audio_engine_provider.dart';
import '../audio_engine/foreground_audio_engine_provider.dart';
import '../learning_progress_provider.dart';
import '../retell_prefs_provider.dart';
import '../../models/stage_settings_overrides.dart';
import '../../utils/playback_speed_default.dart';
import '../speech/speech_recording_controller.dart';
import '../retell_recording_controller_provider.dart';
import '../listening_practice/listening_practice_provider.dart';
import '../listening_practice/bookmark_manager.dart';
import '../media_engine/media_engine_provider.dart';
import '../media_engine/media_sense_group_range_playback.dart';
import 'blind_listen_player_provider.dart';
import 'paragraph_playback_driver.dart';
import 'intensive_listen_player_provider.dart';
import 'intensive_listen_playback_driver.dart';
import 'retell_player_provider.dart';
import 'review_difficult_practice_provider.dart';
import 'sentence_playback_engine.dart';

part 'learning_session_provider.g.dart';

/// 学习模式类型
enum LearningMode {
  /// 全文盲听
  blindListen,

  /// 逐句精听
  intensiveListen,

  /// 难句跟读
  listenAndRepeat,

  /// 段落复述
  retell,

  /// 复习难句补练
  reviewDifficultPractice,
}

/// 当前学习会话实际占用的播放链路。
enum LearningPlaybackChain { audio, media }

/// 学习会话状态
class LearningSessionState {
  /// 当前学习模式（null = 自由收听）
  final LearningMode? learningMode;

  /// 本遍盲听是否已播放完成
  final bool blindListenCompleted;

  /// 当前盲听遍数（从 1 开始，表示正在听第几遍）
  final int blindListenPassCount;

  /// 当前学习的音频 ID
  final String? audioItemId;

  /// 进入学习模式前的用户播放设置（退出时恢复）
  final PlaybackSettings? savedSettings;

  /// 是否为自由练习模式（已完成步骤的单独练习，不计入遍数、不弹完成对话框）
  final bool isFreePlay;

  /// 目标盲听遍数（暂时硬编码，后续由 AI 决定）
  final int targetBlindListenPasses;

  /// 跟读难句列表（enterListenAndRepeatMode 准备，Screen 读取初始化 ListenAndRepeatController）
  final List<Sentence>? shadowingSentences;

  /// 跟读起始句子索引
  final int shadowingStartIndex;

  /// 跟读目标遍数
  final int shadowingTargetPlayCount;

  /// 自由练习时用户点击的目标大阶段（用于"补做跳过的复述"语义）。
  ///
  /// 仅 [isFreePlay] == true 且从过去阶段的复述卡片进入时设置。
  /// 自由练习完成时若该 (stage, subStage) 还未在 completedKeys 内，则写入
  /// stage_completions（[LearningProgressNotifier.recordCompletionIfNew]）
  /// 让 UI 把"跳过"卡切到 ✅。
  final LearningStage? catchUpStage;

  /// 自由练习时用户点击的目标子步骤（与 [catchUpStage] 配套）。
  final SubStageType? catchUpSubStage;
  final LearningPlaybackChain playbackChain;

  const LearningSessionState({
    this.learningMode,
    this.blindListenCompleted = false,
    this.blindListenPassCount = 0,
    this.audioItemId,
    this.savedSettings,
    this.isFreePlay = false,
    this.targetBlindListenPasses = 1,
    this.shadowingSentences,
    this.shadowingStartIndex = 0,
    this.shadowingTargetPlayCount = 3,
    this.catchUpStage,
    this.catchUpSubStage,
    this.playbackChain = LearningPlaybackChain.audio,
  });

  /// 是否处于学习模式中
  bool get isInLearningMode => learningMode != null;

  /// 是否还有剩余遍数未完成
  ///
  /// `blindListenPassCount` 表示"正在听第几遍"，完成后才 +1，
  /// 所以用 `<` 比较：正在听的这一遍还没达到目标时返回 true。
  bool get hasRemainingPasses => blindListenPassCount < targetBlindListenPasses;

  LearningSessionState copyWith({
    LearningMode? learningMode,
    bool? blindListenCompleted,
    int? blindListenPassCount,
    String? audioItemId,
    PlaybackSettings? savedSettings,
    bool? isFreePlay,
    int? targetBlindListenPasses,
    List<Sentence>? shadowingSentences,
    int? shadowingStartIndex,
    int? shadowingTargetPlayCount,
    LearningStage? catchUpStage,
    SubStageType? catchUpSubStage,
    LearningPlaybackChain? playbackChain,
    bool clearLearningMode = false,
    bool clearSavedSettings = false,
    bool clearAudioItemId = false,
    bool clearShadowingSentences = false,
    bool clearCatchUp = false,
  }) {
    return LearningSessionState(
      learningMode: clearLearningMode
          ? null
          : (learningMode ?? this.learningMode),
      blindListenCompleted: blindListenCompleted ?? this.blindListenCompleted,
      blindListenPassCount: blindListenPassCount ?? this.blindListenPassCount,
      audioItemId: clearAudioItemId ? null : (audioItemId ?? this.audioItemId),
      savedSettings: clearSavedSettings
          ? null
          : (savedSettings ?? this.savedSettings),
      isFreePlay: isFreePlay ?? this.isFreePlay,
      targetBlindListenPasses:
          targetBlindListenPasses ?? this.targetBlindListenPasses,
      shadowingSentences: clearShadowingSentences
          ? null
          : (shadowingSentences ?? this.shadowingSentences),
      shadowingStartIndex: shadowingStartIndex ?? this.shadowingStartIndex,
      shadowingTargetPlayCount:
          shadowingTargetPlayCount ?? this.shadowingTargetPlayCount,
      catchUpStage: clearCatchUp ? null : (catchUpStage ?? this.catchUpStage),
      catchUpSubStage: clearCatchUp
          ? null
          : (catchUpSubStage ?? this.catchUpSubStage),
      playbackChain: playbackChain ?? this.playbackChain,
    );
  }
}

/// 学习会话 Provider
///
/// 作为播放器之上的学习流程控制层。
/// 进入盲听模式时暂停 LP 监听、初始化 BlindListenPlayer，
/// 退出时停止盲听播放、恢复 LP 监听。
@Riverpod(keepAlive: true)
class LearningSession extends _$LearningSession {
  StreamSubscription<ja.PlayerState>? _playerStateSub;

  /// 视频盲听进入流程 generation；取消、重试或退出会使旧结果失效。
  int _mediaBlindListenEntryGeneration = 0;

  /// 视频精听进入流程 generation；退出或重试会使旧异步结果失效。
  int _mediaIntensiveEntryGeneration = 0;

  /// 视频复述进入流程 generation；取消、重试或退出会使旧异步结果失效。
  int _mediaRetellEntryGeneration = 0;

  /// 视频难句补练进入流程 generation；取消、重试或退出会使旧结果失效。
  int _mediaReviewDifficultEntryGeneration = 0;

  /// 学习计时器，进入学习模式时启动，退出时停止
  final Stopwatch _studyStopwatch = Stopwatch();

  /// 周期保存定时器（每 _maxSessionSeconds 自动保存并重置计时器）
  Timer? _periodicSaveTimer;

  /// 学习计时器是否正在运行（仅用于测试验证）
  @visibleForTesting
  bool get isStudyTimerRunning => _studyStopwatch.isRunning;

  /// App 生命周期监听器，用于在后台暂停计时
  late AppLifecycleListener _lifecycleListener;

  /// 学习时长存储服务
  late StudyTimeService _studyTimeService;

  @override
  LearningSessionState build() {
    _studyTimeService = ref.read(studyTimeServiceProvider);
    _lifecycleListener = AppLifecycleListener(
      onStateChange: _onAppLifecycleStateChanged,
    );
    ref.onDispose(() {
      _playerStateSub?.cancel();
      _periodicSaveTimer?.cancel();
      _saveStudyTime();
      _lifecycleListener.dispose();
    });
    return const LearningSessionState();
  }

  /// App 生命周期变化时暂停/恢复计时
  ///
  /// - 进入后台：暂停所有计时器 + 取消周期保存（用户不在看，不计入学习时长）
  /// - 回到前台：恢复计时 + 重新调度周期保存
  void _onAppLifecycleStateChanged(AppLifecycleState lifecycleState) {
    if (lifecycleState == AppLifecycleState.paused ||
        lifecycleState == AppLifecycleState.hidden) {
      _studyStopwatch.stop();
      _stopPeriodicSaveTimer();
    } else if (lifecycleState == AppLifecycleState.resumed) {
      if (state.isInLearningMode && !_studyStopwatch.isRunning) {
        _studyStopwatch.start();
        _schedulePeriodicSave();
      }
    }
  }

  /// 单次会话最大计入时长（防止用户睡着等异常场景）
  static const _maxSessionSeconds = 5 * 60; // 5 分钟

  /// 当前学习模式对应的 StudyStage（用于阶段明细双写）
  StudyStage? get _currentStage => switch (state.learningMode) {
    LearningMode.blindListen => StudyStage.blindListen,
    LearningMode.intensiveListen => StudyStage.intensiveListen,
    LearningMode.listenAndRepeat => StudyStage.listenAndRepeat,
    LearningMode.retell => StudyStage.retell,
    LearningMode.reviewDifficultPractice => StudyStage.reviewDifficultPractice,
    null => null,
  };

  /// 停止计时并保存已记录的学习时长
  ///
  /// 尚未迁移的旧学习任务通过事件记录器写入 input/output，无需周期保存。
  Future<void> _saveStudyTime() async {
    if (_isSaving) return;
    _isSaving = true;
    try {
      if (!_studyStopwatch.isRunning &&
          _studyStopwatch.elapsed == Duration.zero) {
        return;
      }
      _studyStopwatch.stop();
      final seconds = _studyStopwatch.elapsed.inSeconds.clamp(
        0,
        _maxSessionSeconds,
      );
      _studyStopwatch.reset();
      if (seconds > 0) {
        await _studyTimeService.addStudyTime(seconds, stage: _currentStage);
      }
    } finally {
      _isSaving = false;
    }
  }

  /// 是否正在执行保存（防止 timer 回调与 exit 竞态）
  bool _isSaving = false;

  /// 启动学习计时（含周期保存定时器）
  void _startStudyTimer() {
    _studyStopwatch.reset();
    _studyStopwatch.start();
    _schedulePeriodicSave();
  }

  /// 调度下一次周期保存（one-shot Timer，避免 periodic 的 async 竞态）
  void _schedulePeriodicSave() {
    _periodicSaveTimer?.cancel();
    _periodicSaveTimer = Timer(
      const Duration(seconds: _maxSessionSeconds),
      () async {
        if (_isSaving || !state.isInLearningMode) return;
        await _saveStudyTime();
        // 保存后如果仍在学习模式，重新启动计时并调度下一次
        if (state.isInLearningMode) {
          _studyStopwatch.start();
          _schedulePeriodicSave();
        }
      },
    );
  }

  /// 上报 session_start 事件
  void _trackSessionStart() {
    final analytics = ref.read(analyticsServiceProvider);
    analytics.track(Events.learningStart, {
      ...ref.audioEventParams(state.audioItemId),
      if (state.learningMode != null)
        EventParams.stage: state.learningMode!.name,
      EventParams.isFreePractice: state.isFreePlay ? 1 : 0,
    });
  }

  /// 上报 session_end 事件
  void _trackSessionEnd({int? durationMs}) {
    final analytics = ref.read(analyticsServiceProvider);
    analytics.track(Events.learningEnd, {
      ...ref.audioEventParams(state.audioItemId),
      if (state.learningMode != null)
        EventParams.stage: state.learningMode!.name,
      EventParams.durationMs: durationMs ?? _studyStopwatch.elapsedMilliseconds,
      EventParams.isFreePractice: state.isFreePlay ? 1 : 0,
    });
  }

  /// 停止周期保存定时器
  void _stopPeriodicSaveTimer() {
    _periodicSaveTimer?.cancel();
    _periodicSaveTimer = null;
  }

  /// 暂停学习计时（步骤完成后调用，防止完成弹窗期间白跑时长）
  void pauseStudyTimer() {
    _studyStopwatch.stop();
    _stopPeriodicSaveTimer();
  }

  /// 立即持久化输出词数（每完成一次跟读/复述调用，不丢数据）
  ///
  /// 学习期间 study tab 不可见，无需实时刷新统计 UI。
  /// 退出学习模式时 `exitLearningMode()` 会统一刷新。
  void addOutputWords(int count) {
    if (count > 0) {
      _studyTimeService.addOutputWords(count);
    }
  }

  /// 测试环境可能未注入数据库，此时跳过词形统计即可。
  LearnedVocabularyTracker? _readLearnedVocabularyTracker() {
    try {
      return ref.read(learnedVocabularyTrackerProvider);
    } on Exception catch (e) {
      AppLogger.log('Session', '⚠ vocabTracker 不可用（测试环境？）: $e');
      return null;
    }
  }

  /// 尽量在退出时落掉待写入的词形统计。
  Future<void> _flushLearnedVocabulary() async {
    final tracker = _readLearnedVocabularyTracker();
    if (tracker == null) return;
    await tracker.flush();
  }

  /// 设置自由练习"补做"目标 (stage, subStage)。
  ///
  /// 自由练习完成时，若该 (stage, subStage) 之前被跳过，则写入 stage_completions
  /// 并回收跳过状态（见 [LearningProgressNotifier.recordCompletionIfNew]）。
  /// 复述走 [enterRetellMode] 的 catchUp 参数；其余任务（盲听/精听/跟读/难句补练）
  /// 由各自由练习入口在进入后调用本方法显式设置，传 null 清除。
  void setCatchUp(LearningStage? stage, SubStageType? subStage) {
    state = state.copyWith(
      catchUpStage: stage,
      catchUpSubStage: subStage,
      clearCatchUp: stage == null,
    );
  }

  /// 若当前会话设置了自由练习"补做"目标，则将其记为完成。
  ///
  /// 幂等：已完成则 no-op；之前被跳过则回收为完成（清除跳过标记）。
  /// 由各自由练习播放器在完成退出时调用。
  Future<void> recordCatchUpCompletionIfAny(String audioItemId) async {
    final stage = state.catchUpStage;
    final subStage = state.catchUpSubStage;
    if (stage == null || subStage == null) return;
    await ref
        .read(learningProgressNotifierProvider.notifier)
        .recordCompletionIfNew(audioItemId, stage, subStage);
  }

  /// 进入全文盲听模式
  ///
  /// 1. 保存当前用户播放设置
  /// 2. 暂停 LP 的 stream 监听（避免 LP 干扰盲听播放）
  /// 3. 初始化 BlindListenPlayer
  /// 4. 有段落时使用段落分段模式，无段落时使用极简全文播放模式
  ///
  /// [paragraphs] 段落列表
  /// [settings] 盲听设置（段间停顿、重复次数等）
  Future<void> enterBlindListenMode(
    String audioItemId, {
    bool isFreePlay = false,
    required List<List<Sentence>> paragraphs,
    BlindListenSettings? settings,
    LearningStage? stage,
  }) async {
    final practice = ref.read(listeningPracticeProvider.notifier);
    final currentSettings = ref.read(listeningPracticeProvider).settings;

    // 从数据库读取已完成遍数 + 断点段落索引
    final progressNotifier = ref.read(
      learningProgressNotifierProvider.notifier,
    );
    final progress = await progressNotifier.getLatestOrEnsureProgress(
      audioItemId,
    );
    final dbPassCount = progress.blindListenPassCount;

    // 读取断点续学的全局句子 index + 校验过期时间
    int? startSentenceIndex;
    if (isFreePlay && _isBreakpointValid(progress.freePlayBreakpointSavedAt)) {
      startSentenceIndex = progress.freePlayBlindListenSentenceIndex;
    } else if (!isFreePlay &&
        _isBreakpointValid(progress.newLearningBreakpointSavedAt)) {
      startSentenceIndex = progress.blindListenSentenceIndex;
    }

    // 全局句子 index → (段索引, 段内本地句索引)
    var startParagraphIndex = 0;
    var startSentenceLocalIndex = 0;
    if (startSentenceIndex != null) {
      for (var i = 0; i < paragraphs.length; i++) {
        final local = paragraphs[i].indexWhere(
          (s) => s.index == startSentenceIndex,
        );
        if (local >= 0) {
          startParagraphIndex = i;
          startSentenceLocalIndex = local;
          break;
        }
      }
    }

    state = state.copyWith(
      learningMode: LearningMode.blindListen,
      blindListenCompleted: false,
      blindListenPassCount: dbPassCount + 1,
      audioItemId: audioItemId,
      savedSettings: currentSettings,
      isFreePlay: isFreePlay,
    );

    practice.suspendListeners();
    await _ensureAudioLoaded(audioItemId);

    final allSentences = paragraphs.expand((p) => p).toList();
    _logEnterMode(
      'enterBlindListenMode',
      audioItemId,
      sentenceCount: allSentences.length,
      firstSentenceText: allSentences.isNotEmpty
          ? allSentences.first.text
          : null,
    );

    final blindPlayer = ref.read(blindListenPlayerProvider.notifier);
    await blindPlayer.initializeParagraphs(
      paragraphs,
      settings ?? const BlindListenSettings(),
      startParagraphIndex: startParagraphIndex,
      startSentenceLocalIndex: startSentenceLocalIndex,
      // 按槽位记忆;自由练习与按计划共用同一轮次槽位(stage 由入口传入)。
      settingsSlot: stageSlotKey(StageSettingsSlots.blindListen, stage),
    );
    _trackSessionStart();
  }

  /// 进入视频盲听：仅占用 MediaEngine，不触碰既有音频盲听加载链路。
  Future<MediaLoadResult> enterMediaBlindListenMode(
    AudioItem mediaItem, {
    required List<List<Sentence>> paragraphs,
    required BlindListenSettings settings,
    LearningStage? stage,
    bool isFreePlay = false,
  }) async {
    final generation = ++_mediaBlindListenEntryGeneration;
    bool isCurrentGeneration() =>
        generation == _mediaBlindListenEntryGeneration;
    final progress = await ref
        .read(learningProgressNotifierProvider.notifier)
        .getLatestOrEnsureProgress(mediaItem.id);
    if (!isCurrentGeneration()) return MediaLoadResult.cancelled;
    final bookmarkedIndices = await BookmarkManager.loadBookmarks(
      mediaItem.id,
      dao: ref.read(bookmarkDaoProvider),
    );
    if (!isCurrentGeneration()) return MediaLoadResult.cancelled;
    final sessionParagraphs = BookmarkManager.createParagraphBookmarkSnapshot(
      paragraphs,
      bookmarkedIndices,
    );
    await ref.read(audioEngineProvider.notifier).pause();
    if (!isCurrentGeneration()) return MediaLoadResult.cancelled;
    final mediaEngine = ref.read(mediaEngineProvider.notifier);
    // MediaEngine 是跨学习入口共享的。每次进入先取得独立会话所有权，旧请求
    // 迟到时只能释放仍归自己所有的链路，不能关闭后一次进入已加载的媒体。
    final mediaSessionId = mediaEngine.newSession();
    bool ownsMediaSession() =>
        isCurrentGeneration() && mediaEngine.isActiveSession(mediaSessionId);
    final duration = await mediaEngine.loadMedia(
      mediaItem,
      settings.playbackSpeed,
    );
    if (!ownsMediaSession()) {
      return MediaLoadResult.cancelled;
    }
    if (duration == null) {
      await mediaEngine.releaseFromScreen();
      return MediaLoadResult.failure;
    }
    await mediaEngine.setSubtitleTrackData(null);
    if (!ownsMediaSession()) {
      return MediaLoadResult.cancelled;
    }

    int? startSentenceIndex;
    if (isFreePlay && _isBreakpointValid(progress.freePlayBreakpointSavedAt)) {
      startSentenceIndex = progress.freePlayBlindListenSentenceIndex;
    } else if (!isFreePlay &&
        _isBreakpointValid(progress.newLearningBreakpointSavedAt)) {
      startSentenceIndex = progress.blindListenSentenceIndex;
    }
    var startParagraphIndex = 0;
    var startSentenceLocalIndex = 0;
    if (startSentenceIndex != null) {
      for (
        var paragraphIndex = 0;
        paragraphIndex < sessionParagraphs.length;
        paragraphIndex++
      ) {
        final localIndex = sessionParagraphs[paragraphIndex].indexWhere(
          (sentence) => sentence.index == startSentenceIndex,
        );
        if (localIndex >= 0) {
          startParagraphIndex = paragraphIndex;
          startSentenceLocalIndex = localIndex;
          break;
        }
      }
    }

    state = state.copyWith(
      learningMode: LearningMode.blindListen,
      blindListenCompleted: false,
      blindListenPassCount: progress.blindListenPassCount + 1,
      audioItemId: mediaItem.id,
      isFreePlay: isFreePlay,
      playbackChain: LearningPlaybackChain.media,
      clearSavedSettings: true,
    );
    await ref
        .read(blindListenPlayerProvider.notifier)
        .initializeParagraphs(
          sessionParagraphs,
          settings,
          startParagraphIndex: startParagraphIndex,
          startSentenceLocalIndex: startSentenceLocalIndex,
          settingsSlot: stageSlotKey(StageSettingsSlots.blindListen, stage),
          playbackDriver: MediaParagraphPlaybackDriver(mediaEngine),
        );
    _trackSessionStart();
    return MediaLoadResult.ready;
  }

  /// 取消视频盲听进入或结束已准备好的媒体会话。
  Future<void> cancelMediaBlindListenEntry() async {
    _mediaBlindListenEntryGeneration += 1;
    if (state.learningMode == LearningMode.blindListen &&
        state.playbackChain == LearningPlaybackChain.media) {
      await exitLearningMode();
    } else {
      await ref.read(mediaEngineProvider.notifier).releaseFromScreen();
    }
  }

  /// 再听一遍：重置到第一段，递增遍数
  Future<void> replayBlindListen() async {
    state = state.copyWith(
      blindListenCompleted: false,
      blindListenPassCount: state.blindListenPassCount + 1,
    );

    final blindPlayer = ref.read(blindListenPlayerProvider.notifier);
    await blindPlayer.restart();
  }

  /// 进入逐句精听模式
  ///
  /// 1. 保存当前用户播放设置
  /// 2. 暂停 LP 的 stream 监听
  /// 3. 初始化 IntensiveListenPlayer，从数据库读取断点句子索引
  Future<void> enterIntensiveListenMode(
    String audioItemId,
    List<Sentence> sentences, {
    bool isFreePlay = false,
    IntensiveListenSettings settings = const IntensiveListenSettings(),
    String? settingsSlot,
  }) async {
    final practice = ref.read(listeningPracticeProvider.notifier);
    final currentSettings = ref.read(listeningPracticeProvider).settings;
    final progressNotifier = ref.read(
      learningProgressNotifierProvider.notifier,
    );

    // 读取断点续学索引：各自读取独立字段 + 校验过期时间
    final progress = await progressNotifier.getLatestOrEnsureProgress(
      audioItemId,
    );
    int startIndex = 0;
    if (isFreePlay && _isBreakpointValid(progress.freePlayBreakpointSavedAt)) {
      startIndex = progress.freePlayIntensiveListenSentenceIndex ?? 0;
    } else if (!isFreePlay &&
        _isBreakpointValid(progress.newLearningBreakpointSavedAt)) {
      startIndex = progress.intensiveListenSentenceIndex ?? 0;
    }

    state = state.copyWith(
      learningMode: LearningMode.intensiveListen,
      blindListenCompleted: false,
      audioItemId: audioItemId,
      savedSettings: currentSettings,
      isFreePlay: isFreePlay,
    );

    // 暂停 LP 的 stream 监听
    practice.suspendListeners();
    await _ensureAudioLoaded(audioItemId);

    _logEnterMode(
      'enterIntensiveListenMode',
      audioItemId,
      sentenceCount: sentences.length,
      firstSentenceText: sentences.isNotEmpty ? sentences.first.text : null,
    );

    // 初始化精听播放器([settings] 已由调用方从用户偏好 resolve 出,含默认+记忆)。
    final intensivePlayer = ref.read(intensiveListenPlayerProvider.notifier);
    await intensivePlayer.initialize(
      sentences,
      startIndex: startIndex,
      settings: settings,
      settingsSlot: settingsSlot,
    );
    _trackSessionStart();
  }

  /// 进入视频逐句精听模式。
  ///
  /// 字幕由调用方直接从数据库提供，媒体只加载到 MediaEngine；不会把视频送入
  /// listeningPracticeProvider，也不会改写现有音频逐句精听的加载链路。
  Future<MediaLoadResult> enterMediaIntensiveListenMode(
    AudioItem mediaItem,
    List<Sentence> sentences, {
    bool isFreePlay = false,
    IntensiveListenSettings settings = const IntensiveListenSettings(),
    String? settingsSlot,
  }) async {
    final generation = ++_mediaIntensiveEntryGeneration;
    bool isCurrentGeneration() => generation == _mediaIntensiveEntryGeneration;

    final progressNotifier = ref.read(
      learningProgressNotifierProvider.notifier,
    );
    final progress = await progressNotifier.getLatestOrEnsureProgress(
      mediaItem.id,
    );
    if (!isCurrentGeneration()) return MediaLoadResult.cancelled;
    final bookmarkedIndices = await BookmarkManager.loadBookmarks(
      mediaItem.id,
      dao: ref.read(bookmarkDaoProvider),
    );
    if (!isCurrentGeneration()) return MediaLoadResult.cancelled;
    final sessionSentences = BookmarkManager.createSentenceBookmarkSnapshot(
      sentences,
      bookmarkedIndices,
    );

    var startIndex = 0;
    if (isFreePlay && _isBreakpointValid(progress.freePlayBreakpointSavedAt)) {
      startIndex = progress.freePlayIntensiveListenSentenceIndex ?? 0;
    } else if (!isFreePlay &&
        _isBreakpointValid(progress.newLearningBreakpointSavedAt)) {
      startIndex = progress.intensiveListenSentenceIndex ?? 0;
    }

    // 两条媒体会话不能同时占用系统控制位；这里只暂停旧音频，不加载或改写它。
    await ref.read(audioEngineProvider.notifier).pause();
    if (!isCurrentGeneration()) return MediaLoadResult.cancelled;

    final mediaEngine = ref.read(mediaEngineProvider.notifier);
    final duration = await mediaEngine.loadMedia(
      mediaItem,
      settings.playbackSpeed,
    );
    if (!isCurrentGeneration()) {
      await mediaEngine.releaseFromScreen();
      return MediaLoadResult.cancelled;
    }
    if (duration == null) {
      AppLogger.log(
        'Session',
        '✗ enterMediaIntensiveListenMode load failed: ${mediaItem.id}',
      );
      // loadMedia 会先创建 media_kit 链路；失败后立即释放，避免重试时残留
      // 未激活的 native Player。该清理只针对独立视频链路。
      await mediaEngine.releaseFromScreen();
      return MediaLoadResult.failure;
    }

    // 学习页视频字幕默认关闭；共享画面宿主在用户点 CC 后再按需读取 SRT。
    await mediaEngine.setSubtitleTrackData(null);
    if (!isCurrentGeneration()) {
      await mediaEngine.releaseFromScreen();
      return MediaLoadResult.cancelled;
    }

    state = state.copyWith(
      learningMode: LearningMode.intensiveListen,
      audioItemId: mediaItem.id,
      isFreePlay: isFreePlay,
      playbackChain: LearningPlaybackChain.media,
      clearSavedSettings: true,
    );

    final intensivePlayer = ref.read(intensiveListenPlayerProvider.notifier);
    await intensivePlayer.initialize(
      sessionSentences,
      startIndex: startIndex,
      settings: settings,
      settingsSlot: settingsSlot,
      playbackDriver: MediaIntensiveListenPlaybackDriver(mediaEngine),
      senseGroupRangePlayback: MediaSenseGroupRangePlayback(
        engine: mediaEngine,
        playbackSpeed: () =>
            ref.read(intensiveListenPlayerProvider).settings.playbackSpeed,
      ),
      usesMediaEngine: true,
    );
    if (!isCurrentGeneration()) {
      await exitLearningMode();
      return MediaLoadResult.cancelled;
    }

    _trackSessionStart();
    AppLogger.log(
      'Session',
      '🎬 enterMediaIntensiveListenMode: targetId=${mediaItem.id}, '
          'sentences=${sentences.length}',
    );
    return MediaLoadResult.ready;
  }

  /// 取消当前视频精听进入流程。
  ///
  /// 加载尚未完成时只使 generation 失效，由原协程在下一异步边界释放媒体；若
  /// 会话已完成写入，则复用正常退出路径立即释放播放器和学习状态。
  Future<void> cancelMediaIntensiveListenEntry() async {
    _mediaIntensiveEntryGeneration += 1;
    if (state.learningMode == LearningMode.intensiveListen &&
        state.playbackChain == LearningPlaybackChain.media) {
      await exitLearningMode();
    }
  }

  // TODO: 跟读页已迁移到 ListenAndRepeatController.initialize()，此方法不再被调用。
  // 等所有 enterXxxMode 都迁移到各自 Controller 后，删除整个 LearningSessionProvider。
  /// 进入难句跟读模式（已废弃，保留供参考）
  ///
  /// 1. 保存当前用户播放设置
  /// 2. 暂停 LP 的 stream 监听
  /// 3. 从 BookmarkDao 读取难句索引集 → 过滤句子
  /// 4. 从 LearningProgress 读取断点 shadowingSentenceIndex
  /// 5. 根据 difficulty 计算 targetPlayCount
  /// 6. 初始化 ListenAndRepeatPlayer
  Future<void> enterListenAndRepeatMode(
    String audioItemId,
    List<Sentence> allSentences, {
    bool isFreePlay = false,
    double playbackSpeed = 1.0,
  }) async {
    _startStudyTimer();
    final practice = ref.read(listeningPracticeProvider.notifier);
    final currentSettings = ref.read(listeningPracticeProvider).settings;

    // 从数据库读取难句索引
    final bookmarkDao = ref.read(bookmarkDaoProvider);
    final bookmarkedIndices = await bookmarkDao.getBookmarkedIndices(
      audioItemId,
    );

    // 过滤出难句列表
    final difficultSentences = allSentences
        .where((s) => bookmarkedIndices.contains(s.index))
        .toList();

    // 跟读断点与难度都需要优先使用持久化的最新值，避免只吃到陈旧内存态。
    final progress = await ref
        .read(learningProgressNotifierProvider.notifier)
        .getLatestOrEnsureProgress(audioItemId);
    int startIndex = 0;
    if (isFreePlay && _isBreakpointValid(progress.freePlayBreakpointSavedAt)) {
      startIndex = progress.freePlayShadowingSentenceIndex ?? 0;
    } else if (!isFreePlay &&
        _isBreakpointValid(progress.newLearningBreakpointSavedAt)) {
      startIndex = progress.shadowingSentenceIndex ?? 0;
    }
    final difficultyValue = progress.difficulty.value;
    final targetPlayCount = targetPlayCountForDifficulty(difficultyValue);

    state = state.copyWith(
      learningMode: LearningMode.listenAndRepeat,
      blindListenCompleted: false,
      audioItemId: audioItemId,
      savedSettings: currentSettings,
      isFreePlay: isFreePlay,
    );

    // 暂停 LP 的 stream 监听
    practice.suspendListeners();
    // 跟读为录音类任务，用前台引擎（此 enter 方法已废弃，跟读改走
    // ListenAndRepeatController.initialize；保留以对齐前台引擎语义）。
    await _ensureAudioLoaded(audioItemId, foreground: true);

    _logEnterMode(
      'enterListenAndRepeatMode',
      audioItemId,
      sentenceCount: difficultSentences.length,
      firstSentenceText: difficultSentences.isNotEmpty
          ? difficultSentences.first.text
          : null,
    );

    // 存储难句数据供 Screen 初始化 ListenAndRepeatController
    state = state.copyWith(
      shadowingSentences: difficultSentences,
      shadowingStartIndex: startIndex,
      shadowingTargetPlayCount: targetPlayCount,
    );
    _trackSessionStart();
  }

  /// 进入段落复述模式
  ///
  /// 1. 保存当前用户播放设置
  /// 2. 暂停 LP 的 stream 监听
  /// 3. 初始化 RetellPlayer（段落分组 + 按音频难度自动算可见词比例 + 断点索引）
  ///
  /// 可见词比例：
  /// - [overrideKeywordRatio] 非空时使用（用户在 briefing 弹窗中手动选了某档）
  /// - 否则按 `progress.difficulty` + 阶段映射自动算
  Future<void> enterRetellMode(
    String audioItemId,
    List<List<Sentence>> paragraphs, {
    bool isFreePlay = false,
    LearningStage? catchUpStage,
    SubStageType? catchUpSubStage,
  }) async {
    final practice = ref.read(listeningPracticeProvider.notifier);
    final currentSettings = ref.read(listeningPracticeProvider).settings;

    // 各自读取独立字段 + 校验过期时间
    final progress = await ref
        .read(learningProgressNotifierProvider.notifier)
        .getLatestOrEnsureProgress(audioItemId);
    final startSentenceIndex = _retellStartSentenceIndex(progress, isFreePlay);

    state = state.copyWith(
      learningMode: LearningMode.retell,
      blindListenCompleted: false,
      audioItemId: audioItemId,
      savedSettings: currentSettings,
      isFreePlay: isFreePlay,
      catchUpStage: catchUpStage,
      catchUpSubStage: catchUpSubStage,
      clearCatchUp: catchUpStage == null,
      playbackChain: LearningPlaybackChain.audio,
    );

    // 暂停 LP 的 stream 监听
    practice.suspendListeners();
    // 录音类任务（复述）用前台引擎播放、不上锁屏：① 停掉媒体引擎，清除上一个媒体任务
    // （盲听/精听）残留在锁屏/通知栏的 now-playing 卡片（非idle→idle 跳变 → stopService）；
    // ② 音频加载到**前台引擎**（foreground:true），物理上不碰系统媒体会话。见 ADR-7。
    await ref.read(audioEngineProvider.notifier).stop();
    await _ensureAudioLoaded(audioItemId, foreground: true);

    final retellSentences = paragraphs.expand((p) => p).toList();
    _logEnterMode(
      'enterRetellMode',
      audioItemId,
      sentenceCount: retellSentences.length,
      firstSentenceText: retellSentences.isNotEmpty
          ? retellSentences.first.text
          : null,
    );

    // 复述按 子阶段×轮次 记忆(轮次取本次会话的有效阶段);自由练习与按计划共用同槽位。
    // 补练场景按 catchUpStage 算曲线(补练 firstLearn 走 firstLearn)。briefing 选择已由
    // 屏幕落入偏好,这里按动态默认(速度/可见词比例)resolve 出完整设置(单一真相源)。
    await _initializeRetellPlayer(
      paragraphs,
      progress: progress,
      startSentenceIndex: startSentenceIndex,
      effectiveStage: catchUpStage ?? progress.currentStage,
    );
    _trackSessionStart();
  }

  /// 进入视频复述：媒体加载与音频复述完全分离，共用同一复述状态机。
  Future<MediaLoadResult> enterMediaRetellMode(
    AudioItem mediaItem,
    List<List<Sentence>> paragraphs, {
    bool isFreePlay = false,
    LearningStage? catchUpStage,
    SubStageType? catchUpSubStage,
  }) async {
    final generation = ++_mediaRetellEntryGeneration;
    bool isCurrentGeneration() => generation == _mediaRetellEntryGeneration;

    final progress = await ref
        .read(learningProgressNotifierProvider.notifier)
        .getLatestOrEnsureProgress(mediaItem.id);
    if (!isCurrentGeneration()) return MediaLoadResult.cancelled;
    final bookmarkedIndices = await BookmarkManager.loadBookmarks(
      mediaItem.id,
      dao: ref.read(bookmarkDaoProvider),
    );
    if (!isCurrentGeneration()) return MediaLoadResult.cancelled;
    final sessionParagraphs = BookmarkManager.createParagraphBookmarkSnapshot(
      paragraphs,
      bookmarkedIndices,
    );

    final effectiveStage = catchUpStage ?? progress.currentStage;
    final settings = _resolveRetellSettings(progress, effectiveStage).settings;
    await ref.read(audioEngineProvider.notifier).pause();
    if (!isCurrentGeneration()) return MediaLoadResult.cancelled;

    final mediaEngine = ref.read(mediaEngineProvider.notifier);
    final duration = await mediaEngine.loadMedia(
      mediaItem,
      settings.playbackSpeed,
    );
    if (!isCurrentGeneration()) {
      await mediaEngine.releaseFromScreen();
      return MediaLoadResult.cancelled;
    }
    if (duration == null) {
      AppLogger.log(
        'Session',
        '✗ enterMediaRetellMode load failed: ${mediaItem.id}',
      );
      await mediaEngine.releaseFromScreen();
      return MediaLoadResult.failure;
    }

    await mediaEngine.setSubtitleTrackData(null);
    if (!isCurrentGeneration()) {
      await mediaEngine.releaseFromScreen();
      return MediaLoadResult.cancelled;
    }

    state = state.copyWith(
      learningMode: LearningMode.retell,
      blindListenCompleted: false,
      audioItemId: mediaItem.id,
      isFreePlay: isFreePlay,
      catchUpStage: catchUpStage,
      catchUpSubStage: catchUpSubStage,
      clearCatchUp: catchUpStage == null,
      playbackChain: LearningPlaybackChain.media,
      clearSavedSettings: true,
    );

    final retellSentences = sessionParagraphs
        .expand((paragraph) => paragraph)
        .toList();
    _logEnterMode(
      'enterMediaRetellMode',
      mediaItem.id,
      sentenceCount: retellSentences.length,
      firstSentenceText: retellSentences.isNotEmpty
          ? retellSentences.first.text
          : null,
    );
    await _initializeRetellPlayer(
      sessionParagraphs,
      progress: progress,
      startSentenceIndex: _retellStartSentenceIndex(progress, isFreePlay),
      effectiveStage: effectiveStage,
      playbackDriver: MediaParagraphPlaybackDriver(mediaEngine),
    );
    if (!isCurrentGeneration()) {
      await exitLearningMode();
      return MediaLoadResult.cancelled;
    }

    _trackSessionStart();
    AppLogger.log(
      'Session',
      '🎬 enterMediaRetellMode: targetId=${mediaItem.id}, '
          'paragraphs=${paragraphs.length}',
    );
    return MediaLoadResult.ready;
  }

  /// 取消尚未完成的视频复述进入任务，或退出已建立的媒体复述会话。
  Future<void> cancelMediaRetellEntry() async {
    _mediaRetellEntryGeneration += 1;
    if (state.learningMode == LearningMode.retell &&
        state.playbackChain == LearningPlaybackChain.media) {
      await exitLearningMode();
    }
  }

  int? _retellStartSentenceIndex(LearningProgress progress, bool isFreePlay) {
    if (isFreePlay && _isBreakpointValid(progress.freePlayBreakpointSavedAt)) {
      return progress.freePlayRetellSentenceIndex;
    }
    if (!isFreePlay &&
        _isBreakpointValid(progress.newLearningBreakpointSavedAt)) {
      return progress.retellSentenceIndex;
    }
    return null;
  }

  ({String slot, RetellSettings settings}) _resolveRetellSettings(
    LearningProgress progress,
    LearningStage effectiveStage,
  ) {
    final slot = stageSlotKey(StageSettingsSlots.retell, effectiveStage);
    final settings = ref
        .read(retellPrefsProvider.notifier)
        .resolve(
          slot,
          smartSpeed: defaultPlaybackSpeedFor(
            progress.difficulty,
            effectiveStage,
          ),
          smartRatio: KeywordRatio.forDifficultyAndStage(
            progress.difficulty,
            effectiveStage,
          ),
        );
    return (slot: slot, settings: settings);
  }

  Future<void> _initializeRetellPlayer(
    List<List<Sentence>> paragraphs, {
    required LearningProgress progress,
    required int? startSentenceIndex,
    required LearningStage effectiveStage,
    ParagraphPlaybackDriver? playbackDriver,
  }) {
    final resolved = _resolveRetellSettings(progress, effectiveStage);
    return ref
        .read(retellPlayerProvider.notifier)
        .initialize(
          paragraphs,
          startSentenceIndex: startSentenceIndex,
          settings: resolved.settings,
          settingsSlot: resolved.slot,
          playbackDriver: playbackDriver,
        );
  }

  /// 进入复习难句补练模式
  ///
  /// 1. 保存当前用户播放设置
  /// 2. 暂停 LP 的 stream 监听
  /// 3. 从 BookmarkDao 读取难句 → 过滤句子
  /// 4. 初始化 ReviewDifficultPractice
  Future<void> enterReviewDifficultPracticeMode(
    String audioItemId,
    List<Sentence> allSentences, {
    bool isFreePlay = false,
    DifficultPracticeSettings settings = const DifficultPracticeSettings(),
    LearningStage? stage,
  }) async {
    _startStudyTimer();
    final practice = ref.read(listeningPracticeProvider.notifier);
    final currentSettings = ref.read(listeningPracticeProvider).settings;

    // 从数据库读取难句索引
    final bookmarkDao = ref.read(bookmarkDaoProvider);
    final bookmarkedIndices = await bookmarkDao.getBookmarkedIndices(
      audioItemId,
    );

    // 过滤出难句列表
    final difficultSentences = allSentences
        .where((s) => bookmarkedIndices.contains(s.index))
        .toList();

    // 各自读取独立字段 + 校验过期时间
    final progress = await ref
        .read(learningProgressNotifierProvider.notifier)
        .getLatestOrEnsureProgress(audioItemId);
    int startIndex = 0;
    if (isFreePlay && _isBreakpointValid(progress.freePlayBreakpointSavedAt)) {
      startIndex = progress.freePlayDifficultPracticeSentenceIndex ?? 0;
    } else if (!isFreePlay &&
        _isBreakpointValid(progress.newLearningBreakpointSavedAt)) {
      startIndex = progress.difficultPracticeSentenceIndex ?? 0;
    }

    state = state.copyWith(
      learningMode: LearningMode.reviewDifficultPractice,
      blindListenCompleted: false,
      audioItemId: audioItemId,
      savedSettings: currentSettings,
      isFreePlay: isFreePlay,
      playbackChain: LearningPlaybackChain.audio,
    );

    // 暂停 LP 的 stream 监听
    practice.suspendListeners();
    // 录音类任务（难句补练）用前台引擎、不上锁屏：先停媒体引擎清残留卡片，再加载到前台引擎。
    await ref.read(audioEngineProvider.notifier).stop();
    await _ensureAudioLoaded(audioItemId, foreground: true);

    _logEnterMode(
      'enterReviewDifficultPracticeMode',
      audioItemId,
      sentenceCount: difficultSentences.length,
      firstSentenceText: difficultSentences.isNotEmpty
          ? difficultSentences.first.text
          : null,
    );

    // 初始化难句补练播放器（传入断点索引 + 入口选择的播放速度 + 句间停顿）
    final player = ref.read(reviewDifficultPracticeProvider.notifier);
    player.initialize(
      difficultSentences,
      startIndex: startIndex,
      settings: settings,
      // 按槽位记忆;自由练习与按计划共用同一轮次槽位(stage 由入口传入)。
      settingsSlot: stageSlotKey(
        StageSettingsSlots.reviewDifficultPractice,
        stage,
      ),
    );
    _trackSessionStart();
  }

  /// 进入视频难句补练：媒体只负责原句区间播放，练习流程与音频共用。
  Future<MediaLoadResult> enterMediaReviewDifficultPracticeMode(
    AudioItem mediaItem,
    List<Sentence> allSentences, {
    bool isFreePlay = false,
    DifficultPracticeSettings settings = const DifficultPracticeSettings(),
    LearningStage? stage,
  }) async {
    final generation = ++_mediaReviewDifficultEntryGeneration;
    bool isCurrentGeneration() =>
        generation == _mediaReviewDifficultEntryGeneration;

    final bookmarkDao = ref.read(bookmarkDaoProvider);
    final bookmarkedIndices = await bookmarkDao.getBookmarkedIndices(
      mediaItem.id,
    );
    if (!isCurrentGeneration()) return MediaLoadResult.cancelled;

    final difficultSentences = allSentences
        .where((sentence) => bookmarkedIndices.contains(sentence.index))
        .map((sentence) => sentence.copyWith(isBookmarked: true))
        .toList();
    final progress = await ref
        .read(learningProgressNotifierProvider.notifier)
        .getLatestOrEnsureProgress(mediaItem.id);
    if (!isCurrentGeneration()) return MediaLoadResult.cancelled;

    var startIndex = 0;
    if (isFreePlay && _isBreakpointValid(progress.freePlayBreakpointSavedAt)) {
      startIndex = progress.freePlayDifficultPracticeSentenceIndex ?? 0;
    } else if (!isFreePlay &&
        _isBreakpointValid(progress.newLearningBreakpointSavedAt)) {
      startIndex = progress.difficultPracticeSentenceIndex ?? 0;
    }

    // 录音类视频任务不复用前台音频播放器；这里只清理旧系统媒体会话。
    await ref.read(audioEngineProvider.notifier).stop();
    if (!isCurrentGeneration()) return MediaLoadResult.cancelled;

    final mediaEngine = ref.read(mediaEngineProvider.notifier);
    final duration = await mediaEngine.loadMedia(
      mediaItem,
      settings.playbackSpeed,
    );
    if (!isCurrentGeneration()) {
      await mediaEngine.releaseFromScreen();
      return MediaLoadResult.cancelled;
    }
    if (duration == null) {
      AppLogger.log(
        'Session',
        '✗ enterMediaReviewDifficultPracticeMode load failed: ${mediaItem.id}',
      );
      await mediaEngine.releaseFromScreen();
      return MediaLoadResult.failure;
    }

    await mediaEngine.setSubtitleTrackData(null);
    if (!isCurrentGeneration()) {
      await mediaEngine.releaseFromScreen();
      return MediaLoadResult.cancelled;
    }

    state = state.copyWith(
      learningMode: LearningMode.reviewDifficultPractice,
      blindListenCompleted: false,
      audioItemId: mediaItem.id,
      isFreePlay: isFreePlay,
      playbackChain: LearningPlaybackChain.media,
      clearSavedSettings: true,
    );

    ref
        .read(reviewDifficultPracticeProvider.notifier)
        .initialize(
          difficultSentences,
          startIndex: startIndex,
          settings: settings,
          settingsSlot: stageSlotKey(
            StageSettingsSlots.reviewDifficultPractice,
            stage,
          ),
          playbackDriver: MediaSentencePlaybackDriver(mediaEngine),
          usesMediaEngine: true,
        );
    if (!isCurrentGeneration()) {
      await exitLearningMode();
      return MediaLoadResult.cancelled;
    }

    _startStudyTimer();
    _trackSessionStart();
    AppLogger.log(
      'Session',
      '🎬 enterMediaReviewDifficultPracticeMode: targetId=${mediaItem.id}, '
          'sentences=${difficultSentences.length}',
    );
    return MediaLoadResult.ready;
  }

  /// 取消视频难句补练加载，或退出已建立的媒体会话。
  Future<void> cancelMediaReviewDifficultPracticeEntry() async {
    _mediaReviewDifficultEntryGeneration += 1;
    if (state.learningMode == LearningMode.reviewDifficultPractice &&
        state.playbackChain == LearningPlaybackChain.media) {
      await exitLearningMode();
    }
  }

  /// 退出学习模式
  ///
  /// 根据当前学习模式分支处理：停止播放、释放资源、恢复 LP 监听。
  Future<void> exitLearningMode() async {
    final mode = state.learningMode;
    final intensivePlayer = mode == LearningMode.intensiveListen
        ? ref.read(intensiveListenPlayerProvider.notifier)
        : null;
    final blindPlayer = mode == LearningMode.blindListen
        ? ref.read(blindListenPlayerProvider.notifier)
        : null;
    final retellPlayer = mode == LearningMode.retell
        ? ref.read(retellPlayerProvider.notifier)
        : null;
    _trackSessionEnd(
      durationMs:
          intensivePlayer?.elapsed.inMilliseconds ??
          blindPlayer?.elapsed.inMilliseconds ??
          retellPlayer?.elapsed.inMilliseconds,
    );
    if (mode != LearningMode.intensiveListen &&
        mode != LearningMode.blindListen &&
        mode != LearningMode.retell) {
      _stopPeriodicSaveTimer();
      await _saveStudyTime();
    }
    AppLogger.log(
      'Session',
      'exitLearningMode: begin mode=$mode chain=${state.playbackChain}',
    );

    _playerStateSub?.cancel();
    _playerStateSub = null;
    final usesMediaChain = state.playbackChain == LearningPlaybackChain.media;
    if (mode == LearningMode.retell && usesMediaChain) {
      _mediaRetellEntryGeneration += 1;
    }
    if (mode == LearningMode.blindListen && usesMediaChain) {
      _mediaBlindListenEntryGeneration += 1;
    }
    if (mode == LearningMode.reviewDifficultPractice && usesMediaChain) {
      _mediaReviewDifficultEntryGeneration += 1;
    }
    if (mode == LearningMode.blindListen) {
      await blindPlayer?.disposePlayer();
    } else if (mode == LearningMode.intensiveListen) {
      // 释放精听播放器资源
      await intensivePlayer?.disposePlayer();
    } else if (mode == LearningMode.listenAndRepeat) {
      // 跟读资源由 ListenAndRepeatController 在 Screen 层释放
    } else if (mode == LearningMode.retell) {
      // 释放复述播放器资源
      await retellPlayer?.disposePlayer();
    } else if (mode == LearningMode.reviewDifficultPractice) {
      // 释放难句补练播放器资源
      final player = ref.read(reviewDifficultPracticeProvider.notifier);
      player.disposePlayer();
    }

    // 录音控制器属于录音任务本身，音频和视频退出都必须先完整复位。
    if (mode == LearningMode.retell) {
      await ref.read(retellRecordingControllerProvider.notifier).fullReset();
    }
    if (mode == LearningMode.reviewDifficultPractice) {
      await ref.read(speechRecordingControllerProvider.notifier).fullReset();
    }

    if (usesMediaChain) {
      AppLogger.log(
        'Session',
        'exitLearningMode: releasing media chain mode=$mode',
      );
      await ref.read(mediaEngineProvider.notifier).releaseFromScreen();
      await _flushLearnedVocabulary();
      ref.read(dailyStudyTimeProvider.notifier).refresh();
      ref.invalidate(studyDurationRecordsProvider);
      ref.read(studyStatsNotifierProvider.notifier).refresh();
      state = const LearningSessionState();
      AppLogger.log(
        'Session',
        'exitLearningMode: complete mode=$mode media chain',
      );
      return;
    }

    // 通用：清除 clip 防止残留影响 LP 的 absolutePositionStream
    final engine = ref.read(audioEngineProvider.notifier);
    await engine.clearClip();
    final savedSettings = state.savedSettings;
    if (savedSettings != null) {
      await engine.setSpeed(savedSettings.playbackSpeed);
    }
    // 按模式调用对应录音控制器的 fullReset
    if (mode == LearningMode.listenAndRepeat) {
      await ref.read(speechRecordingControllerProvider.notifier).fullReset();
    }

    // 恢复 LP 的 stream 监听
    final practice = ref.read(listeningPracticeProvider.notifier);
    practice.resumeListeners();

    // 同步精听期间新增的书签到 LP 内存状态
    await practice.syncBookmarks();

    // 停止引擎播放（确保干净退出）
    await practice.stop();

    await _flushLearnedVocabulary();

    // 通知 UI 刷新今日学习时长
    ref.read(dailyStudyTimeProvider.notifier).refresh();
    ref.invalidate(studyDurationRecordsProvider);
    ref.read(studyStatsNotifierProvider.notifier).refresh();

    state = const LearningSessionState();
  }

  /// 记录进入学习模式时的音频/字幕诊断信息
  void _logEnterMode(
    String mode,
    String audioItemId, {
    int? sentenceCount,
    String? firstSentenceText,
  }) {
    final engineId = ref.read(audioEngineProvider).currentAudioId;
    final lp = ref.read(listeningPracticeProvider);
    final lpItem = lp.currentAudioItem;
    final preview = firstSentenceText != null
        ? firstSentenceText.substring(0, min(40, firstSentenceText.length))
        : (lp.sentences.isNotEmpty
              ? lp.sentences.first.text.substring(
                  0,
                  min(40, lp.sentences.first.text.length),
                )
              : 'empty');
    AppLogger.log(
      'Session',
      '🎬 $mode: '
          'targetId=$audioItemId, '
          'engineId=$engineId, '
          'lpId=${lpItem?.id}, '
          'lpName=${lpItem?.name}, '
          'transcript=${lpItem?.transcriptPath}, '
          'sentences=${sentenceCount ?? lp.sentences.length}, '
          'first="$preview"',
    );
  }

  /// 断点是否有效（距今 ≤3 天）
  bool _isBreakpointValid(DateTime? savedAt) {
    if (savedAt == null) return false;
    return DateTime.now().difference(savedAt).inDays <= 3;
  }

  /// 确保音频引擎已加载目标音频
  ///
  /// 收藏页、单词卡等页面可能将不同音频加载到全局引擎，
  /// 导致引擎持有的音频与当前学习目标不一致。
  /// 进入任何学习模式前调用此方法，检测不匹配时主动重新加载。
  ///
  /// [foreground] 为 true 时加载到前台引擎（录音类任务：复述/补练，不上锁屏），
  /// 否则加载到媒体引擎（盲听/精听，需后台+锁屏）。见 PLAN.md ADR-7。
  Future<void> _ensureAudioLoaded(
    String audioItemId, {
    bool foreground = false,
  }) async {
    final lp = ref.read(listeningPracticeProvider);
    final audioItem = lp.currentAudioItem;

    if (foreground) {
      final engine = ref.read(foregroundAudioEngineProvider);
      if (engine.currentAudioId == audioItemId && !engine.isLoading) return;
      if (audioItem != null && audioItem.id == audioItemId) {
        await ref
            .read(foregroundAudioEngineProvider.notifier)
            .loadAudio(audioItem, lp.settings.playbackSpeed);
      }
      return;
    }

    final engine = ref.read(audioEngineProvider);
    if (engine.currentAudioId == audioItemId && !engine.isLoading) return;
    if (audioItem != null && audioItem.id == audioItemId) {
      await ref
          .read(audioEngineProvider.notifier)
          .loadAudio(audioItem, lp.settings.playbackSpeed);
    }
  }
}
