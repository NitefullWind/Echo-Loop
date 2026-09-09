import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/providers.dart';
import '../../database/daos/playback_state_dao.dart';
import '../../models/audio_item.dart';
import '../../models/listening_practice_state.dart';
import '../../models/media_load_result.dart';
import '../../models/media_playback_state.dart';
import '../../models/playback_settings.dart';
import '../../models/sentence.dart';
import '../../models/sentence_playback_result.dart';
import '../../models/sense_group_range_playback.dart';
import '../../models/study_stage.dart';
import '../../services/app_logger.dart';
import '../../services/study_session_timer.dart';
import '../../services/storage_service.dart';
import '../audio_engine/audio_engine_provider.dart';
import '../listening_practice/bookmark_manager.dart';
import '../favorite_sentence_lifecycle_provider.dart';
import '../listening_practice/playback_reducer.dart';
import '../listening_practice/playback_state_storage.dart';
import '../listening_practice/sentence_tracker.dart';
import '../media_engine/media_engine_provider.dart';
import '../media_engine/media_sense_group_range_playback.dart';

final mediaPlaybackProvider =
    NotifierProvider<MediaPlayback, MediaPlaybackState>(MediaPlayback.new);

/// media_kit 随心听控制器。
///
/// 当前用于带画面轨的媒体页面。实现刻意独立于现有音频随心听 controller，便于先在
/// media_kit + audio_service 链路上收敛正确性，后续再决定音频迁移边界。
class MediaPlayback extends Notifier<MediaPlaybackState> {
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool?>? _landscapeVideoSub;
  StreamSubscription<double?>? _videoAspectRatioSub;
  int _loadGeneration = 0;
  int _playbackGen = 0;
  int _playbackSessionId = -1;
  bool _activeSentenceDrivenPlayback = false;
  bool _awaitingReplayFromStart = false;
  Duration? _pauseAfterPosition;
  bool _autoSaving = false;
  bool _released = false;
  bool _loadReady = false;
  bool _positionUpdatesEnabled = false;
  bool _changingPlaylistMode = false;
  String? _videoSubtitleSrt;
  MediaEngine? _engineCache;
  int? _loadedResourceGeneration;
  SenseGroupRangePlayback? _senseGroupRangePlayback;
  PlaybackStateDao? _playbackStateDaoCache;
  StudySessionTimer? _studySessionTimer;
  int _studyPageGeneration = 0;
  int? _activeStudyPageGeneration;

  MediaEngine get _engine {
    final cached = _engineCache;
    if (cached != null) return cached;
    final engine = ref.read(mediaEngineProvider.notifier);
    _engineCache = engine;
    return engine;
  }

  /// 建立视频随心听页面级学习会话；页面退出前播放器状态不会结束该会话。
  int beginStudyPage() {
    final generation = ++_studyPageGeneration;
    _activeStudyPageGeneration = generation;
    if (_studySessionTimer == null) {
      final timer = StudySessionTimer(
        studyTimeService: ref.read(studyTimeServiceProvider),
        stage: StudyStage.freePlayer,
        activityGate: ref.read(studyActivityGateProvider),
        idleTimeout: const Duration(minutes: 2),
        logScope: 'FreePlayerMediaTimer',
      );
      _studySessionTimer = timer;
      timer.start();
    } else {
      _studySessionTimer?.markActivity();
    }
    _studySessionTimer?.setPlaybackActive(state.isPlaying);
    return generation;
  }

  /// 标记视频随心听页面上的用户活动。
  void markStudyActivity() {
    _studySessionTimer?.markActivity();
  }

  /// 将播放器活动状态同步给页面学习会话。
  void _setStudyPlaybackActive(bool active) {
    _studySessionTimer?.setPlaybackActive(active);
  }

  /// 结束指定页面会话；过期页面的异步清理不会关闭新页面会话。
  Future<bool> endStudyPage(int generation) async {
    if (_activeStudyPageGeneration != generation) return false;
    await _endActiveStudyPage();
    return true;
  }

  Future<void> _endActiveStudyPage() async {
    _activeStudyPageGeneration = null;
    final timer = _studySessionTimer;
    _studySessionTimer = null;
    if (timer != null) await timer.dispose();
  }

  void _setPlaying(bool playing) {
    if (!playing) {
      state = state.copyWith(isPlaying: false);
      _setStudyPlaybackActive(false);
      return;
    }
    if (state.isPlaying) return;
    state = state.copyWith(isPlaying: playing);
    _setStudyPlaybackActive(true);
  }

  /// 将播放器置为停止态；学习页面会话由页面退出时统一结束。
  Future<void> _stopPlaying() async {
    state = state.copyWith(isPlaying: false);
    _setStudyPlaybackActive(false);
  }

  /// 普通暂停只暂停输入计时，保留页面学习会话供用户继续思考。
  Future<void> _pausePlaying() async {
    state = state.copyWith(isPlaying: false);
    _setStudyPlaybackActive(false);
  }

  /// 当前媒体会话的意群区间播放器；随心听页面只通过该契约传递播放意图。
  SenseGroupRangePlayback get senseGroupRangePlayback {
    return _senseGroupRangePlayback ??= MediaSenseGroupRangePlayback(
      engine: _engine,
      playbackSpeed: () => state.settings.playbackSpeed,
    );
  }

  @override
  MediaPlaybackState build() {
    ref.onDispose(() {
      _loadGeneration++;
      _playbackGen++;
      unawaited(_positionSub?.cancel());
      unawaited(_playingSub?.cancel());
      unawaited(_landscapeVideoSub?.cancel());
      unawaited(_videoAspectRatioSub?.cancel());
      final engine = _engineCache;
      unawaited(_endActiveStudyPage());
      unawaited(_senseGroupRangePlayback?.cancel());
      engine?.setTransportHandlers(onPlay: null, onPause: null);
      unawaited(engine?.releaseForOwnerDispose());
    });
    return const MediaPlaybackState();
  }

  List<Sentence> get _playable => state.playableSentences;

  bool get _usesSentenceDrivenPlayback =>
      state.playlistMode == PlaylistMode.bookmarks ||
      state.settings.loopSentence;

  int? get _currentPos => state.currentPlayablePosition;

  /// 准备随心听媒体及其业务数据。
  ///
  /// 每次调用都会分配独立 generation；退出、取消或后续重试会使旧任务失效，
  /// 防止迟到的字幕、断点和播放器结果重新污染已经释放的页面状态。
  Future<MediaLoadResult> load(AudioItem item) async {
    final pendingRelease = _releaseInFlight;
    if (pendingRelease != null) {
      await pendingRelease;
    }
    final engine = _engine;
    if (state.audioItem?.id == item.id &&
        !_released &&
        _loadReady &&
        _loadedResourceGeneration == engine.resourceGeneration &&
        engine.isReadyFor(item.id)) {
      return MediaLoadResult.ready;
    }
    final generation = ++_loadGeneration;
    bool isCurrentGeneration() => generation == _loadGeneration && !_released;

    _released = false;
    _loadReady = false;
    _positionUpdatesEnabled = false;
    _playbackGen++;
    _pauseAfterPosition = null;
    await _positionSub?.cancel();
    await _playingSub?.cancel();
    await _landscapeVideoSub?.cancel();
    await _videoAspectRatioSub?.cancel();

    state = state.copyWith(
      audioItem: item,
      isLoading: true,
      isTranscriptLoading: true,
      clearErrorMessage: true,
      clearDuration: true,
      position: Duration.zero,
      sentences: const [],
      clearCurrentFullIndex: true,
      clearCurrentBookmarkIndex: true,
      isPlaying: false,
      wholeLoopsDone: 0,
      sentenceRepeatsDone: 0,
      visualTrackVisible: true,
      visualTrackExpanded: false,
      videoSubtitleVisible: false,
      clearIsLandscapeVideo: true,
      clearVideoAspectRatio: true,
    );
    _videoSubtitleSrt = null;

    try {
      _engineCache = engine;
      final audioEngine = ref.read(audioEngineProvider.notifier);
      final playbackRestoreFuture = _loadPlaybackState(item);
      if (audioEngine.isPlaying) await audioEngine.pause();
      if (!isCurrentGeneration()) return MediaLoadResult.cancelled;

      final settingsStore = await StorageService.loadSettings();
      if (!isCurrentGeneration()) return MediaLoadResult.cancelled;
      state = state.copyWith(
        fullSettings: settingsStore.full.copyWith(
          loopWhole: false,
          loopSentence: false,
        ),
        bookmarkSettings: withBookmarkLoopDefaults(settingsStore.bookmark),
      );

      // 字幕读取与 media_kit 初始化互不依赖，应并行启动。字幕通常更快，完成后
      // 立即更新列表；外挂字幕轨仍在 backend 打开完成后再设置。
      final transcriptFuture = _loadTranscriptData(item, audioEngine);
      // 断点必须在打开视频前就绪：页面先显示正确进度，Media(start) 也能直接
      // 解码目标帧，避免先露出第 0 帧再执行一次可见 seek。
      final playbackRestore = await playbackRestoreFuture;
      if (!isCurrentGeneration()) return MediaLoadResult.cancelled;
      _applyInitialPlaybackState(playbackRestore);
      final mediaFuture = _engine.loadMedia(
        item,
        state.settings.playbackSpeed,
        initialPosition: state.position,
      );

      final transcriptData = await transcriptFuture;
      if (!isCurrentGeneration()) return MediaLoadResult.cancelled;
      _videoSubtitleSrt = transcriptData.subtitleSrt;
      state = state.copyWith(
        sentences: transcriptData.sentences,
        bookmarkedIndices: transcriptData.bookmarkedIndices,
        currentFullIndex: transcriptData.sentences.isEmpty ? null : 0,
        isTranscriptLoading: false,
      );
      _syncSentenceFocusToPosition();

      final duration = await mediaFuture;
      if (!isCurrentGeneration()) return MediaLoadResult.cancelled;
      if (duration == null) {
        final errorMessage = ref.read(mediaEngineProvider).errorMessage;
        await _engine.releaseFromScreen();
        if (!isCurrentGeneration()) return MediaLoadResult.cancelled;
        state = state.copyWith(isLoading: false, errorMessage: errorMessage);
        return MediaLoadResult.failure;
      }

      _engine.setTransportHandlers(onPlay: play, onPause: pause);
      _positionSub = _engine.positionStream.listen(_onPositionChanged);
      _playingSub = _engine.playingStream.listen((playing) {
        // 底层状态只校准 UI。计时器由 Provider 的显式播放/暂停入口控制，避免
        // 区间起播时 backend 的瞬时 false 让计时器被错误切断。
        if (state.isPlaying != playing) {
          state = state.copyWith(isPlaying: playing);
        }
      });
      state = state.copyWith(isLandscapeVideo: _engine.isLandscapeVideo);
      _landscapeVideoSub = _engine.isLandscapeVideoStream.listen((value) {
        if (!_released && state.isLandscapeVideo != value) {
          state = state.copyWith(
            isLandscapeVideo: value,
            clearIsLandscapeVideo: value == null,
          );
        }
      });
      state = state.copyWith(videoAspectRatio: _engine.videoAspectRatio);
      _videoAspectRatioSub = _engine.videoAspectRatioStream.listen((value) {
        if (!_released && state.videoAspectRatio != value) {
          state = state.copyWith(
            videoAspectRatio: value,
            clearVideoAspectRatio: value == null,
          );
        }
      });

      // 视频进入时默认不显示字幕，同时清空播放器可能保留的外挂字幕轨。
      await _engine.setSubtitleTrackData(
        state.videoSubtitleVisible ? _videoSubtitleSrt : null,
      );
      if (!isCurrentGeneration()) return MediaLoadResult.cancelled;
      state = state.copyWith(duration: duration, isLoading: false);
      _positionUpdatesEnabled = true;
      _applyTransportSpeed();
      _loadReady = true;
      _loadedResourceGeneration = engine.resourceGeneration;
      return MediaLoadResult.ready;
    } catch (e) {
      AppLogger.log('MediaPlayback', '✗ load failed: $e');
      if (!isCurrentGeneration()) return MediaLoadResult.cancelled;
      await _engineCache?.releaseFromScreen();
      if (!isCurrentGeneration()) return MediaLoadResult.cancelled;
      state = state.copyWith(
        isLoading: false,
        isTranscriptLoading: false,
        errorMessage: e.toString(),
      );
      return MediaLoadResult.failure;
    }
  }

  /// 读取页面字幕、外挂字幕原文与收藏状态。
  ///
  /// 此流程不依赖播放器 backend，可与视频打开并行；只有数据完整后才结束字幕加载
  /// 状态，避免列表先显示未同步收藏标记的中间态。
  Future<
    ({
      List<Sentence> sentences,
      Set<int> bookmarkedIndices,
      String? subtitleSrt,
    })
  >
  _loadTranscriptData(AudioItem item, AudioEngine audioEngine) async {
    final sentencesFuture = audioEngine.loadTranscript(item);
    final subtitleSrtFuture = _loadSubtitleTrackData(item);
    final sentences = await sentencesFuture;
    final subtitleSrt = await subtitleSrtFuture;
    var bookmarkedIndices = <int>{};
    if (sentences.isNotEmpty) {
      try {
        final bookmarkDao = ref.read(bookmarkDaoProvider);
        bookmarkedIndices = await BookmarkManager.loadBookmarks(
          item.id,
          dao: bookmarkDao,
        );
      } catch (e) {
        AppLogger.log('MediaPlayback', '⚠ load bookmarks failed: $e');
      }
    }
    BookmarkManager.updateSentenceBookmarkStatus(sentences, bookmarkedIndices);
    return (
      sentences: sentences,
      bookmarkedIndices: bookmarkedIndices,
      subtitleSrt: subtitleSrt,
    );
  }

  void _onPositionChanged(Duration position) {
    // backend 初始化期间可能先补发 0；断点已作为 Media(start) 传入，正式就绪前
    // 保持预读的正确位置，避免进度条从断点闪回 0 再恢复。
    if (!_positionUpdatesEnabled) return;
    state = state.copyWith(position: position);
    if (!_engine.isActiveSession(_playbackSessionId)) return;
    final pauseAfterPosition = _pauseAfterPosition;
    if (_engine.isPlaying &&
        pauseAfterPosition != null &&
        position >= pauseAfterPosition) {
      _pauseAfterPosition = null;
      unawaited(pause());
      return;
    }
    if (!_engine.isPlaying || _activeSentenceDrivenPlayback) return;
    final idx = _nearestSentenceIndex(position);
    if (idx < 0) return;
    if (state.playlistMode == PlaylistMode.bookmarks) {
      final bookmarkIndex = _nearestBookmarkIndex(position);
      if (bookmarkIndex != null &&
          bookmarkIndex != state.currentBookmarkIndex) {
        state = state.copyWith(currentBookmarkIndex: bookmarkIndex);
        _autoSaveProgress();
      }
      return;
    }
    if (idx != state.currentFullIndex) {
      state = state.copyWith(currentFullIndex: idx);
      _autoSaveProgress();
    }
  }

  /// 在播放器打开前读取断点，供进度 state 与 media_kit 的 start 参数共同使用。
  Future<PlaybackStateRestoreResult?> _loadPlaybackState(AudioItem item) async {
    PlaybackStateDao dao;
    try {
      dao = _playbackStateDaoCache ?? ref.read(playbackStateDaoProvider);
      _playbackStateDaoCache = dao;
    } catch (e) {
      AppLogger.log('MediaPlayback', '⚠ restore state unavailable: $e');
      return null;
    }
    return PlaybackStateStorage.loadPlaybackState(item.id, dao: dao);
  }

  void _applyInitialPlaybackState(PlaybackStateRestoreResult? result) {
    if (result == null) return;
    final mode = result.playlistMode;
    final position = result.position;
    state = state.copyWith(playlistMode: mode, position: position);
  }

  /// 字幕可能晚于断点完成；字幕写入后再从已恢复位置推导当前播放列表的焦点。
  ///
  /// 收藏模式的媒体时间不应被列表焦点吸附，但焦点必须选中恢复时间附近的收藏句；
  /// 否则空的 [MediaPlaybackState.currentBookmarkIndex] 会被
  /// [_ensureValidIndex] 回退成第一条收藏，造成列表与进度条指向不同句子。
  void _syncSentenceFocusToPosition() {
    final idx = _nearestSentenceIndex(state.position);
    if (idx >= 0) state = state.copyWith(currentFullIndex: idx);
    if (state.playlistMode == PlaylistMode.bookmarks) {
      final bookmarkIndex = _nearestBookmarkIndex(state.position);
      if (bookmarkIndex != null) {
        state = state.copyWith(currentBookmarkIndex: bookmarkIndex);
      }
    }
    _ensureValidIndex();
  }

  /// 按当前播放设置开始或恢复播放。
  ///
  /// 用户在播放中拖动进度、点选句子或切换上下句时传
  /// [resetWholeLoops] 为 false：这些都是同一整篇循环会话内的导航，不能把已经
  /// 自然完成的整篇遍数清零。仅明确新起播时才使用默认值重置计数。
  Future<void> play({bool resetWholeLoops = true}) async {
    AppLogger.log(
      'MediaPlayback',
      'play tap: item=${state.audioItem?.id} loading=${state.isLoading} '
          'sentences=${state.sentences.length} isPlaying=${state.isPlaying} '
          'session=$_playbackSessionId engineSession=${_engine.currentSessionId}',
    );
    if (state.audioItem == null || state.isLoading) {
      AppLogger.log('MediaPlayback', 'play ignored: no item or loading');
      return;
    }
    if (state.sentences.isEmpty) {
      AppLogger.log(
        'MediaPlayback',
        'play route: whole playback without subtitles',
      );
      await _startWholeDriven(startAtBeginning: _shouldRestartWhole());
      return;
    }
    _ensureValidIndex();
    if (state.playlistMode == PlaylistMode.bookmarks &&
        state.bookmarkedSentences.isEmpty) {
      AppLogger.log(
        'MediaPlayback',
        'play ignored: bookmark playlist is empty',
      );
      return;
    }
    if (_awaitingReplayFromStart || _isAtEnd()) {
      await _restartFromPlayableBeginning();
      return;
    }
    if (_usesSentenceDrivenPlayback) {
      AppLogger.log('MediaPlayback', 'play route: sentence playback');
      _launchSentenceDriven(
        resetWholeLoops: resetWholeLoops,
        resetSentenceRepeats: true,
      );
      return;
    }
    await _startWholeDriven(resetWholeLoops: resetWholeLoops);
  }

  Future<void> pause() async {
    AppLogger.log(
      'MediaPlayback',
      'pause tap: item=${state.audioItem?.id} session=$_playbackSessionId '
          'engineSession=${_engine.currentSessionId}',
    );
    _playbackGen++;
    _activeSentenceDrivenPlayback = false;
    _awaitingReplayFromStart = false;
    _pauseAfterPosition = null;
    await _pausePlaying();
    await _engine.pause();
    _playbackSessionId = _engine.currentSessionId;
  }

  /// 请求当前句自然播放结束后暂停；未在播放或当前句无效时立即暂停。
  Future<void> pauseAfterCurrentSentence() async {
    if (!state.isPlaying) {
      await pause();
      return;
    }
    final pos = _currentPos;
    final playable = _playable;
    if (pos == null || pos < 0 || pos >= playable.length) {
      await pause();
      return;
    }
    final sentenceEnd = playable[pos].endTime;
    if (state.position >= sentenceEnd) {
      await pause();
      return;
    }
    _pauseAfterPosition = sentenceEnd;
  }

  Future<void> seekAbsolute(Duration target) async {
    if (target < Duration.zero) target = Duration.zero;
    final duration = state.duration;
    if (duration != null && target > duration) target = duration;
    final wasPlaying = state.isPlaying;
    _playbackGen++;
    _activeSentenceDrivenPlayback = false;
    _awaitingReplayFromStart = false;
    _pauseAfterPosition = null;

    if (state.sentences.isNotEmpty) {
      final idx = _nearestSentenceIndex(target);
      if (state.playlistMode == PlaylistMode.bookmarks) {
        final playable = _playable;
        if (playable.isEmpty) return;
        var pos = playable.indexWhere((s) => s.index == idx);
        if (pos < 0) {
          final closest = SentenceTracker.findClosestBookmark(playable, target);
          pos = closest == null
              ? 0
              : playable.indexWhere((s) => s.index == closest);
        }
        final safePos = pos < 0 ? 0 : pos;
        final selected = playable[safePos];
        target = selected.startTime;
        state = state.copyWith(
          currentBookmarkIndex: selected.index,
          lastPlayedBookmarkIndex: selected.index,
        );
      } else if (idx >= 0) {
        state = state.copyWith(currentFullIndex: idx, lastPlayedFullIndex: idx);
      }
    }

    await _engine.seek(target);
    await _pausePlaying();
    state = state.copyWith(position: target, sentenceRepeatsDone: 0);
    if (wasPlaying) unawaited(play(resetWholeLoops: false));
  }

  Future<void> seekRelative(Duration delta) async {
    await seekAbsolute(state.position + delta);
  }

  Future<void> previousSentence() async {
    if (state.sentences.isEmpty) {
      await seekRelative(const Duration(seconds: -10));
      return;
    }
    final playable = _playable;
    if (playable.isEmpty) return;
    final current = _currentPos ?? 0;
    if (current <= 0) return;
    await _moveToPosition(current - 1);
  }

  Future<void> nextSentence() async {
    if (state.sentences.isEmpty) {
      await seekRelative(const Duration(seconds: 10));
      return;
    }
    final playable = _playable;
    if (playable.isEmpty) return;
    final current = _currentPos ?? 0;
    if (current >= playable.length - 1) return;
    await _moveToPosition(current + 1);
  }

  Future<void> selectFullSentence(int index, {bool autoPlay = true}) async {
    if (index < 0 || index >= state.sentences.length) return;
    final wasPlaying = state.isPlaying;
    state = state.copyWith(currentFullIndex: index, lastPlayedFullIndex: index);
    await _alignEngineToCurrent();
    if (autoPlay) {
      unawaited(play(resetWholeLoops: !wasPlaying));
    }
  }

  Future<void> selectBookmarkedSentence(
    int index, {
    bool autoPlay = true,
  }) async {
    if (index < 0 || index >= state.sentences.length) return;
    if (!state.bookmarkedIndices.contains(index)) return;
    final wasPlaying = state.isPlaying;
    state = state.copyWith(
      currentBookmarkIndex: index,
      lastPlayedBookmarkIndex: index,
    );
    await _alignEngineToCurrent();
    if (autoPlay) {
      unawaited(play(resetWholeLoops: !wasPlaying));
    }
  }

  /// 进入句子讲解前，将媒体焦点对齐到目标句并保持暂停。
  Future<void> prepareSentenceDetail(int index) async {
    AppLogger.log(
      'MediaPlayback',
      'sentence detail prepare media=${state.audioItem?.id} index=$index',
    );
    if (state.playlistMode == PlaylistMode.bookmarks) {
      await selectBookmarkedSentence(index, autoPlay: false);
    } else {
      await selectFullSentence(index, autoPlay: false);
    }
    await pause();
  }

  /// 从句子讲解返回后，同步收藏状态并恢复当前媒体句的暂停位置。
  Future<void> restoreAfterSentenceDetail() async {
    final item = state.audioItem;
    if (item == null) return;
    AppLogger.log(
      'MediaPlayback',
      'sentence detail restore media=${item.id} '
          'index=${state.playlistMode == PlaylistMode.bookmarks ? state.currentBookmarkIndex : state.currentFullIndex}',
    );

    final bookmarkedIndices = await BookmarkManager.loadBookmarks(
      item.id,
      dao: ref.read(bookmarkDaoProvider),
    );
    final sentences = List<Sentence>.from(state.sentences);
    BookmarkManager.updateSentenceBookmarkStatus(sentences, bookmarkedIndices);

    final currentBookmarkIndex = state.currentBookmarkIndex;
    final currentBookmarkRemoved =
        state.playlistMode == PlaylistMode.bookmarks &&
        !bookmarkedIndices.contains(currentBookmarkIndex);
    final bookmarksBecameEmpty =
        state.playlistMode == PlaylistMode.bookmarks &&
        bookmarkedIndices.isEmpty;
    state = state.copyWith(
      sentences: sentences,
      bookmarkedIndices: bookmarkedIndices,
      playlistMode: bookmarksBecameEmpty ? PlaylistMode.full : null,
      currentFullIndex: bookmarksBecameEmpty
          ? currentBookmarkIndex ?? state.currentFullIndex ?? 0
          : null,
      clearCurrentBookmarkIndex: currentBookmarkRemoved,
    );
    _ensureValidIndex();
    await _alignEngineToCurrent();
  }

  Future<void> _moveToPosition(int pos) async {
    final playable = _playable;
    if (pos < 0 || pos >= playable.length) return;
    final wasPlaying = state.isPlaying;
    final selected = playable[pos];
    if (state.playlistMode == PlaylistMode.bookmarks) {
      state = state.copyWith(
        currentBookmarkIndex: selected.index,
        lastPlayedBookmarkIndex: selected.index,
      );
    } else {
      state = state.copyWith(
        currentFullIndex: selected.index,
        lastPlayedFullIndex: selected.index,
      );
    }
    await _alignEngineToCurrent();
    if (wasPlaying) unawaited(play(resetWholeLoops: false));
  }

  Future<void> toggleBookmark(int index) async {
    final item = state.audioItem;
    if (item == null || index < 0 || index >= state.sentences.length) return;
    final (
      isRemoving,
      indicesToRemove,
      replacementIndex,
    ) = BookmarkManager.toggleBookmark(
      index,
      state.sentences,
      state.bookmarkedIndices,
      state.playlistMode == PlaylistMode.bookmarks,
    );

    final newBookmarks = Set<int>.from(state.bookmarkedIndices);
    final newSentences = List<Sentence>.from(state.sentences);
    if (isRemoving) {
      final toRemove = indicesToRemove.isEmpty ? {index} : indicesToRemove;
      for (final idx in toRemove) {
        newBookmarks.remove(idx);
        if (idx >= 0 && idx < newSentences.length) {
          newSentences[idx] = newSentences[idx].copyWith(isBookmarked: false);
        }
      }
      if (state.playlistMode == PlaylistMode.bookmarks) {
        if (newBookmarks.isEmpty) {
          // 收藏播放列表不保留空死端：取消最后一条后回到
          // 全文，并保持刚操作的句子为当前焦点。
          state = state.copyWith(
            playlistMode: PlaylistMode.full,
            bookmarkedIndices: newBookmarks,
            sentences: newSentences,
            currentFullIndex: index,
            clearCurrentBookmarkIndex: true,
          );
          await pause();
        } else if (replacementIndex != null &&
            newBookmarks.contains(replacementIndex)) {
          state = state.copyWith(
            bookmarkedIndices: newBookmarks,
            sentences: newSentences,
            currentBookmarkIndex: replacementIndex,
          );
        } else {
          state = state.copyWith(
            bookmarkedIndices: newBookmarks,
            sentences: newSentences,
            clearCurrentBookmarkIndex: true,
          );
          await pause();
        }
      } else {
        state = state.copyWith(
          bookmarkedIndices: newBookmarks,
          sentences: newSentences,
        );
      }
      await ref
          .read(favoriteSentenceLifecycleProvider)
          .remove(item.id, toRemove);
    } else {
      newBookmarks.add(index);
      newSentences[index] = newSentences[index].copyWith(isBookmarked: true);
      state = state.copyWith(
        bookmarkedIndices: newBookmarks,
        sentences: newSentences,
      );
      await ref
          .read(favoriteSentenceLifecycleProvider)
          .save(item.id, state.sentences[index]);
    }
  }

  Future<void> updateSettings(PlaybackSettings next) async {
    final wasSentenceDriven = _usesSentenceDrivenPlayback;
    final willUseSentenceDriven =
        state.playlistMode == PlaylistMode.bookmarks || next.loopSentence;
    state = state.copyWith(settings: next);

    // 单句循环决定底层使用逐句区间播放还是整篇连续播放。播放中切换时必须立刻
    // 失效旧协程并由新模型接管；否则只更新设置会一直等到暂停后再次 play 才生效。
    // 收藏列表始终逐句播放，切换单句循环开关不应打断它。
    // 播放状态流回调可能晚于底层 play；切换循环时以 MediaEngine 的 backend 真值
    // 判断是否需要接管，避免 provider state 尚未回写而丢掉用户的设置变更。
    // provider 状态先于底层 transport 更新；切换发生在 play/区间播放建立期间时，
    // 仅检查 backend 会漏掉这次接管，导致设置变更要等下一次手动播放才生效。
    if ((state.isPlaying || _engine.isPlaying) &&
        wasSentenceDriven != willUseSentenceDriven) {
      if (willUseSentenceDriven) {
        // 用户开启单句循环时明确要求立即从当前句句首重播。
        _launchSentenceDriven(
          resetWholeLoops: false,
          resetSentenceRepeats: true,
        );
      } else {
        // 用户关闭单句循环时从媒体当前真实位置无缝恢复整篇连续播放。旧逐句会话可能
        // 已排队句首 seek，因此新会话需重新对齐当前位置，避免迟到命令将进度回跳。
        // _startWholeDriven 会持续到媒体自然结束；设置更新不能等待该长生命周期会话。
        unawaited(
          _startWholeDriven(
            resumePosition: _engine.currentPosition,
            resetWholeLoops: false,
          ),
        );
      }
    }

    await _applyTransportSpeed();
    await StorageService.saveSettings(
      ListeningPracticeSettingsStore(
        full: state.fullSettings,
        bookmark: state.bookmarkSettings,
      ),
    );
  }

  Future<void> setPlaylistMode(PlaylistMode mode) async {
    if (state.playlistMode == mode || _changingPlaylistMode) return;
    if (mode == PlaylistMode.bookmarks && state.bookmarkedSentences.isEmpty) {
      return;
    }
    _changingPlaylistMode = true;
    try {
      await pause();
      if (_released) return;
      state = state.copyWith(playlistMode: mode);
      _ensureValidIndex();
      await _applyTransportSpeed();
      await _alignEngineToCurrent();
    } finally {
      _changingPlaylistMode = false;
    }
  }

  Future<void> setVisualTrackVisible(bool visible) async {
    AppLogger.log('MediaPlayback', 'visual track visible=$visible');
    state = state.copyWith(
      visualTrackVisible: visible,
      visualTrackExpanded: visible ? state.visualTrackExpanded : false,
    );
    await _engine.setVideoTrackEnabled(visible);
  }

  Future<void> setVisualTrackExpanded(bool expanded) async {
    AppLogger.log('MediaPlayback', 'visual track expanded=$expanded');
    if (expanded && !state.visualTrackVisible) {
      await setVisualTrackVisible(true);
    }
    state = state.copyWith(visualTrackExpanded: expanded);
  }

  Future<void> setVideoSubtitleVisible(bool visible) async {
    AppLogger.log('MediaPlayback', 'subtitle track visible=$visible');
    state = state.copyWith(videoSubtitleVisible: visible);
    await _engine.setSubtitleTrackData(visible ? _videoSubtitleSrt : null);
  }

  Future<String?> _loadSubtitleTrackData(AudioItem item) async {
    if (!item.hasTranscript) return null;
    try {
      final srt = await ref
          .read(audioItemDaoProvider)
          .getTranscriptSrt(item.id);
      if (srt != null && srt.trim().isNotEmpty) return srt;
    } catch (e) {
      AppLogger.log('MediaPlayback', '⚠ load video subtitle track failed: $e');
    }
    return null;
  }

  Future<void> handleLifecycleHidden() async {
    await _engine.setVideoTrackEnabled(false);
  }

  Future<void> handleLifecycleResumed() async {
    if (state.visualTrackVisible) await _engine.setVideoTrackEnabled(true);
  }

  /// 保存当前播放断点；自然播放完成时可显式写入 0，避免下次恢复到终点。
  Future<void> saveCurrentPlaybackState({
    bool silent = false,
    Duration? position,
  }) async {
    final item = state.audioItem;
    if (item == null) return;
    final dao = _playbackStateDaoCache;
    if (dao == null) return;
    await PlaybackStateStorage.savePlaybackState(
      item,
      position ?? state.position,
      ListeningPracticeState(playlistMode: state.playlistMode),
      dao: dao,
      silent: silent,
    );
  }

  /// 取消尚未完成的加载，不保存尚未开放给用户的临时播放位置。
  Future<void> cancelLoad() async {
    await _releaseMedia(saveProgress: false);
  }

  Future<void>? _releaseInFlight;

  Future<void> releaseFromScreen({int? studyPageGeneration}) async {
    if (studyPageGeneration != null) {
      final ended = await endStudyPage(studyPageGeneration);
      if (!ended) return;
    } else {
      await _endActiveStudyPage();
    }
    await _releaseMedia(saveProgress: _loadReady);
  }

  Future<void> _releaseMedia({required bool saveProgress}) async {
    final existing = _releaseInFlight;
    if (existing != null) {
      await existing;
      return;
    }
    final release = _releaseFromScreen(saveProgress: saveProgress);
    _releaseInFlight = release;
    try {
      await release;
    } finally {
      if (identical(_releaseInFlight, release)) {
        _releaseInFlight = null;
      }
    }
  }

  /// 统一释放页面拥有的媒体资源；加载取消与正常退出仅在断点保存上不同。
  Future<void> _releaseFromScreen({required bool saveProgress}) async {
    _loadGeneration++;
    _released = true;
    _loadReady = false;
    _loadedResourceGeneration = null;
    _positionUpdatesEnabled = false;
    _playbackGen++;
    _pauseAfterPosition = null;
    Object? releaseError;
    try {
      await _senseGroupRangePlayback?.cancel();
      _senseGroupRangePlayback = null;
      final engine = _engineCache;
      engine?.setTransportHandlers(onPlay: null, onPause: null);
      await _positionSub?.cancel();
      await _playingSub?.cancel();
      await _landscapeVideoSub?.cancel();
      await _videoAspectRatioSub?.cancel();
    } catch (error) {
      releaseError = error;
      AppLogger.log('MediaPlayback', 'release subscriptions failed: $error');
    }
    final engine = _engineCache;
    // 自然完成后 UI 可继续停在终点展示完成态，但持久化断点必须保持为开头；
    // 否则退出页面会用 state.position 的终点值覆盖刚写入的 0:00。持久化失败
    // 不能阻止 engine detach，否则页面 owner 已销毁而 native Player 仍在工作。
    if (saveProgress) {
      try {
        await saveCurrentPlaybackState(
          silent: true,
          position: _awaitingReplayFromStart ? Duration.zero : null,
        );
      } catch (error) {
        releaseError ??= error;
        AppLogger.log('MediaPlayback', 'release progress save failed: $error');
      }
    }
    try {
      await engine?.releaseFromScreen();
    } catch (error) {
      releaseError ??= error;
      AppLogger.log('MediaPlayback', 'release engine detach failed: $error');
    } finally {
      await _stopPlaying();
      state = const MediaPlaybackState();
    }
    final error = releaseError;
    if (error != null) throw error;
  }

  Future<void> _applyTransportSpeed() async {
    await _engine.setSpeed(state.settings.playbackSpeed);
  }

  Future<void> _alignEngineToCurrent() async {
    _playbackGen++;
    _activeSentenceDrivenPlayback = false;
    _awaitingReplayFromStart = false;
    _pauseAfterPosition = null;
    await _pausePlaying();
    state = state.copyWith(sentenceRepeatsDone: 0);
    final pos = _currentPos;
    if (pos != null && pos >= 0 && pos < _playable.length) {
      await _engine.seek(_playable[pos].startTime);
      state = state.copyWith(position: _playable[pos].startTime);
    }
    _playbackSessionId = _engine.currentSessionId;
  }

  bool _shouldRestartWhole() => _awaitingReplayFromStart || _isAtEnd();

  bool _isAtEnd() {
    final duration = state.duration;
    if (duration == null || duration <= Duration.zero) return false;
    return state.position >= duration - const Duration(milliseconds: 250);
  }

  Future<void> _restartFromPlayableBeginning() async {
    final playable = _playable;
    if (playable.isEmpty) {
      await _startWholeDriven(startAtBeginning: true, resetWholeLoops: true);
      return;
    }
    final first = playable.first;
    if (state.playlistMode == PlaylistMode.bookmarks) {
      state = state.copyWith(currentBookmarkIndex: first.index);
    } else {
      state = state.copyWith(currentFullIndex: first.index);
    }
    await _alignEngineToCurrent();
    await play();
  }

  Future<void> _startWholeDriven({
    int? startPos,
    Duration? resumePosition,
    bool startAtBeginning = false,
    bool resetWholeLoops = false,
  }) async {
    final gen = ++_playbackGen;
    final wasSentenceDriven = _activeSentenceDrivenPlayback;
    _activeSentenceDrivenPlayback = false;
    _awaitingReplayFromStart = false;
    if (resetWholeLoops) {
      state = state.copyWith(wholeLoopsDone: 0, sentenceRepeatsDone: 0);
    }
    _playbackSessionId = _engine.newSession();
    if (wasSentenceDriven) {
      // 区间播放可能仍在等待结束；先取消其迟到的 pause/完成回调，避免切换到整篇
      // 播放后旧协程把新的播放状态改回暂停。
      await _engine.cancelActiveRange(reason: 'switch-to-whole-playback');
    }
    AppLogger.log(
      'MediaPlayback',
      'start whole: gen=$gen session=$_playbackSessionId',
    );
    if (startAtBeginning) {
      await _engine.seek(Duration.zero);
      state = state.copyWith(position: Duration.zero);
    } else if (resumePosition != null) {
      await _engine.seek(resumePosition);
      state = state.copyWith(position: resumePosition);
    } else if (startPos != null && state.sentences.isNotEmpty) {
      final playable = _playable;
      if (startPos >= 0 && startPos < playable.length) {
        final target = playable[startPos];
        await _engine.seek(target.startTime);
        state = state.copyWith(position: target.startTime);
      }
    }
    _setPlaying(true);
    AppLogger.log(
      'MediaPlayback',
      'start whole playToEnd active=${_engine.isActiveSession(_playbackSessionId)}',
    );
    while (gen == _playbackGen && _engine.isActiveSession(_playbackSessionId)) {
      await _engine.playToEnd(_playbackSessionId);
      if (gen != _playbackGen || !_engine.isActiveSession(_playbackSessionId)) {
        return;
      }
      final done = state.wholeLoopsDone + 1;
      state = state.copyWith(wholeLoopsDone: done);
      final settings = state.settings;
      if (!shouldLoopWhole(settings.loopWhole, settings.wholeLoopCount, done)) {
        _awaitingReplayFromStart = true;
        await _stopPlaying();
        // 已自然播完时断点应回到开头，不能在退出后恢复为 -0:00 的终点状态。
        await saveCurrentPlaybackState(silent: true, position: Duration.zero);
        await _engine.pauseKeepSession();
        return;
      }
      _autoSaveProgress();
      await _delay(settings.wholeInterval);
      await _engine.seek(Duration.zero);
      state = state.copyWith(position: Duration.zero);
    }
  }

  /// 按播放位置查找最应该高亮的全文字幕。
  ///
  /// 播放器位置是唯一真实进度：命中字幕区间时高亮该句，落在无字幕空白区时只选择
  /// 距离最近的句子，不反向 seek 播放器，避免普通播放被字幕时间轴吸附。
  int _nearestSentenceIndex(Duration position) {
    final sentences = state.sentences;
    if (sentences.isEmpty) return -1;
    var bestIndex = sentences.first.index;
    var bestDistance = _distanceToSentence(position, sentences.first);
    for (final sentence in sentences.skip(1)) {
      final distance = _distanceToSentence(position, sentence);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = sentence.index;
      }
    }
    return bestIndex;
  }

  /// 书签模式下仅在书签句集合内查找最近焦点，播放进度本身不被吸附。
  int? _nearestBookmarkIndex(Duration position) {
    final bookmarks = state.bookmarkedSentences;
    if (bookmarks.isEmpty) return null;
    var best = bookmarks.first;
    var bestDistance = _distanceToSentence(position, best);
    for (final sentence in bookmarks.skip(1)) {
      final distance = _distanceToSentence(position, sentence);
      if (distance < bestDistance) {
        best = sentence;
        bestDistance = distance;
      }
    }
    return best.index;
  }

  Duration _distanceToSentence(Duration position, Sentence sentence) {
    if (position < sentence.startTime) return sentence.startTime - position;
    if (position > sentence.endTime) return position - sentence.endTime;
    return Duration.zero;
  }

  void _launchSentenceDriven({
    required bool resetWholeLoops,
    required bool resetSentenceRepeats,
  }) {
    final gen = ++_playbackGen;
    _activeSentenceDrivenPlayback = true;
    _awaitingReplayFromStart = false;
    _playbackSessionId = _engine.newSession();
    state = state.copyWith(
      wholeLoopsDone: resetWholeLoops ? 0 : state.wholeLoopsDone,
      sentenceRepeatsDone: resetSentenceRepeats ? 0 : state.sentenceRepeatsDone,
    );
    _setPlaying(true);
    unawaited(_playSentenceDriven(gen));
  }

  Future<void> _playSentenceDriven(int gen) async {
    var pos = _currentPos ?? 0;
    while (gen == _playbackGen) {
      final playable = _playable;
      if (playable.isEmpty || pos < 0 || pos >= playable.length) {
        await _stopPlaying();
        return;
      }
      final sentence = playable[pos];
      _setCurrentFromSentence(sentence);
      final result = await _engine.playRange(
        sentence.startTime,
        sentence.endTime,
        speed: state.settings.playbackSpeed,
        sessionId: _playbackSessionId,
      );
      if (gen != _playbackGen || result != SentencePlaybackResult.completed) {
        return;
      }
      _recordCompletedSentenceStatistics(sentence);
      if (_pauseAfterPosition != null) {
        await pause();
        return;
      }

      final repeats = state.sentenceRepeatsDone + 1;
      state = state.copyWith(sentenceRepeatsDone: repeats);

      final settings = state.settings;
      final action = decideNext(
        loopSentence: settings.loopSentence,
        sentenceLoopCount: settings.sentenceLoopCount,
        sentenceInterval: settings.sentenceInterval,
        loopWhole: settings.loopWhole,
        wholeLoopCount: settings.wholeLoopCount,
        wholeInterval: settings.wholeInterval,
        sentenceRepeatsDone: repeats,
        wholeLoopsDone: state.wholeLoopsDone,
        currentPos: pos,
        playableCount: playable.length,
      );
      switch (action) {
        case StopPlayback():
          _awaitingReplayFromStart = true;
          _activeSentenceDrivenPlayback = false;
          await _stopPlaying();
          // 单句驱动走到播放列表末尾同样属于自然完成，清除终点断点。
          await saveCurrentPlaybackState(silent: true, position: Duration.zero);
          await _engine.pauseKeepSession();
          return;
        case ReplayCurrent(:final pauseBefore):
          _autoSaveProgress();
          await _delay(pauseBefore);
        case GoToPosition(:final position, :final pauseBefore):
          final loopedWhole = pos >= playable.length - 1 && position == 0;
          await _delay(pauseBefore);
          pos = position;
          state = state.copyWith(
            sentenceRepeatsDone: 0,
            wholeLoopsDone: loopedWhole
                ? state.wholeLoopsDone + 1
                : state.wholeLoopsDone,
          );
          _autoSaveProgress();
      }
    }
  }

  /// 仅在按句区间播放自然完成后写入输入统计；连续整篇播放的总时长由计时器负责。
  ///
  /// 不等待后台数据库写入，避免统计延迟影响媒体播放、循环或切句。
  void _recordCompletedSentenceStatistics(Sentence sentence) {
    ref
        .read(studyTimeServiceProvider)
        .submitSentencePlayback(
          duration: sentence.duration,
          text: sentence.text,
          stage: StudyStage.freePlayer,
          recordInputDuration: false,
        );
  }

  void _setCurrentFromSentence(Sentence sentence) {
    if (state.playlistMode == PlaylistMode.bookmarks) {
      state = state.copyWith(
        currentBookmarkIndex: sentence.index,
        lastPlayedBookmarkIndex: sentence.index,
        position: sentence.startTime,
      );
      return;
    }
    state = state.copyWith(
      currentFullIndex: sentence.index,
      lastPlayedFullIndex: sentence.index,
      position: sentence.startTime,
    );
  }

  void _ensureValidIndex() {
    if (state.playlistMode == PlaylistMode.bookmarks) {
      final bookmarked = state.bookmarkedSentences;
      if (bookmarked.isEmpty) return;
      if (state.currentBookmarkIndex == null ||
          !state.bookmarkedIndices.contains(state.currentBookmarkIndex)) {
        state = state.copyWith(currentBookmarkIndex: bookmarked.first.index);
      }
      return;
    }
    if (state.sentences.isEmpty) return;
    final current = state.currentFullIndex;
    if (current == null || current < 0 || current >= state.sentences.length) {
      state = state.copyWith(currentFullIndex: 0);
    }
  }

  Future<void> _delay(Duration duration) async {
    if (duration <= Duration.zero) return;
    await Future.delayed(duration);
  }

  void _autoSaveProgress() {
    if (_autoSaving || state.audioItem == null) return;
    _autoSaving = true;
    saveCurrentPlaybackState(silent: true)
        .catchError(
          (Object e) =>
              AppLogger.log('MediaPlayback', '⚠ auto-save failed: $e'),
        )
        .whenComplete(() => _autoSaving = false);
  }
}
