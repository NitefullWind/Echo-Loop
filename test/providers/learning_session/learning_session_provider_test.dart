import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_loop/database/enums.dart';
import 'package:echo_loop/models/learning_progress.dart';
import 'package:echo_loop/models/audio_item.dart' as model;
import 'package:echo_loop/models/blind_listen_settings.dart';
import 'package:echo_loop/models/media_engine_state.dart';
import 'package:echo_loop/models/media_load_result.dart';
import 'package:echo_loop/providers/learning_session/learning_session_provider.dart';
import 'package:echo_loop/providers/learning_session/blind_listen_player_provider.dart';
import 'package:echo_loop/providers/learning_session/intensive_listen_player_provider.dart';
import 'package:echo_loop/providers/learning_session/paragraph_playback_driver.dart';
import 'package:echo_loop/providers/learning_session/review_difficult_practice_provider.dart';
import 'package:echo_loop/providers/learning_session/retell_player_provider.dart';
import 'package:echo_loop/providers/audio_engine/audio_engine_provider.dart';
import 'package:echo_loop/providers/media_engine/media_engine_provider.dart';
import 'package:echo_loop/providers/listening_practice/listening_practice_provider.dart';
import 'package:echo_loop/providers/learning_progress_provider.dart';
import 'package:echo_loop/providers/daily_study_time_provider.dart';
import 'package:echo_loop/models/playback_settings.dart';
import 'package:echo_loop/models/sentence.dart';
import 'package:echo_loop/database/providers.dart';
import 'package:echo_loop/database/daos/bookmark_dao.dart';
import 'package:echo_loop/database/app_database.dart';

import '../../helpers/mock_providers.dart';

/// 创建内存数据库（用于测试 StudyTimeService 依赖注入）
AppDatabase _createTestDb() {
  return AppDatabase(
    NativeDatabase.memory(
      setup: (db) => db.execute('PRAGMA foreign_keys = ON'),
    ),
  );
}

class _DaoFallbackLearningProgressNotifier
    extends TestLearningProgressNotifier {
  final LearningProgress? _dbProgress;

  _DaoFallbackLearningProgressNotifier(
    this._dbProgress, [
    LearningProgressState initialState = const LearningProgressState(),
  ]) : super(initialState);

  @override
  Future<LearningProgress?> getLatestByAudioId(String audioItemId) async {
    final persisted = _dbProgress;
    if (persisted != null) {
      final newMap = Map<String, LearningProgress>.from(state.progressMap);
      newMap[audioItemId] = persisted;
      state = state.copyWith(progressMap: newMap);
      return persisted;
    }
    return super.getLatestByAudioId(audioItemId);
  }

  @override
  Future<LearningProgress> ensureProgress(String audioItemId) async {
    final persisted = _dbProgress;
    if (persisted != null) {
      final newMap = Map<String, LearningProgress>.from(state.progressMap);
      newMap[audioItemId] = persisted;
      state = state.copyWith(progressMap: newMap);
      return persisted;
    }
    return super.ensureProgress(audioItemId);
  }

  @override
  Future<LearningProgress> getLatestOrEnsureProgress(String audioItemId) async {
    final latest = await getLatestByAudioId(audioItemId);
    if (latest != null) return latest;
    return ensureProgress(audioItemId);
  }
}

class _TestBookmarkDao implements BookmarkDao {
  final Set<int> bookmarkedIndices;

  _TestBookmarkDao(this.bookmarkedIndices);

  @override
  Future<Set<int>> getBookmarkedIndices(String audioItemId) async {
    return bookmarkedIndices;
  }

  @override
  Future<List<Bookmark>> getByAudioId(String audioItemId) async => [];

  @override
  Stream<List<Bookmark>> watchByAudioId(String audioItemId) =>
      Stream<List<Bookmark>>.value([]);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return Future<void>.value();
  }
}

/// 模拟视频文件加载失败，并记录失败后的独立媒体链路释放。
class _FailingMediaEngine extends MediaEngine {
  int releaseCalls = 0;

  @override
  MediaEngineState build() => const MediaEngineState();

  @override
  Future<Duration?> loadMedia(
    model.AudioItem item,
    double speed, {
    Duration initialPosition = Duration.zero,
  }) async => null;

  @override
  Future<void> releaseFromScreen() async {
    releaseCalls += 1;
  }
}

/// 用 Completer 控制媒体打开时机，验证退出后的迟到结果不会进入学习会话。
class _BlockingMediaEngine extends MediaEngine {
  final Completer<void> loadStarted = Completer<void>();
  final Completer<Duration?> loadResult = Completer<Duration?>();
  int releaseCalls = 0;

  @override
  MediaEngineState build() => const MediaEngineState();

  @override
  Future<Duration?> loadMedia(
    model.AudioItem item,
    double speed, {
    Duration initialPosition = Duration.zero,
  }) {
    loadStarted.complete();
    return loadResult.future;
  }

  @override
  Future<void> releaseFromScreen() async {
    releaseCalls += 1;
  }
}

/// 控制两次交叠媒体加载，验证旧请求不会释放新请求取得的会话。
class _OverlappingMediaEngine extends MediaEngine {
  final List<Completer<void>> loadStarted = [
    Completer<void>(),
    Completer<void>(),
  ];
  final List<Completer<Duration?>> loadResults = [
    Completer<Duration?>(),
    Completer<Duration?>(),
  ];
  int loadCalls = 0;
  int releaseCalls = 0;

  @override
  MediaEngineState build() => const MediaEngineState();

  @override
  Future<Duration?> loadMedia(
    model.AudioItem item,
    double speed, {
    Duration initialPosition = Duration.zero,
  }) {
    final callIndex = loadCalls++;
    loadStarted[callIndex].complete();
    return loadResults[callIndex].future;
  }

  @override
  Future<void> releaseFromScreen() async {
    releaseCalls += 1;
  }
}

class _SuccessfulMediaEngine extends MediaEngine {
  int subtitleClearCalls = 0;

  @override
  MediaEngineState build() => const MediaEngineState();

  @override
  Future<Duration?> loadMedia(
    model.AudioItem item,
    double speed, {
    Duration initialPosition = Duration.zero,
  }) async => const Duration(minutes: 1);

  @override
  Future<void> setSubtitleTrackData(String? srt) async {
    subtitleClearCalls += 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('LearningSessionState', () {
    test('初始状态 — 非学习模式', () {
      const state = LearningSessionState();

      expect(state.learningMode, isNull);
      expect(state.isInLearningMode, false);
      expect(state.blindListenCompleted, false);
      expect(state.blindListenPassCount, 0);
      expect(state.audioItemId, isNull);
      expect(state.savedSettings, isNull);
    });

    test('copyWith 设置盲听模式', () {
      const state = LearningSessionState();
      final updated = state.copyWith(
        learningMode: LearningMode.blindListen,
        audioItemId: 'audio-1',
        savedSettings: const PlaybackSettings(),
      );

      expect(updated.learningMode, LearningMode.blindListen);
      expect(updated.isInLearningMode, true);
      expect(updated.audioItemId, 'audio-1');
      expect(updated.savedSettings, isNotNull);
    });

    test('copyWith 标记完成 + 增加遍数', () {
      final state = const LearningSessionState().copyWith(
        learningMode: LearningMode.blindListen,
      );
      final completed = state.copyWith(
        blindListenCompleted: true,
        blindListenPassCount: 1,
      );

      expect(completed.blindListenCompleted, true);
      expect(completed.blindListenPassCount, 1);
    });

    test('copyWith clearLearningMode 清除模式', () {
      final state = const LearningSessionState().copyWith(
        learningMode: LearningMode.blindListen,
        audioItemId: 'audio-1',
      );
      final cleared = state.copyWith(clearLearningMode: true);

      expect(cleared.learningMode, isNull);
      expect(cleared.isInLearningMode, false);
      // audioItemId 保留
      expect(cleared.audioItemId, 'audio-1');
    });

    test('copyWith clearSavedSettings 清除保存的设置', () {
      final state = const LearningSessionState().copyWith(
        savedSettings: const PlaybackSettings(playbackSpeed: 1.5),
      );
      final cleared = state.copyWith(clearSavedSettings: true);

      expect(cleared.savedSettings, isNull);
    });

    test('copyWith clearAudioItemId 清除音频ID', () {
      final state = const LearningSessionState().copyWith(
        audioItemId: 'audio-1',
      );
      final cleared = state.copyWith(clearAudioItemId: true);

      expect(cleared.audioItemId, isNull);
    });

    test('copyWith 设置 / 清除自由练习补做目标 catchUp', () {
      final state = const LearningSessionState().copyWith(
        catchUpStage: LearningStage.firstLearn,
        catchUpSubStage: SubStageType.intensiveListen,
      );
      expect(state.catchUpStage, LearningStage.firstLearn);
      expect(state.catchUpSubStage, SubStageType.intensiveListen);

      final cleared = state.copyWith(clearCatchUp: true);
      expect(cleared.catchUpStage, isNull);
      expect(cleared.catchUpSubStage, isNull);
    });

    test('isFreePlay 默认为 false', () {
      const state = LearningSessionState();
      expect(state.isFreePlay, false);
    });

    test('copyWith 设置 isFreePlay', () {
      const state = LearningSessionState();
      final updated = state.copyWith(
        learningMode: LearningMode.blindListen,
        isFreePlay: true,
      );

      expect(updated.isFreePlay, true);
      expect(updated.learningMode, LearningMode.blindListen);
    });

    test('copyWith 保持 isFreePlay 不变', () {
      final state = const LearningSessionState().copyWith(isFreePlay: true);
      final updated = state.copyWith(blindListenCompleted: true);

      expect(updated.isFreePlay, true);
    });

    test('targetBlindListenPasses 默认为 1', () {
      const state = LearningSessionState();
      expect(state.targetBlindListenPasses, 1);
    });

    test('copyWith 设置 targetBlindListenPasses', () {
      const state = LearningSessionState();
      final updated = state.copyWith(targetBlindListenPasses: 3);
      expect(updated.targetBlindListenPasses, 3);
    });

    test('hasRemainingPasses — 遍数未达目标时返回 true', () {
      // blindListenPassCount=1, target=2 → 正在听第 1 遍，还没达目标
      final state = const LearningSessionState().copyWith(
        blindListenPassCount: 1,
        targetBlindListenPasses: 2,
      );
      expect(state.hasRemainingPasses, true);
    });

    test('hasRemainingPasses — 遍数达到目标时返回 false', () {
      // blindListenPassCount=2, target=2 → 正在听第 2 遍，达到目标
      final state = const LearningSessionState().copyWith(
        blindListenPassCount: 2,
        targetBlindListenPasses: 2,
      );
      expect(state.hasRemainingPasses, false);
    });

    test('hasRemainingPasses — 遍数超过目标时返回 false', () {
      // blindListenPassCount=3, target=2 → 用户选了"再听一遍"
      final state = const LearningSessionState().copyWith(
        blindListenPassCount: 3,
        targetBlindListenPasses: 2,
      );
      expect(state.hasRemainingPasses, false);
    });

    test('重置为初始状态', () {
      final state = const LearningSessionState().copyWith(
        learningMode: LearningMode.blindListen,
        blindListenCompleted: true,
        blindListenPassCount: 3,
        audioItemId: 'audio-1',
        savedSettings: const PlaybackSettings(),
      );

      // 创建全新的初始状态
      const resetState = LearningSessionState();
      expect(resetState.isInLearningMode, false);
      expect(resetState.blindListenCompleted, false);
      expect(resetState.blindListenPassCount, 0);

      // 原始 state 不变
      expect(state.isInLearningMode, true);
      expect(state.blindListenPassCount, 3);
    });
  });

  group('LearningMode', () {
    test('所有学习模式枚举存在', () {
      expect(LearningMode.blindListen, isNotNull);
      expect(LearningMode.intensiveListen, isNotNull);
      expect(LearningMode.listenAndRepeat, isNotNull);
      expect(LearningMode.retell, isNotNull);
      expect(LearningMode.reviewDifficultPractice, isNotNull);
      expect(LearningMode.values.length, 5);
    });
  });

  group('enterIntensiveListenMode 断点恢复', () {
    ProviderContainer createContainer(
      LearningProgressNotifier progressNotifier, {
      MediaEngine? mediaEngine,
      BookmarkDao? bookmarkDao,
    }) {
      return ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(_createTestDb()),
          audioEngineProvider.overrideWith(() => TestAudioEngine()),
          listeningPracticeProvider.overrideWith(() => TestListeningPractice()),
          learningProgressNotifierProvider.overrideWith(() => progressNotifier),
          intensiveListenPlayerProvider.overrideWith(
            () => TestIntensiveListenPlayer(),
          ),
          blindListenPlayerProvider.overrideWith(() => TestBlindListenPlayer()),
          dailyStudyTimeProvider.overrideWith(() => TestDailyStudyTime()),
          analyticsOverride(),
          if (bookmarkDao != null)
            bookmarkDaoProvider.overrideWithValue(bookmarkDao),
          if (mediaEngine != null)
            mediaEngineProvider.overrideWith(() => mediaEngine),
        ],
      );
    }

    final sentences = [
      Sentence(
        index: 0,
        text: 'First sentence',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 1),
      ),
      Sentence(
        index: 1,
        text: 'Second sentence',
        startTime: const Duration(seconds: 2),
        endTime: const Duration(seconds: 3),
      ),
      Sentence(
        index: 2,
        text: 'Third sentence',
        startTime: const Duration(seconds: 4),
        endTime: const Duration(seconds: 5),
      ),
    ];

    test('正常学习精听从头开始，忽略遗留断点', () async {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.firstLearn,
        currentSubStage: SubStageType.intensiveListen,
        intensiveListenSentenceIndex: 2,
        updatedAt: DateTime(2026, 3, 11),
      );
      final container = createContainer(
        TestLearningProgressNotifier(
          LearningProgressState(progressMap: {'audio-1': progress}),
        ),
      );
      addTearDown(container.dispose);

      await container
          .read(learningSessionProvider.notifier)
          .enterIntensiveListenMode('audio-1', sentences);

      final playerState = container.read(intensiveListenPlayerProvider);
      expect(playerState.currentSentenceIndex, 0);
    });

    test('视频加载失败时释放独立媒体链路且不进入学习模式', () async {
      final mediaEngine = _FailingMediaEngine();
      final container = createContainer(
        TestLearningProgressNotifier(),
        mediaEngine: mediaEngine,
      );
      addTearDown(container.dispose);

      final entered = await container
          .read(learningSessionProvider.notifier)
          .enterMediaIntensiveListenMode(
            model.AudioItem(
              id: 'video-1',
              name: 'Video',
              audioPath: 'video.mp4',
              addedDate: DateTime(2026, 7, 28),
            ),
            sentences,
          );

      expect(entered, MediaLoadResult.failure);
      expect(mediaEngine.releaseCalls, 1);
      expect(container.read(learningSessionProvider).isInLearningMode, isFalse);
    });

    test('视频精听用收藏快照初始化，不修改共享字幕句子', () async {
      final mediaEngine = _SuccessfulMediaEngine();
      final player = TestIntensiveListenPlayer();
      final videoSentences = List.generate(
        6,
        (index) => Sentence(
          index: index,
          text: 'Sentence $index',
          startTime: Duration(seconds: index * 2),
          endTime: Duration(seconds: index * 2 + 1),
        ),
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(_createTestDb()),
          audioEngineProvider.overrideWith(() => TestAudioEngine()),
          listeningPracticeProvider.overrideWith(() => TestListeningPractice()),
          learningProgressNotifierProvider.overrideWith(
            () => TestLearningProgressNotifier(),
          ),
          intensiveListenPlayerProvider.overrideWith(() => player),
          blindListenPlayerProvider.overrideWith(() => TestBlindListenPlayer()),
          dailyStudyTimeProvider.overrideWith(() => TestDailyStudyTime()),
          bookmarkDaoProvider.overrideWithValue(
            _TestBookmarkDao({0, 1, 2, 3, 4}),
          ),
          mediaEngineProvider.overrideWith(() => mediaEngine),
          analyticsOverride(),
        ],
      );
      addTearDown(container.dispose);

      final result = await container
          .read(learningSessionProvider.notifier)
          .enterMediaIntensiveListenMode(
            model.AudioItem(
              id: 'video-intense-bookmarks',
              name: 'Video',
              audioPath: 'video.mp4',
              addedDate: DateTime(2026, 8, 14),
            ),
            videoSentences,
          );

      expect(result, MediaLoadResult.ready);
      expect(player.sentences.map((sentence) => sentence.isBookmarked), [
        true,
        true,
        true,
        true,
        true,
        false,
      ]);
      expect(
        videoSentences.map((sentence) => sentence.isBookmarked),
        everyElement(isFalse),
      );
    });

    test('视频盲听用收藏快照初始化段落状态', () async {
      final player = TestBlindListenPlayer();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(_createTestDb()),
          audioEngineProvider.overrideWith(() => TestAudioEngine()),
          listeningPracticeProvider.overrideWith(() => TestListeningPractice()),
          learningProgressNotifierProvider.overrideWith(
            () => TestLearningProgressNotifier(),
          ),
          blindListenPlayerProvider.overrideWith(() => player),
          dailyStudyTimeProvider.overrideWith(() => TestDailyStudyTime()),
          bookmarkDaoProvider.overrideWithValue(_TestBookmarkDao({0, 2, 4})),
          mediaEngineProvider.overrideWith(() => _SuccessfulMediaEngine()),
          analyticsOverride(),
        ],
      );
      addTearDown(container.dispose);
      final videoSentences = List.generate(
        5,
        (index) => Sentence(
          index: index,
          text: 'Sentence $index',
          startTime: Duration(seconds: index * 2),
          endTime: Duration(seconds: index * 2 + 1),
        ),
      );

      final result = await container
          .read(learningSessionProvider.notifier)
          .enterMediaBlindListenMode(
            model.AudioItem(
              id: 'video-blind-bookmarks',
              name: 'Video',
              audioPath: 'video.mp4',
              addedDate: DateTime(2026, 8, 14),
            ),
            paragraphs: [
              videoSentences.sublist(0, 3),
              videoSentences.sublist(3),
            ],
            settings: const BlindListenSettings(),
          );

      expect(result, MediaLoadResult.ready);
      expect(player.state.bookmarkedSentenceIndices, {0, 2, 4});
      expect(
        videoSentences.map((sentence) => sentence.isBookmarked),
        everyElement(isFalse),
      );
    });

    test('视频加载中取消后迟到成功被丢弃并释放媒体链路', () async {
      final mediaEngine = _BlockingMediaEngine();
      final container = createContainer(
        TestLearningProgressNotifier(),
        mediaEngine: mediaEngine,
      );
      addTearDown(container.dispose);
      final session = container.read(learningSessionProvider.notifier);

      final entry = session.enterMediaIntensiveListenMode(
        model.AudioItem(
          id: 'video-cancelled',
          name: 'Video',
          audioPath: 'video.mp4',
          addedDate: DateTime(2026, 7, 29),
        ),
        sentences,
      );
      await mediaEngine.loadStarted.future;

      await session.cancelMediaIntensiveListenEntry();
      mediaEngine.loadResult.complete(const Duration(minutes: 1));

      expect(await entry, MediaLoadResult.cancelled);
      expect(mediaEngine.releaseCalls, 1);
      expect(container.read(learningSessionProvider).isInLearningMode, isFalse);
    });

    test('视频盲听旧加载不能释放后一次进入的媒体会话', () async {
      final mediaEngine = _OverlappingMediaEngine();
      final container = createContainer(
        TestLearningProgressNotifier(),
        mediaEngine: mediaEngine,
      );
      addTearDown(container.dispose);
      final session = container.read(learningSessionProvider.notifier);
      final firstItem = model.AudioItem(
        id: 'video-blind-first',
        name: 'First video',
        audioPath: 'first.mp4',
        addedDate: DateTime(2026, 8, 14),
      );
      final secondItem = model.AudioItem(
        id: 'video-blind-second',
        name: 'Second video',
        audioPath: 'second.mp4',
        addedDate: DateTime(2026, 8, 14),
      );

      final firstEntry = session.enterMediaBlindListenMode(
        firstItem,
        paragraphs: [sentences],
        settings: const BlindListenSettings(),
      );
      await mediaEngine.loadStarted[0].future;

      final secondEntry = session.enterMediaBlindListenMode(
        secondItem,
        paragraphs: [sentences],
        settings: const BlindListenSettings(),
      );
      await mediaEngine.loadStarted[1].future;
      mediaEngine.loadResults[1].complete(const Duration(minutes: 1));

      expect(await secondEntry, MediaLoadResult.ready);
      mediaEngine.loadResults[0].complete(const Duration(minutes: 1));

      expect(await firstEntry, MediaLoadResult.cancelled);
      expect(mediaEngine.releaseCalls, 0);
      expect(
        container.read(learningSessionProvider).audioItemId,
        secondItem.id,
      );
    });

    test('自由练习精听恢复已保存断点', () async {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.firstLearn,
        currentSubStage: SubStageType.intensiveListen,
        freePlayIntensiveListenSentenceIndex: 2,
        freePlayBreakpointSavedAt: DateTime.now(),
        updatedAt: DateTime(2026, 3, 11),
      );
      final container = createContainer(
        TestLearningProgressNotifier(
          LearningProgressState(progressMap: {'audio-1': progress}),
        ),
      );
      addTearDown(container.dispose);

      await container
          .read(learningSessionProvider.notifier)
          .enterIntensiveListenMode('audio-1', sentences, isFreePlay: true);

      final playerState = container.read(intensiveListenPlayerProvider);
      expect(playerState.currentSentenceIndex, 2);
    });

    test('自由练习内存缺失时也能通过 DB 断点恢复', () async {
      final dbProgress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.firstLearn,
        currentSubStage: SubStageType.intensiveListen,
        freePlayIntensiveListenSentenceIndex: 1,
        freePlayBreakpointSavedAt: DateTime.now(),
        updatedAt: DateTime(2026, 3, 11),
      );
      final container = createContainer(
        _DaoFallbackLearningProgressNotifier(dbProgress),
      );
      addTearDown(container.dispose);

      await container
          .read(learningSessionProvider.notifier)
          .enterIntensiveListenMode('audio-1', sentences, isFreePlay: true);

      final playerState = container.read(intensiveListenPlayerProvider);
      expect(playerState.currentSentenceIndex, 1);
    });

    test('自由练习内存旧于数据库时优先使用数据库最新精听断点', () async {
      final stale = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.firstLearn,
        currentSubStage: SubStageType.intensiveListen,
        freePlayIntensiveListenSentenceIndex: 0,
        freePlayBreakpointSavedAt: DateTime.now().subtract(
          const Duration(hours: 1),
        ),
        updatedAt: DateTime(2026, 3, 11, 9),
      );
      final latest = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.firstLearn,
        currentSubStage: SubStageType.intensiveListen,
        freePlayIntensiveListenSentenceIndex: 2,
        freePlayBreakpointSavedAt: DateTime.now(),
        updatedAt: DateTime(2026, 3, 11, 10),
      );
      final container = createContainer(
        _DaoFallbackLearningProgressNotifier(
          latest,
          LearningProgressState(progressMap: {'audio-1': stale}),
        ),
      );
      addTearDown(container.dispose);

      await container
          .read(learningSessionProvider.notifier)
          .enterIntensiveListenMode('audio-1', sentences, isFreePlay: true);

      final playerState = container.read(intensiveListenPlayerProvider);
      expect(playerState.currentSentenceIndex, 2);
    });
  });

  group('LearningSession App 生命周期计时', () {
    late ProviderContainer container;

    /// 创建带有所有依赖 override 的 ProviderContainer
    ProviderContainer createContainer() {
      final c = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(_createTestDb()),
          audioEngineProvider.overrideWith(() => TestAudioEngine()),
          listeningPracticeProvider.overrideWith(() => TestListeningPractice()),
          learningProgressNotifierProvider.overrideWith(
            () => TestLearningProgressNotifier(),
          ),
          blindListenPlayerProvider.overrideWith(() => TestBlindListenPlayer()),
          dailyStudyTimeProvider.overrideWith(() => TestDailyStudyTime()),
          analyticsOverride(),
        ],
      );
      return c;
    }

    /// 获取 LearningSession notifier
    LearningSession session(ProviderContainer c) =>
        c.read(learningSessionProvider.notifier);

    tearDown(() => container.dispose());

    test('盲听使用页面级计时器，不启动 LearningSession 旧计时器', () async {
      container = createContainer();
      final s = session(container);

      await s.enterBlindListenMode('audio-1', paragraphs: const []);
    });
  });

  group('其他学习模式断点恢复', () {
    final sentences = [
      Sentence(
        index: 0,
        text: 'First sentence',
        startTime: Duration.zero,
        endTime: const Duration(seconds: 1),
      ),
      Sentence(
        index: 1,
        text: 'Second sentence',
        startTime: const Duration(seconds: 2),
        endTime: const Duration(seconds: 3),
      ),
      Sentence(
        index: 2,
        text: 'Third sentence',
        startTime: const Duration(seconds: 4),
        endTime: const Duration(seconds: 5),
      ),
      Sentence(
        index: 3,
        text: 'Fourth sentence',
        startTime: const Duration(seconds: 6),
        endTime: const Duration(seconds: 7),
      ),
    ];

    ProviderContainer createContainer(
      LearningProgressNotifier progressNotifier, {
      MediaEngine? mediaEngine,
    }) {
      return ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(_createTestDb()),
          audioEngineProvider.overrideWith(() => TestAudioEngine()),
          listeningPracticeProvider.overrideWith(() => TestListeningPractice()),
          learningProgressNotifierProvider.overrideWith(() => progressNotifier),
          reviewDifficultPracticeProvider.overrideWith(
            () => TestReviewDifficultPractice(),
          ),
          retellPlayerProvider.overrideWith(() => TestRetellPlayer()),
          blindListenPlayerProvider.overrideWith(() => TestBlindListenPlayer()),
          dailyStudyTimeProvider.overrideWith(() => TestDailyStudyTime()),
          bookmarkDaoProvider.overrideWithValue(_TestBookmarkDao({1, 3})),
          analyticsOverride(),
          if (mediaEngine != null)
            mediaEngineProvider.overrideWith(() => mediaEngine),
        ],
      );
    }

    // TODO: 旧 ListenAndRepeatPlayer / PlaybackPhase 已删除，需要基于新播放器重写
    test('跟读正常学习从头开始，忽略遗留断点', skip: '需要基于新播放器重写', () async {});

    // TODO: 旧 ListenAndRepeatPlayer / PlaybackPhase 已删除，需要基于新播放器重写
    test('跟读自由练习恢复已保存句子断点', skip: '需要基于新播放器重写', () async {});

    test('难句补练正常学习从头开始，忽略遗留断点', () async {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review1,
        currentSubStage: SubStageType.reviewDifficultPractice,
        difficultPracticeSentenceIndex: 1,
        updatedAt: DateTime(2026, 3, 11),
      );
      final container = createContainer(
        TestLearningProgressNotifier(
          LearningProgressState(progressMap: {'audio-1': progress}),
        ),
      );
      addTearDown(container.dispose);

      await container
          .read(learningSessionProvider.notifier)
          .enterReviewDifficultPracticeMode('audio-1', sentences);

      final playerState = container.read(reviewDifficultPracticeProvider);
      expect(playerState.currentSentenceIndex, 0);
    });

    test('难句补练自由练习恢复已保存句子断点', () async {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review1,
        currentSubStage: SubStageType.reviewDifficultPractice,
        freePlayDifficultPracticeSentenceIndex: 1,
        freePlayBreakpointSavedAt: DateTime.now(),
        updatedAt: DateTime(2026, 3, 11),
      );
      final container = createContainer(
        TestLearningProgressNotifier(
          LearningProgressState(progressMap: {'audio-1': progress}),
        ),
      );
      addTearDown(container.dispose);

      await container
          .read(learningSessionProvider.notifier)
          .enterReviewDifficultPracticeMode(
            'audio-1',
            sentences,
            isFreePlay: true,
          );

      final playerState = container.read(reviewDifficultPracticeProvider);
      expect(playerState.currentSentenceIndex, 1);
    });

    test('视频难句补练加载成功后使用独立媒体链路和共享播放器状态', () async {
      final mediaEngine = _SuccessfulMediaEngine();
      final container = createContainer(
        TestLearningProgressNotifier(),
        mediaEngine: mediaEngine,
      );
      addTearDown(container.dispose);

      final result = await container
          .read(learningSessionProvider.notifier)
          .enterMediaReviewDifficultPracticeMode(
            model.AudioItem(
              id: 'video-review',
              name: 'Video review',
              audioPath: 'video.mp4',
              addedDate: DateTime(2026, 8, 11),
            ),
            sentences,
          );

      expect(result, MediaLoadResult.ready);
      expect(
        container.read(learningSessionProvider).playbackChain,
        LearningPlaybackChain.media,
      );
      final playerState = container.read(reviewDifficultPracticeProvider);
      expect(playerState.usesMediaEngine, isTrue);
      expect(playerState.totalSentences, 2);
      expect(
        container
            .read(reviewDifficultPracticeProvider.notifier)
            .sentences
            .every((sentence) => sentence.isBookmarked),
        isTrue,
      );
      expect(mediaEngine.subtitleClearCalls, 1);
    });

    test('视频难句补练加载失败时释放媒体且不进入学习模式', () async {
      final mediaEngine = _FailingMediaEngine();
      final container = createContainer(
        TestLearningProgressNotifier(),
        mediaEngine: mediaEngine,
      );
      addTearDown(container.dispose);

      final result = await container
          .read(learningSessionProvider.notifier)
          .enterMediaReviewDifficultPracticeMode(
            model.AudioItem(
              id: 'video-review-failure',
              name: 'Video review',
              audioPath: 'video.mp4',
              addedDate: DateTime(2026, 8, 11),
            ),
            sentences,
          );

      expect(result, MediaLoadResult.failure);
      expect(mediaEngine.releaseCalls, 1);
      expect(container.read(learningSessionProvider).isInLearningMode, isFalse);
    });

    test('视频难句补练加载中取消会丢弃迟到结果并释放媒体', () async {
      final mediaEngine = _BlockingMediaEngine();
      final container = createContainer(
        TestLearningProgressNotifier(),
        mediaEngine: mediaEngine,
      );
      addTearDown(container.dispose);
      final session = container.read(learningSessionProvider.notifier);

      final entry = session.enterMediaReviewDifficultPracticeMode(
        model.AudioItem(
          id: 'video-review-cancelled',
          name: 'Video review',
          audioPath: 'video.mp4',
          addedDate: DateTime(2026, 8, 11),
        ),
        sentences,
      );
      await mediaEngine.loadStarted.future;

      await session.cancelMediaReviewDifficultPracticeEntry();
      mediaEngine.loadResult.complete(const Duration(minutes: 1));

      expect(await entry, MediaLoadResult.cancelled);
      expect(mediaEngine.releaseCalls, 1);
      expect(container.read(learningSessionProvider).isInLearningMode, isFalse);
    });

    test('复述正常学习从头开始，忽略遗留断点', () async {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.firstLearn,
        currentSubStage: SubStageType.retell,
        retellSentenceIndex: 2,
        updatedAt: DateTime(2026, 3, 11),
      );
      final paragraphs = [
        [sentences[0], sentences[1]],
        [sentences[2], sentences[3]],
      ];
      final container = createContainer(
        TestLearningProgressNotifier(
          LearningProgressState(progressMap: {'audio-1': progress}),
        ),
      );
      addTearDown(container.dispose);

      await container
          .read(learningSessionProvider.notifier)
          .enterRetellMode('audio-1', paragraphs);

      final playerState = container.read(retellPlayerProvider);
      expect(playerState.currentParagraphIndex, 0);
    });

    test('复述自由练习恢复段首句断点', () async {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.firstLearn,
        currentSubStage: SubStageType.retell,
        freePlayRetellSentenceIndex: 2,
        freePlayBreakpointSavedAt: DateTime.now(),
        updatedAt: DateTime(2026, 3, 11),
      );
      final paragraphs = [
        [sentences[0], sentences[1]],
        [sentences[2], sentences[3]],
      ];
      final container = createContainer(
        TestLearningProgressNotifier(
          LearningProgressState(progressMap: {'audio-1': progress}),
        ),
      );
      addTearDown(container.dispose);

      await container
          .read(learningSessionProvider.notifier)
          .enterRetellMode('audio-1', paragraphs, isFreePlay: true);

      final playerState = container.read(retellPlayerProvider);
      expect(playerState.currentParagraphIndex, 1);
    });

    test('视频复述进入媒体链路并复用段落播放驱动与自由练习断点', () async {
      final progress = LearningProgress(
        audioItemId: 'video-retell',
        currentStage: LearningStage.review1,
        currentSubStage: SubStageType.retell,
        freePlayRetellSentenceIndex: 2,
        freePlayBreakpointSavedAt: DateTime.now(),
        updatedAt: DateTime(2026, 8, 11),
      );
      final mediaEngine = _SuccessfulMediaEngine();
      final player = TestRetellPlayer();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(_createTestDb()),
          audioEngineProvider.overrideWith(() => TestAudioEngine()),
          listeningPracticeProvider.overrideWith(() => TestListeningPractice()),
          learningProgressNotifierProvider.overrideWith(
            () => TestLearningProgressNotifier(
              LearningProgressState(progressMap: {'video-retell': progress}),
            ),
          ),
          retellPlayerProvider.overrideWith(() => player),
          blindListenPlayerProvider.overrideWith(() => TestBlindListenPlayer()),
          dailyStudyTimeProvider.overrideWith(() => TestDailyStudyTime()),
          bookmarkDaoProvider.overrideWithValue(_TestBookmarkDao({0, 2})),
          mediaEngineProvider.overrideWith(() => mediaEngine),
          analyticsOverride(),
        ],
      );
      addTearDown(container.dispose);
      final paragraphs = [
        [sentences[0], sentences[1]],
        [sentences[2], sentences[3]],
      ];

      final result = await container
          .read(learningSessionProvider.notifier)
          .enterMediaRetellMode(
            model.AudioItem(
              id: 'video-retell',
              name: 'Video retell',
              audioPath: 'video.mp4',
              addedDate: DateTime(2026, 8, 11),
            ),
            paragraphs,
            isFreePlay: true,
          );

      expect(result, MediaLoadResult.ready);
      expect(
        container.read(learningSessionProvider).playbackChain,
        LearningPlaybackChain.media,
      );
      expect(container.read(retellPlayerProvider).currentParagraphIndex, 1);
      expect(
        player.testParagraphs
            .expand((paragraph) => paragraph)
            .map((sentence) => sentence.isBookmarked),
        [true, false, true, false],
      );
      expect(
        sentences.map((sentence) => sentence.isBookmarked),
        everyElement(isFalse),
      );
      expect(player.lastPlaybackDriver, isA<MediaParagraphPlaybackDriver>());
      expect(mediaEngine.subtitleClearCalls, 1);
    });

    test('视频复述加载失败不进入会话，取消后迟到成功也被丢弃', () async {
      final failedEngine = _FailingMediaEngine();
      final failedContainer = createContainer(
        TestLearningProgressNotifier(),
        mediaEngine: failedEngine,
      );
      addTearDown(failedContainer.dispose);
      final item = model.AudioItem(
        id: 'video-retell-failure',
        name: 'Video',
        audioPath: 'video.mp4',
        addedDate: DateTime(2026, 8, 11),
      );

      expect(
        await failedContainer
            .read(learningSessionProvider.notifier)
            .enterMediaRetellMode(item, [sentences]),
        MediaLoadResult.failure,
      );
      expect(failedEngine.releaseCalls, 1);
      expect(
        failedContainer.read(learningSessionProvider).isInLearningMode,
        isFalse,
      );

      final blockingEngine = _BlockingMediaEngine();
      final cancelledContainer = createContainer(
        TestLearningProgressNotifier(),
        mediaEngine: blockingEngine,
      );
      addTearDown(cancelledContainer.dispose);
      final session = cancelledContainer.read(learningSessionProvider.notifier);
      final entry = session.enterMediaRetellMode(item, [sentences]);
      await blockingEngine.loadStarted.future;
      await session.cancelMediaRetellEntry();
      blockingEngine.loadResult.complete(const Duration(minutes: 1));

      expect(await entry, MediaLoadResult.cancelled);
      expect(blockingEngine.releaseCalls, 1);
      expect(
        cancelledContainer.read(learningSessionProvider).isInLearningMode,
        isFalse,
      );
    });

    // TODO: 旧 ListenAndRepeatPlayer 已删除，需要基于新播放器重写
    test('冷启动自由练习时也能从 DB 断点恢复跟读/补练/复述', skip: '需要基于新播放器重写', () async {});

    // TODO: 旧 ListenAndRepeatPlayer 已删除，需要基于新播放器重写
    test('自由练习进入时优先使用数据库最新断点覆盖旧内存', skip: '需要基于新播放器重写', () async {});
  });
}
