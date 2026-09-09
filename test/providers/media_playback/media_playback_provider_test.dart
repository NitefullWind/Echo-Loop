import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart' hide PlaybackState;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:echo_loop/database/app_database.dart' hide AudioItem;
import 'package:echo_loop/database/daos/playback_state_dao.dart';
import 'package:echo_loop/models/audio_item.dart';
import 'package:echo_loop/models/listening_practice_state.dart';
import 'package:echo_loop/models/media_load_result.dart';
import 'package:echo_loop/models/sentence.dart';
import 'package:echo_loop/models/study_stage.dart';
import 'package:echo_loop/database/providers.dart';
import 'package:echo_loop/providers/audio_engine/audio_engine_provider.dart';
import 'package:echo_loop/providers/learned_vocabulary_tracker_provider.dart';
import 'package:echo_loop/providers/media_engine/media_engine_provider.dart';
import 'package:echo_loop/providers/media_playback/media_playback_provider.dart';
import 'package:echo_loop/services/media_session_router.dart';
import 'package:echo_loop/utils/app_data_dir.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/mock_providers.dart';
import '../../helpers/shared/fake_media_player_backend.dart';

void main() {
  late Directory appDir;
  late File mediaFile;
  late FakeMediaPlayerBackend backend;
  late FakeAudioItemDao audioItemDao;
  late FakeBookmarkDao bookmarkDao;
  late _MockPlaybackStateDao playbackStateDao;
  late MediaSessionRouter router;
  late ProviderContainer container;
  late AppDatabase database;

  final sentences = <Sentence>[
    Sentence(
      index: 0,
      text: 'First sentence.',
      startTime: const Duration(seconds: 43),
      endTime: const Duration(seconds: 50),
    ),
    Sentence(
      index: 1,
      text: 'Second sentence.',
      startTime: const Duration(seconds: 60),
      endTime: const Duration(seconds: 70),
    ),
    Sentence(
      index: 2,
      text: 'Third sentence.',
      startTime: const Duration(seconds: 80),
      endTime: const Duration(seconds: 90),
    ),
    Sentence(
      index: 3,
      text: 'Fourth sentence.',
      startTime: const Duration(seconds: 100),
      endTime: const Duration(seconds: 110),
    ),
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    appDir = await Directory.systemTemp.createTemp('echo-loop-media-playback-');
    appDataDirectoryOverride = appDir;
    mediaFile = File('${appDir.path}/echo-loop-media-playback.mp4');
    await mediaFile.writeAsBytes(const [0, 1, 2]);
    backend = FakeMediaPlayerBackend()
      ..setDuration(const Duration(seconds: 120));
    audioItemDao = FakeAudioItemDao()
      ..transcriptSrtStore['media-playback-test'] =
          '1\n00:00:43,000 --> 00:00:50,000\nFirst sentence.\n';
    bookmarkDao = FakeBookmarkDao();
    playbackStateDao = _MockPlaybackStateDao();
    database = AppDatabase(NativeDatabase.memory());
    when(
      () => playbackStateDao.getByAudioId(any()),
    ).thenAnswer((_) async => null);
    router = MediaSessionRouter(defaultHandler: BaseAudioHandler());
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        mediaBackendFactoryProvider.overrideWithValue(() => backend),
        mediaSessionRouterProvider.overrideWithValue(router),
        audioItemDaoProvider.overrideWithValue(audioItemDao),
        bookmarkDaoProvider.overrideWithValue(bookmarkDao),
        playbackStateDaoProvider.overrideWithValue(playbackStateDao),
        audioEngineProvider.overrideWith(
          () => _TranscriptAudioEngine(sentences),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    appDataDirectoryOverride = null;
    if (await appDir.exists()) await appDir.delete(recursive: true);
  });

  AudioItem item() => AudioItem(
    id: 'media-playback-test',
    name: 'Media Playback Test',
    audioPath: mediaFile.uri.pathSegments.last,
    addedDate: DateTime(2026, 7, 25),
    transcriptSource: TranscriptSource.local,
  );

  Future<MediaPlayback> loadController() async {
    final controller = container.read(mediaPlaybackProvider.notifier);
    await controller.load(item());
    await Future<void>.delayed(Duration.zero);
    return controller;
  }

  Future<void> waitForSentenceStatistics({int minimumWords = 2}) async {
    for (var attempt = 0; attempt < 20; attempt += 1) {
      final record = await database.dailyStudyRecordDao.getByDate(
        DateTime.now(),
      );
      if ((record?.inputWords ?? 0) >= minimumWords) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('Timed out waiting for asynchronous sentence statistics write.');
  }

  Future<void> waitForStudyDuration() async {
    for (var attempt = 0; attempt < 20; attempt += 1) {
      final record = await database.dailyStudyRecordDao.getByDate(
        DateTime.now(),
      );
      if ((record?.studyTimeMilliseconds ?? 0) >= 1000) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('Timed out waiting for the asynchronous study duration write.');
  }

  test('打开媒体前预读断点并作为 backend 初始位置', () async {
    when(() => playbackStateDao.getByAudioId('media-playback-test')).thenAnswer(
      (_) async => PlaybackState(
        audioItemId: 'media-playback-test',
        positionMs: 26000,
        playlistMode: PlaylistMode.full.index,
        savedAt: DateTime(2026, 7, 27),
      ),
    );

    await loadController();

    expect(backend.openInitialPositions, [const Duration(seconds: 26)]);
    expect(
      container.read(mediaPlaybackProvider).position,
      const Duration(seconds: 26),
    );
    expect(backend.seekCalls, isEmpty);
  });

  test('收藏模式恢复时焦点与断点所在收藏句一致', () async {
    await bookmarkDao.addBookmark(
      const BookmarksCompanion(
        audioItemId: Value('media-playback-test'),
        sentenceIndex: Value(0),
      ),
    );
    await bookmarkDao.addBookmark(
      const BookmarksCompanion(
        audioItemId: Value('media-playback-test'),
        sentenceIndex: Value(2),
      ),
    );
    when(() => playbackStateDao.getByAudioId('media-playback-test')).thenAnswer(
      (_) async => PlaybackState(
        audioItemId: 'media-playback-test',
        positionMs: const Duration(seconds: 80).inMilliseconds,
        playlistMode: PlaylistMode.bookmarks.index,
        savedAt: DateTime(2026, 8, 3),
      ),
    );

    await loadController();

    final state = container.read(mediaPlaybackProvider);
    expect(backend.openInitialPositions, [const Duration(seconds: 80)]);
    expect(backend.seekCalls, isEmpty);
    expect(state.position, const Duration(seconds: 80));
    expect(state.playlistMode, PlaylistMode.bookmarks);
    expect(state.currentFullIndex, 2);
    expect(state.currentBookmarkIndex, 2);
  });

  test('加载失败后可对同一媒体真正重试并成功', () async {
    backend
      ..closeStreamsOnDispose = false
      ..openError = StateError('open failed');
    final controller = container.read(mediaPlaybackProvider.notifier);

    expect(await controller.load(item()), MediaLoadResult.failure);
    expect(container.read(mediaPlaybackProvider).errorMessage, isNotNull);

    backend.openError = null;
    expect(await controller.load(item()), MediaLoadResult.ready);

    final state = container.read(mediaPlaybackProvider);
    expect(state.errorMessage, isNull);
    expect(state.duration, const Duration(seconds: 120));
    expect(backend.openCalls, hasLength(1));
  });

  test('加载中取消会忽略迟到结果且不保存临时断点', () async {
    final restoreCompleter = Completer<PlaybackState?>();
    when(
      () => playbackStateDao.getByAudioId('media-playback-test'),
    ).thenAnswer((_) => restoreCompleter.future);
    final controller = container.read(mediaPlaybackProvider.notifier);
    final loadFuture = controller.load(item());
    await waitUntil(() => container.read(mediaPlaybackProvider).isLoading);

    await controller.cancelLoad();
    restoreCompleter.complete(
      PlaybackState(
        audioItemId: 'media-playback-test',
        positionMs: 26000,
        playlistMode: PlaylistMode.full.index,
        savedAt: DateTime(2026, 7, 29),
      ),
    );

    expect(await loadFuture, MediaLoadResult.cancelled);
    await Future<void>.delayed(Duration.zero);
    final state = container.read(mediaPlaybackProvider);
    expect(state.audioItem, isNull);
    expect(state.position, Duration.zero);
    expect(playbackStateDao.savedPositions, isEmpty);
  });

  test('点击讲解前选中并暂停目标句，返回后同步收藏并复位媒体位置', () async {
    final controller = await loadController();
    unawaited(controller.play());
    await Future<void>.delayed(Duration.zero);

    await controller.prepareSentenceDetail(1);

    var state = container.read(mediaPlaybackProvider);
    expect(state.currentFullIndex, 1);
    expect(state.position, const Duration(seconds: 60));
    expect(state.isPlaying, isFalse);
    expect(backend.pauseCalls, 1);

    await bookmarkDao.addBookmark(
      const BookmarksCompanion(
        audioItemId: Value('media-playback-test'),
        sentenceIndex: Value(1),
      ),
    );
    await controller.restoreAfterSentenceDetail();

    state = container.read(mediaPlaybackProvider);
    expect(state.bookmarkedIndices, {1});
    expect(state.sentences[1].isBookmarked, isTrue);
    expect(state.currentFullIndex, 1);
    expect(state.position, const Duration(seconds: 60));
    expect(backend.seekCalls.last, const Duration(seconds: 60));
  });

  test('空收藏不进入收藏模式，也不触发暂停和对齐', () async {
    final controller = await loadController();
    final pauseCallsBefore = backend.pauseCalls;
    final seekCallsBefore = List<Duration>.of(backend.seekCalls);

    await controller.setPlaylistMode(PlaylistMode.bookmarks);

    expect(
      container.read(mediaPlaybackProvider).playlistMode,
      PlaylistMode.full,
    );
    expect(backend.pauseCalls, pauseCallsBefore);
    expect(backend.seekCalls, seekCallsBefore);
  });

  test('收藏模式取消最后一条后回全文并保持当前句', () async {
    await bookmarkDao.addBookmark(
      const BookmarksCompanion(
        audioItemId: Value('media-playback-test'),
        sentenceIndex: Value(1),
      ),
    );
    final controller = await loadController();
    await controller.setPlaylistMode(PlaylistMode.bookmarks);

    await controller.toggleBookmark(1);

    final state = container.read(mediaPlaybackProvider);
    expect(state.playlistMode, PlaylistMode.full);
    expect(state.currentFullIndex, 1);
    expect(state.currentBookmarkIndex, isNull);
    expect(state.bookmarkedSentences, isEmpty);
    expect(state.isPlaying, isFalse);
  });

  test('四条收藏连续取消倒数第二条和最后一条后回退到前一条', () async {
    for (var index = 0; index < sentences.length; index += 1) {
      await bookmarkDao.addBookmark(
        BookmarksCompanion(
          audioItemId: const Value('media-playback-test'),
          sentenceIndex: Value(index),
        ),
      );
    }
    final controller = await loadController();
    await controller.setPlaylistMode(PlaylistMode.bookmarks);
    await controller.selectBookmarkedSentence(2, autoPlay: false);

    await controller.toggleBookmark(2);
    expect(container.read(mediaPlaybackProvider).currentBookmarkIndex, 3);

    await controller.toggleBookmark(3);

    final state = container.read(mediaPlaybackProvider);
    expect(state.playlistMode, PlaylistMode.bookmarks);
    expect(state.bookmarkedIndices, {0, 1});
    expect(state.currentBookmarkIndex, 1);
  });

  test('讲解页返回时收藏已清空则回全文并保持原句', () async {
    await bookmarkDao.addBookmark(
      const BookmarksCompanion(
        audioItemId: Value('media-playback-test'),
        sentenceIndex: Value(1),
      ),
    );
    final controller = await loadController();
    await controller.setPlaylistMode(PlaylistMode.bookmarks);
    await bookmarkDao.removeBookmark('media-playback-test', 1);

    await controller.restoreAfterSentenceDetail();

    final state = container.read(mediaPlaybackProvider);
    expect(state.playlistMode, PlaylistMode.full);
    expect(state.currentFullIndex, 1);
    expect(state.currentBookmarkIndex, isNull);
    expect(state.bookmarkedSentences, isEmpty);
  });

  test('快速重复切换只执行一次暂停和位置对齐', () async {
    await bookmarkDao.addBookmark(
      const BookmarksCompanion(
        audioItemId: Value('media-playback-test'),
        sentenceIndex: Value(0),
      ),
    );
    final controller = await loadController();
    backend.pauseDelay = const Duration(milliseconds: 40);
    final pauseCallsBefore = backend.pauseCalls;
    final seekCallsBefore = backend.seekCalls.length;

    await Future.wait([
      controller.setPlaylistMode(PlaylistMode.bookmarks),
      controller.setPlaylistMode(PlaylistMode.bookmarks),
    ]);

    expect(
      container.read(mediaPlaybackProvider).playlistMode,
      PlaylistMode.bookmarks,
    );
    expect(backend.pauseCalls, pauseCallsBefore + 1);
    expect(backend.seekCalls.length, seekCallsBefore + 1);
  });

  test('普通播放从真实进度续播，不吸附到第一句字幕开头', () async {
    final controller = await loadController();

    await controller.seekAbsolute(Duration.zero);
    unawaited(controller.play());
    await Future<void>.delayed(Duration.zero);

    expect(backend.playCalls, 1);
    expect(backend.seekCalls.last, Duration.zero);
    expect(backend.seekCalls, isNot(contains(const Duration(seconds: 43))));
    expect(container.read(mediaPlaybackProvider).position, Duration.zero);
    expect(container.read(mediaPlaybackProvider).currentFullIndex, 0);
    await controller.pause();
  });

  test('播放中进度回调同步进度条，并在空白区聚焦最近字幕', () async {
    final controller = await loadController();
    unawaited(controller.play());
    await Future<void>.delayed(Duration.zero);

    backend.emitPosition(const Duration(seconds: 45));
    await Future<void>.delayed(Duration.zero);

    var state = container.read(mediaPlaybackProvider);
    expect(state.position, const Duration(seconds: 45));
    expect(state.currentFullIndex, 0);

    backend.emitPosition(const Duration(seconds: 58));
    await Future<void>.delayed(Duration.zero);

    state = container.read(mediaPlaybackProvider);
    expect(state.position, const Duration(seconds: 58));
    expect(state.currentFullIndex, 1);
    await controller.pause();
  });

  test('请求句末暂停后让当前句自然播完再暂停', () async {
    final controller = await loadController();
    unawaited(controller.play());
    await Future<void>.delayed(Duration.zero);

    await controller.pauseAfterCurrentSentence();
    backend.emitPosition(const Duration(seconds: 49));
    await Future<void>.delayed(Duration.zero);
    expect(backend.pauseCalls, 0);

    backend.emitPosition(const Duration(seconds: 50));
    await waitUntil(() => backend.pauseCalls == 1);

    expect(container.read(mediaPlaybackProvider).isPlaying, isFalse);
  });

  test('点击全文句子后从句首播放，进度条跟随 position stream', () async {
    final controller = await loadController();

    await controller.selectFullSentence(1);
    await Future<void>.delayed(Duration.zero);

    expect(backend.seekCalls.last, const Duration(seconds: 60));
    expect(backend.playCalls, 1);
    var state = container.read(mediaPlaybackProvider);
    expect(state.position, const Duration(seconds: 60));
    expect(state.currentFullIndex, 1);

    backend.emitPosition(const Duration(seconds: 61));
    await Future<void>.delayed(Duration.zero);

    state = container.read(mediaPlaybackProvider);
    expect(state.position, const Duration(seconds: 61));
    expect(state.currentFullIndex, 1);
    await controller.pause();
  });

  test('整篇循环进入下一遍后播放图标状态恢复为播放中', () async {
    final controller = await loadController();
    await controller.updateSettings(
      container
          .read(mediaPlaybackProvider)
          .settings
          .copyWith(
            loopWhole: true,
            wholeLoopCount: 2,
            wholeInterval: Duration.zero,
          ),
    );

    unawaited(controller.play());
    await Future<void>.delayed(Duration.zero);

    expect(container.read(mediaPlaybackProvider).isPlaying, isTrue);

    backend.emitPlaying(false);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(mediaPlaybackProvider).isPlaying, isFalse);

    backend.emitCompleted();
    await waitUntil(() => backend.playCalls >= 2);

    expect(backend.seekCalls.last, Duration.zero);
    expect(backend.playCalls, 2);
    expect(container.read(mediaPlaybackProvider).isPlaying, isTrue);

    await controller.pause();
    expect(container.read(mediaPlaybackProvider).isPlaying, isFalse);
  });

  test('自然播完后退出页面仍将断点保存为开头', () async {
    final controller = await loadController();
    unawaited(controller.play());
    await Future<void>.delayed(Duration.zero);
    backend.emitPosition(const Duration(seconds: 120));
    await Future<void>.delayed(Duration.zero);

    backend.emitCompleted();
    await waitUntil(() => backend.pauseCalls == 1);

    await controller.releaseFromScreen();

    expect(playbackStateDao.savedPositions.last, Duration.zero);
  });

  test('播放中开启单句循环会立即从当前句句首接管', () async {
    final controller = await loadController();
    unawaited(controller.play());
    await waitUntil(() => backend.playCalls == 1);
    backend.emitPosition(const Duration(seconds: 65));
    await Future<void>.delayed(Duration.zero);

    await controller.updateSettings(
      container
          .read(mediaPlaybackProvider)
          .settings
          .copyWith(
            loopSentence: true,
            sentenceLoopCount: 2,
            sentenceInterval: Duration.zero,
          ),
    );

    await waitUntil(() => backend.playCalls == 2);
    expect(backend.seekCalls.last, const Duration(seconds: 60));
    final state = container.read(mediaPlaybackProvider);
    expect(state.currentFullIndex, 1);
    expect(state.sentenceRepeatsDone, 0);
    expect(backend.playCalls, 2);

    await controller.pause();
  });

  test('播放中关闭单句循环会从当前位置立即恢复连续播放', () async {
    final controller = await loadController();
    await controller.updateSettings(
      container
          .read(mediaPlaybackProvider)
          .settings
          .copyWith(
            loopSentence: true,
            sentenceLoopCount: 2,
            sentenceInterval: Duration.zero,
          ),
    );
    unawaited(controller.play());
    await waitUntil(() => backend.playCalls == 1);
    backend.emitPosition(const Duration(seconds: 65));
    await waitUntil(() => backend.position == const Duration(seconds: 65));
    final seeksBeforeDisable = backend.seekCalls.length;

    final disableLoop = controller.updateSettings(
      container
          .read(mediaPlaybackProvider)
          .settings
          .copyWith(loopSentence: false),
    );

    await waitUntil(() => backend.playCalls >= 2);
    await disableLoop;
    expect(backend.seekCalls.length, seeksBeforeDisable + 1);
    expect(backend.seekCalls.last, const Duration(seconds: 65));
    expect(backend.position, const Duration(seconds: 65));
    expect(container.read(mediaPlaybackProvider).isPlaying, isTrue);

    await controller.pause();
  });

  test('播放中切换整篇循环会在本遍结束时按最新设置决定是否回卷', () async {
    final controller = await loadController();
    unawaited(controller.play());
    await Future<void>.delayed(Duration.zero);

    await controller.updateSettings(
      container
          .read(mediaPlaybackProvider)
          .settings
          .copyWith(
            loopWhole: true,
            wholeLoopCount: 2,
            wholeInterval: Duration.zero,
          ),
    );
    backend.emitCompleted();
    await waitUntil(() => backend.playCalls >= 2);

    expect(backend.seekCalls.last, Duration.zero);
    expect(container.read(mediaPlaybackProvider).wholeLoopsDone, 1);

    await controller.pause();
  });

  test('整篇循环中拖动进度会保留已完成遍数', () async {
    final controller = await loadController();
    await controller.updateSettings(
      container
          .read(mediaPlaybackProvider)
          .settings
          .copyWith(
            loopWhole: true,
            wholeLoopCount: 3,
            wholeInterval: Duration.zero,
          ),
    );
    unawaited(controller.play());
    await Future<void>.delayed(Duration.zero);
    backend.emitCompleted();
    await waitUntil(() => backend.playCalls >= 2);
    expect(container.read(mediaPlaybackProvider).wholeLoopsDone, 1);

    await controller.seekAbsolute(const Duration(seconds: 65));
    await waitUntil(() => backend.playCalls >= 3);

    final state = container.read(mediaPlaybackProvider);
    expect(state.position, const Duration(seconds: 65));
    expect(state.wholeLoopsDone, 1);

    await controller.pause();
  });

  test('整篇循环中点选句子会保留已完成遍数', () async {
    final controller = await loadController();
    await controller.updateSettings(
      container
          .read(mediaPlaybackProvider)
          .settings
          .copyWith(
            loopWhole: true,
            wholeLoopCount: 3,
            wholeInterval: Duration.zero,
          ),
    );
    unawaited(controller.play());
    await Future<void>.delayed(Duration.zero);
    backend.emitCompleted();
    await waitUntil(() => backend.playCalls >= 2);
    expect(container.read(mediaPlaybackProvider).wholeLoopsDone, 1);

    await controller.selectFullSentence(1);
    await waitUntil(() => backend.playCalls >= 3);

    final state = container.read(mediaPlaybackProvider);
    expect(state.currentFullIndex, 1);
    expect(state.position, const Duration(seconds: 60));
    expect(state.wholeLoopsDone, 1);

    await controller.pause();
  });

  test('收藏播放中切换单句循环设置不重启当前逐句播放', () async {
    await bookmarkDao.addBookmark(
      const BookmarksCompanion(
        audioItemId: Value('media-playback-test'),
        sentenceIndex: Value(0),
      ),
    );
    final controller = await loadController();
    await controller.setPlaylistMode(PlaylistMode.bookmarks);
    unawaited(controller.play());
    await Future<void>.delayed(Duration.zero);
    final playCallsBeforeToggle = backend.playCalls;
    final seekCallsBeforeToggle = backend.seekCalls.length;

    await controller.updateSettings(
      container
          .read(mediaPlaybackProvider)
          .settings
          .copyWith(loopSentence: true),
    );

    expect(backend.playCalls, playCallsBeforeToggle);
    expect(backend.seekCalls.length, seekCallsBeforeToggle);
    expect(container.read(mediaPlaybackProvider).isPlaying, isTrue);

    await controller.pause();
  });

  test('暂停时切换单句循环只更新设置，不会自动播放', () async {
    final controller = await loadController();

    await controller.updateSettings(
      container
          .read(mediaPlaybackProvider)
          .settings
          .copyWith(loopSentence: true),
    );

    expect(backend.playCalls, 0);
    expect(container.read(mediaPlaybackProvider).settings.loopSentence, isTrue);
  });

  test('按句媒体播放自然完成后异步记录学习统计', () async {
    final controller = await loadController();
    final studyPageGeneration = controller.beginStudyPage();
    await controller.updateSettings(
      container
          .read(mediaPlaybackProvider)
          .settings
          .copyWith(
            loopSentence: true,
            sentenceLoopCount: 1,
            sentenceInterval: Duration.zero,
          ),
    );

    unawaited(controller.play());
    await waitUntil(() => backend.playCalls == 1);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    // 区间播放以到达句尾位置作为自然完成信号；直接发整媒体完成事件会因
    // fake backend 未同步到区间终点而被 MediaEngine 判为失败。
    backend.emitPosition(const Duration(seconds: 50));
    await waitForSentenceStatistics();
    await controller.pause();
    await controller.endStudyPage(studyPageGeneration);
    await waitForStudyDuration();
    await container.read(learnedVocabularyTrackerProvider).flush();

    final record = await database.dailyStudyRecordDao.getByDate(DateTime.now());
    expect(record?.studyTimeMilliseconds, greaterThanOrEqualTo(1000));
    expect(record?.inputTimeMilliseconds, greaterThanOrEqualTo(1000));
    expect(
      record?.inputTimeMilliseconds,
      lessThanOrEqualTo(record?.studyTimeMilliseconds ?? 0),
    );
    expect(record?.inputWords, 2);
    final stageRecord = (await database.dailyStageStudyRecordDao.getByDate(
      DateTime.now(),
    )).singleWhere((item) => item.stage == StudyStage.freePlayer);
    expect(stageRecord.studyTimeMilliseconds, greaterThanOrEqualTo(1000));
    expect(
      stageRecord.inputTimeMilliseconds,
      lessThanOrEqualTo(stageRecord.studyTimeMilliseconds),
    );
    expect(await database.learnedWordFormDao.countAll(), 2);
  });

  test('连续媒体播放自然完成后异步记录所有已听句子的词数和词汇', () async {
    final controller = await loadController();
    final studyPageGeneration = controller.beginStudyPage();

    unawaited(controller.play());
    await waitUntil(() => backend.playCalls == 1);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    backend.emitPosition(const Duration(seconds: 120));
    backend.emitCompleted();

    await waitForSentenceStatistics(minimumWords: 8);
    await controller.endStudyPage(studyPageGeneration);
    await container.read(studyTimeServiceProvider).flush();
    await waitForStudyDuration();
    await container.read(learnedVocabularyTrackerProvider).flush();

    final record = await database.dailyStudyRecordDao.getByDate(DateTime.now());
    expect(record?.inputWords, 8);
    expect(await database.learnedWordFormDao.countAll(), 5);
  });

  test('releaseFromScreen 后迟到的底层播放事件不再污染状态且 backend 保留', () async {
    backend.closeStreamsOnDispose = false;
    final controller = await loadController();
    unawaited(controller.play());
    await Future<void>.delayed(Duration.zero);

    expect(container.read(mediaPlaybackProvider).isPlaying, isTrue);

    await controller.releaseFromScreen();
    backend.emitPlaying(true);
    backend.emitPosition(const Duration(seconds: 88));
    await Future<void>.delayed(Duration.zero);

    final state = container.read(mediaPlaybackProvider);
    expect(state.isPlaying, isFalse);
    expect(state.position, Duration.zero);
    expect(backend.disposed, isFalse);
  });

  test('旧页面 token 不能释放新页面的媒体会话', () async {
    final controller = await loadController();
    final oldPage = controller.beginStudyPage();
    final newPage = controller.beginStudyPage();

    await controller.releaseFromScreen(studyPageGeneration: oldPage);

    expect(router.isRouted, isTrue);
    await controller.endStudyPage(newPage);
  });

  test('MediaEngine 被学习模式释放后，同一媒体再次进入会重新加载', () async {
    backend.closeStreamsOnDispose = false;
    final controller = await loadController();
    final engine = container.read(mediaEngineProvider.notifier);

    await engine.releaseFromScreen();

    expect(await controller.load(item()), MediaLoadResult.ready);
    expect(backend.openCalls, hasLength(2));
    expect(
      container.read(mediaPlaybackProvider).duration,
      const Duration(seconds: 120),
    );
    expect(backend.disposed, isFalse);
  });

  test('视频字幕默认关闭，且由 media controller 统一管理', () async {
    final controller = await loadController();

    expect(container.read(mediaPlaybackProvider).videoSubtitleVisible, isFalse);
    expect(backend.subtitleTrackDataCalls, [null]);

    await controller.setVideoSubtitleVisible(true);
    await controller.setVisualTrackExpanded(true);

    var state = container.read(mediaPlaybackProvider);
    expect(state.videoSubtitleVisible, isTrue);
    expect(state.visualTrackExpanded, isTrue);
    expect(
      backend.subtitleTrackDataCalls.last,
      '1\n00:00:43,000 --> 00:00:50,000\nFirst sentence.\n',
    );

    await controller.setVisualTrackVisible(false);

    state = container.read(mediaPlaybackProvider);
    expect(state.visualTrackVisible, isFalse);
    expect(state.visualTrackExpanded, isFalse);
    expect(backend.videoTrackCalls.last, isFalse);
  });

  test('解码后的画面方向同步到媒体状态', () async {
    await loadController();

    backend.emitLandscapeVideo(true);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(mediaPlaybackProvider).isLandscapeVideo, isTrue);

    backend.emitLandscapeVideo(false);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(mediaPlaybackProvider).isLandscapeVideo, isFalse);
  });

  test('解码后的画面比例同步到媒体状态', () async {
    await loadController();

    backend.emitVideoAspectRatio(4 / 3);
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(mediaPlaybackProvider).videoAspectRatio,
      closeTo(4 / 3, 0.0001),
    );

    backend.emitVideoAspectRatio(9 / 16);
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(mediaPlaybackProvider).videoAspectRatio,
      closeTo(9 / 16, 0.0001),
    );
  });

  test('Provider 销毁会释放 media chain', () async {
    await loadController();

    expect(router.isRouted, isTrue);

    container.dispose();
    await waitUntil(() => backend.disposed);
    container = ProviderContainer();

    expect(router.isRouted, isFalse);
    expect(backend.stopCalls, 1);
  });
}

class _MockPlaybackStateDao extends Mock implements PlaybackStateDao {
  final savedPositions = <Duration>[];

  @override
  Future<void> saveState(PlaybackStatesCompanion entry) async {
    savedPositions.add(Duration(milliseconds: entry.positionMs.value));
  }
}

Future<void> waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 1),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for condition.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _TranscriptAudioEngine extends TestAudioEngine {
  _TranscriptAudioEngine(this.sentences);

  final List<Sentence> sentences;

  @override
  Future<List<Sentence>> loadTranscript(AudioItem audioItem) async =>
      List<Sentence>.of(sentences);
}
