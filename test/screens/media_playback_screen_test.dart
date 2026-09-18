import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart' hide PlaybackState;
import 'package:echo_loop/database/app_database.dart' show PlaybackState;
import 'package:echo_loop/database/daos/playback_state_dao.dart';
import 'package:echo_loop/database/providers.dart';
import 'package:echo_loop/models/audio_item.dart';
import 'package:echo_loop/models/listening_practice_state.dart';
import 'package:echo_loop/models/sentence.dart';
import 'package:echo_loop/providers/audio_engine/audio_engine_provider.dart';
import 'package:echo_loop/providers/media_engine/media_engine_provider.dart';
import 'package:echo_loop/providers/media_playback/media_playback_provider.dart';
import 'package:echo_loop/providers/sentence_ai_provider.dart';
import 'package:echo_loop/screens/media_playback_screen.dart';
import 'package:echo_loop/services/media_session_router.dart';
import 'package:echo_loop/services/sentence_ai_api_client.dart';
import 'package:echo_loop/theme/app_theme.dart';
import 'package:echo_loop/utils/app_data_dir.dart';
import 'package:echo_loop/widgets/common/paragraph_sentence_list_card.dart';
import 'package:echo_loop/widgets/common/masked_sentence_tile.dart';
import 'package:echo_loop/widgets/common/free_player_sentence_pager.dart';
import 'package:echo_loop/widgets/practice/sentence_explanation_view.dart';
import 'package:echo_loop/widgets/practice/practice_progress_section.dart';
import 'package:echo_loop/widgets/dictionary/dictionary_panel_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/mock_providers.dart';
import '../helpers/shared/fake_media_player_backend.dart';
import '../helpers/test_app.dart';

class _MockApiClient extends Mock implements SentenceAiApiClient {
  @override
  bool get usesExternalProvider => false;
}

void main() {
  late FakeMediaPlayerBackend backend;
  late MediaSessionRouter router;
  late Directory appDir;
  late File mediaFile;
  late AudioItem item;
  late FakeAudioItemDao audioItemDao;

  final transcriptSentences = <Sentence>[
    Sentence(
      index: 0,
      text: 'First sentence.',
      startTime: const Duration(seconds: 1),
      endTime: const Duration(seconds: 3),
    ),
    Sentence(
      index: 1,
      text: 'Second sentence.',
      startTime: const Duration(seconds: 4),
      endTime: const Duration(seconds: 6),
    ),
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    appDir = await Directory.systemTemp.createTemp('echo-loop-video-screen-');
    appDataDirectoryOverride = appDir;
    backend = FakeMediaPlayerBackend();
    router = MediaSessionRouter(defaultHandler: BaseAudioHandler());
    mediaFile = File('${appDir.path}/echo-loop-video-screen.mp4');
    await mediaFile.writeAsBytes(const [0, 1, 2]);
    audioItemDao = FakeAudioItemDao()
      ..transcriptSrtStore['video-screen'] =
          '1\n00:00:01,000 --> 00:00:03,000\nFirst sentence.\n';
    item = AudioItem(
      id: 'video-screen',
      name: 'Screen Video',
      audioPath: 'echo-loop-video-screen.mp4',
      addedDate: DateTime(2026, 7, 24),
      transcriptSource: TranscriptSource.local,
    );
  });

  List<Override> mediaOverrides({
    bool withTranscript = false,
    Future<List<Sentence>>? transcriptFuture,
    List<Sentence>? transcriptOverride,
    PlaybackStateDao? playbackStateDao,
  }) => [
    mediaBackendFactoryProvider.overrideWithValue(() => backend),
    mediaSessionRouterProvider.overrideWithValue(router),
    if (playbackStateDao != null)
      playbackStateDaoProvider.overrideWithValue(playbackStateDao),
    if (withTranscript) ...[
      audioItemDaoProvider.overrideWithValue(audioItemDao),
      bookmarkDaoProvider.overrideWithValue(TestBookmarkDao()),
      audioEngineProvider.overrideWith(
        () => transcriptFuture == null
            ? _TranscriptAudioEngine(transcriptOverride ?? transcriptSentences)
            : _FutureTranscriptAudioEngine(transcriptFuture),
      ),
      ...learningSettingsOverrides(),
      sentenceAiNotifierProvider.overrideWithValue(
        SentenceAiNotifier(
          cacheDao: createStubbedMockCacheDao(),
          apiClient: _MockApiClient(),
        ),
      ),
    ],
  ];

  void testMediaWidgets(
    String description,
    Future<void> Function(WidgetTester tester) body,
  ) {
    testWidgets(description, (tester) async {
      await body(tester);
      // 必须在测试回调仍运行时卸载 ProviderScope；若放进 addTearDown，
      // 测试框架会先校验 Provider 产生的 Drift 关闭定时器。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    });
  }

  Future<void> pumpMediaReady(WidgetTester tester) async {
    for (var i = 0; i < 40; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
      if (backend.openCalls.isNotEmpty &&
          find
              .byKey(const ValueKey('managed-media-loading'))
              .evaluate()
              .isEmpty &&
          find.byKey(const ValueKey('fake-video-view')).evaluate().isNotEmpty &&
          find
              .byKey(const ValueKey('media-progress-elapsed-label'))
              .evaluate()
              .isNotEmpty) {
        // 媒体容器就绪后，字幕 Provider 仍可能在下一帧提交结果；多推进一小段
        // 时间，避免后续断言观察到“媒体已就绪但字幕尚未挂载”的中间态。
        await tester.pump(const Duration(milliseconds: 500));
        return;
      }
    }
  }

  tearDown(() async {
    // 页面卸载会异步保存播放断点，先给 Drift 写入一个真实事件循环机会，
    // 再清理临时目录，避免释放流程访问已删除的测试数据库文件。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    appDataDirectoryOverride = null;
    if (await appDir.exists()) await appDir.delete(recursive: true);
  });

  testMediaWidgets('加载后渲染视觉区，隐藏画面后显示折叠条', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: [
          mediaBackendFactoryProvider.overrideWithValue(() => backend),
          mediaSessionRouterProvider.overrideWithValue(router),
        ],
      ),
    );
    await pumpMediaReady(tester);

    expect(find.text('Failed to load video'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(backend.openCalls, isNotEmpty);
    expect(find.text('No transcript'), findsOneWidget);
    expect(find.text('Screen Video'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-video-view')), findsOneWidget);
    final viewportWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final videoViewport = backend.videoViewSizes.last;
    expect(videoViewport.width, lessThan(viewportWidth));
    // 宽屏将控制区以外的余高交给观看画布，实际视频由 media_kit
    // 在画布内等比 contain，不再让 Flutter 画布固定为 16:9。
    expect(videoViewport.height, greaterThan(0));

    await tester.tap(find.byKey(const ValueKey('media-visual-surface')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('media-fullscreen-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('media-subtitle-track-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('media-visual-play-pause-button')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('media-visual-play-pause-button')),
    );
    await tester.pump();
    expect(backend.playCalls, 1);
    await tester.tap(
      find.byKey(const ValueKey('media-visual-play-pause-button')),
    );
    await tester.pump();
    expect(backend.pauseCalls, 1);
    await tester.tap(find.byKey(const ValueKey('media-hide-visual-button')));
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.byKey(const ValueKey('media-visual-collapsed-bar')),
      findsOneWidget,
    );
    expect(backend.videoTrackCalls, contains(false));
  });

  testMediaWidgets('已创建意群播放器后退出页面不在卸载期修改媒体状态', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);

    final context = tester.element(find.byType(MediaPlaybackScreen));
    ProviderScope.containerOf(
      context,
    ).read(mediaPlaybackProvider.notifier).senseGroupRangePlayback;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testMediaWidgets('视频播放控制区避让底部系统安全区', (tester) async {
    final originalPhysicalSize = tester.view.physicalSize;
    final originalDevicePixelRatio = tester.view.devicePixelRatio;
    final originalPadding = tester.view.padding;
    final originalViewPadding = tester.view.viewPadding;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    // 模拟退出沉浸式全屏后的瞬间：普通 padding 可能暂时为 0，
    // 但系统导航栏的 viewPadding 已经恢复。
    tester.view.padding = const FakeViewPadding();
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);

    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(),
      ),
    );
    await pumpMediaReady(tester);

    final playButton = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('media-control-panel')),
        matching: find.byIcon(Icons.play_arrow),
      ),
    );
    expect(playButton.bottom, lessThanOrEqualTo(844 - 34));

    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.devicePixelRatio = originalDevicePixelRatio;
    tester.view.physicalSize = originalPhysicalSize;
    tester.view.padding = originalPadding;
    tester.view.viewPadding = originalViewPadding;
    await tester.pump();
  });

  testMediaWidgets('键盘快捷键控制播放和切换字幕句', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);

    // 键盘事件需要先让媒体页获得焦点。
    await tester.tap(find.byKey(const ValueKey('media-visual-surface')));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(backend.playCalls, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(backend.pauseCalls, 1);
    // MediaEngine 以 200ms 轮询确认播放 session 已失效；推进时钟让该轮询自行释放。
    await tester.pump(const Duration(milliseconds: 200));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(backend.seekCalls.last, const Duration(seconds: 4));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(backend.seekCalls.last, const Duration(seconds: 1));

    await tester.pumpWidget(const SizedBox.shrink());
    // 卸载媒体页并推进启动保护定时器，避免测试结束时遗留 pending timer。
    await tester.pump(const Duration(seconds: 6));
  });

  testMediaWidgets('字幕读取期间显示加载态，不提前显示无字幕空态', (tester) async {
    final transcriptCompleter = Completer<List<Sentence>>();
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(
          withTranscript: true,
          transcriptFuture: transcriptCompleter.future,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.byKey(const ValueKey('managed-media-loading')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('media-transcript-loading-indicator')),
      findsOneWidget,
    );
    expect(find.text('No transcript'), findsNothing);

    transcriptCompleter.complete(transcriptSentences);
    await pumpMediaReady(tester);
    for (var i = 0; i < 20; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(ParagraphSentenceListCard).evaluate().isNotEmpty) {
        break;
      }
    }

    final card = tester.widget<ParagraphSentenceListCard>(
      find.byType(ParagraphSentenceListCard),
    );
    expect(card.sentences.map((sentence) => sentence.text), [
      'First sentence.',
      'Second sentence.',
    ]);

    await tester.pumpWidget(const SizedBox.shrink());
    // 释放 Drift 查询流的关闭定时器，避免测试框架误报 pending timer。
    await tester.pump(const Duration(seconds: 6));
  });

  testMediaWidgets('字幕列表不等待 media_kit 初始化完成即可出现', (tester) async {
    final blockingBackend = _BlockingOpenMediaPlayerBackend();
    backend = blockingBackend;
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );

    for (var i = 0; i < 20; i += 1) {
      await tester.pump(const Duration(milliseconds: 10));
      if (find.byType(ParagraphSentenceListCard).evaluate().isNotEmpty) break;
    }

    expect(backend.openCalls, isNotEmpty);
    expect(blockingBackend.openCompleter.isCompleted, isFalse);
    final card = tester.widget<ParagraphSentenceListCard>(
      find.byType(ParagraphSentenceListCard),
    );
    expect(card.sentences.first.text, 'First sentence.');

    blockingBackend.openCompleter.complete();
    await pumpMediaReady(tester);
  });

  testMediaWidgets('恢复断点前不显示零进度，backend 直接从断点位置打开', (tester) async {
    final playbackStateDao = _MockPlaybackStateDao();
    when(() => playbackStateDao.getByAudioId(item.id)).thenAnswer(
      (_) async => PlaybackState(
        audioItemId: item.id,
        positionMs: 26000,
        playlistMode: PlaylistMode.full.index,
        savedAt: DateTime(2026, 7, 27),
      ),
    );
    final blockingBackend = _BlockingOpenMediaPlayerBackend()
      ..setDuration(const Duration(seconds: 66));
    backend = blockingBackend;
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(playbackStateDao: playbackStateDao),
      ),
    );

    for (var i = 0; i < 20; i += 1) {
      await tester.pump(const Duration(milliseconds: 10));
      if (backend.openCalls.isNotEmpty) break;
    }

    expect(backend.openInitialPositions, [const Duration(seconds: 26)]);
    expect(
      find.byKey(const ValueKey('media-progress-placeholder')),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      find.byKey(const ValueKey('media-progress-elapsed-label')),
      findsNothing,
    );

    blockingBackend.openCompleter.complete();
    await pumpMediaReady(tester);
    await tester.pump(const Duration(milliseconds: 16));

    final elapsed = tester.widget<Text>(
      find.byKey(const ValueKey('media-progress-elapsed-label')),
    );
    final remaining = tester.widget<Text>(
      find.byKey(const ValueKey('media-progress-remaining-label')),
    );
    expect(elapsed.data, '0:26');
    expect(remaining.data, '-0:40');
  });

  testMediaWidgets('视频随心听 AppBar 提供与音频一致的定时停止入口', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: [
          mediaBackendFactoryProvider.overrideWithValue(() => backend),
          mediaSessionRouterProvider.overrideWithValue(router),
        ],
      ),
    );
    await pumpMediaReady(tester);

    await tester.tap(find.byIcon(Icons.timer_outlined));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Sleep timer'), findsOneWidget);
    expect(find.text('5 min'), findsOneWidget);
    await tester.tap(find.text('5 min'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining(RegExp(r'^\d\d:\d\d$')), findsOneWidget);
  });

  testMediaWidgets('列表模式字幕在当前自适应栏位内接入句子讲解回调', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);

    final cardFinder = find.byType(ParagraphSentenceListCard);
    expect(cardFinder, findsOneWidget);
    expect(find.byType(TabBar), findsNothing);
    expect(find.byType(TabBarView), findsOneWidget);
    final card = tester.widget<ParagraphSentenceListCard>(cardFinder);
    expect(card.onSentenceTap, isNotNull);

    final cardRect = tester.getRect(cardFinder);
    final viewportWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(cardRect.left, greaterThan(0));
    expect(cardRect.right, closeTo(viewportWidth, 0.1));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testMediaWidgets('视频画面和字幕区之间显示主题化细分割线', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);

    final dividerFinder = find.byKey(
      const ValueKey('media-visual-transcript-divider'),
    );
    expect(dividerFinder, findsOneWidget);

    final divider = tester.widget<Container>(dividerFinder);
    expect(tester.getSize(dividerFinder).width, 1);
    expect(tester.getSize(dividerFinder).height, greaterThan(1));
    expect(
      divider.color,
      Theme.of(
        tester.element(dividerFinder),
      ).colorScheme.outlineVariant.withValues(alpha: 0.45),
    );
  });

  testMediaWidgets('单句模式复用音频讲解视图并保留视频画面', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);

    final context = tester.element(find.byType(MediaPlaybackScreen));
    final container = ProviderScope.containerOf(context);
    final controller = container.read(mediaPlaybackProvider.notifier);
    await controller.updateSettings(
      container
          .read(mediaPlaybackProvider)
          .settings
          .copyWith(singleSentenceMode: true),
    );
    // 单句讲解区可能包含持续刷新的异步内容，固定推进等待设置生效即可。
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(FreePlayerSentencePager), findsOneWidget);
    expect(find.byType(SentenceExplanationView), findsOneWidget);
    expect(find.byType(PracticeProgressBar), findsNothing);
    expect(find.byType(PracticeSentenceInfoRow), findsOneWidget);
    expect(find.byType(DictionaryPanelHost), findsOneWidget);
    expect(find.byType(ParagraphSentenceListCard), findsNothing);
    expect(find.byKey(const ValueKey('fake-video-view')), findsOneWidget);
    expect(find.text('Sentence 1/2'), findsOneWidget);
    expect(find.text('0:01 - 0:03'), findsOneWidget);
    final pagerRect = tester.getRect(
      find.byKey(kFullSingleSentenceSwipeAreaKey),
    );
    expect(
      tester.getRect(find.byType(SentenceExplanationView).hitTestable()).left,
      pagerRect.left + AppSpacing.m,
      reason: '视频随心听讲解区应相对分页器保留宿主级水平边距',
    );
    final viewportWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(pagerRect.left, greaterThan(0));
    expect(pagerRect.right, greaterThanOrEqualTo(viewportWidth));

    await tester.pumpWidget(const SizedBox.shrink());
    // 消耗测试环境中的启动保护定时器，避免卸载时留下 pending timer。
    await tester.pump(const Duration(seconds: 6));
  });

  testMediaWidgets('竖屏手机尺寸下单句模式讲解区应完整显示句子正文', (tester) async {
    final originalPhysicalSize = tester.view.physicalSize;
    final originalDevicePixelRatio = tester.view.devicePixelRatio;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 667);
    addTearDown(() {
      tester.view.physicalSize = originalPhysicalSize;
      tester.view.devicePixelRatio = originalDevicePixelRatio;
    });

    final longSentences = <Sentence>[
      Sentence(
        index: 0,
        text: "And it's challenging too. Do you need any equipment?",
        startTime: const Duration(seconds: 1),
        endTime: const Duration(seconds: 3),
      ),
      Sentence(
        index: 1,
        text: 'Second sentence.',
        startTime: const Duration(seconds: 4),
        endTime: const Duration(seconds: 6),
      ),
    ];

    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(
          withTranscript: true,
          transcriptOverride: longSentences,
        ),
      ),
    );
    await pumpMediaReady(tester);

    final context = tester.element(find.byType(MediaPlaybackScreen));
    final container = ProviderScope.containerOf(context);
    final controller = container.read(mediaPlaybackProvider.notifier);
    await controller.updateSettings(
      container
          .read(mediaPlaybackProvider)
          .settings
          .copyWith(singleSentenceMode: true),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final scrollView = find.descendant(
      of: find.byType(SentenceExplanationView),
      matching: find.byType(SingleChildScrollView),
    );
    expect(scrollView, findsOneWidget);
    final scrollable = find.descendant(
      of: scrollView,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(
      position.maxScrollExtent,
      0,
      reason:
          '视频可见时讲解区可用高度不应挤压到句子正文需要滚动才能看全，'
          '否则底部会被 SingleChildScrollView 裁掉一截',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testMediaWidgets('视频单句模式左滑切到下一句并保持暂停态', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);

    final context = tester.element(find.byType(MediaPlaybackScreen));
    final container = ProviderScope.containerOf(context);
    final controller = container.read(mediaPlaybackProvider.notifier);
    await controller.updateSettings(
      container
          .read(mediaPlaybackProvider)
          .settings
          .copyWith(singleSentenceMode: true),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.fling(
      find.byKey(kFullSingleSentenceSwipeAreaKey),
      const Offset(-500, 0),
      1000,
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(container.read(mediaPlaybackProvider).currentFullIndex, 1);
    expect(container.read(mediaPlaybackProvider).isPlaying, isFalse);
    expect(backend.seekCalls.last, const Duration(seconds: 4));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testMediaWidgets('第一句时上一句按钮禁用，下一句按钮启用', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);

    final prevButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.skip_previous),
    );
    expect(prevButton.onPressed, isNull);

    final nextButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.skip_next),
    );
    expect(nextButton.onPressed, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testMediaWidgets('最后一句时下一句按钮禁用，上一句按钮启用', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);

    final context = tester.element(find.byType(MediaPlaybackScreen));
    final container = ProviderScope.containerOf(context);
    await container
        .read(mediaPlaybackProvider.notifier)
        .selectFullSentence(1, autoPlay: false);
    await tester.pumpAndSettle();

    final prevButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.skip_previous),
    );
    expect(prevButton.onPressed, isNotNull);

    final nextButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.skip_next),
    );
    expect(nextButton.onPressed, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testMediaWidgets('底部收藏按钮在全文与收藏列表间双向切换', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);

    final context = tester.element(find.byType(MediaPlaybackScreen));
    final container = ProviderScope.containerOf(context);
    final controller = container.read(mediaPlaybackProvider.notifier);
    await controller.toggleBookmark(0);
    await tester.pump();

    final button = find.byKey(const ValueKey('media-playlist-mode-button'));
    expect(find.byIcon(Icons.bookmarks_outlined), findsOneWidget);
    expect(
      find.descendant(of: button, matching: find.text('1')),
      findsOneWidget,
    );

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
      container.read(mediaPlaybackProvider).playlistMode,
      PlaylistMode.bookmarks,
    );
    expect(find.byIcon(Icons.bookmarks), findsOneWidget);

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
      container.read(mediaPlaybackProvider).playlistMode,
      PlaylistMode.full,
    );
    expect(find.byIcon(Icons.bookmarks_outlined), findsOneWidget);
  });

  testMediaWidgets('收藏列表播放中仍可点击编号、正文和书签热区', (tester) async {
    await tester.pumpWidget(
      createTestScreen(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);

    final context = tester.element(find.byType(MediaPlaybackScreen));
    final container = ProviderScope.containerOf(context);
    final controller = container.read(mediaPlaybackProvider.notifier);
    await controller.toggleBookmark(0);
    await controller.toggleBookmark(1);
    await controller.setPlaylistMode(PlaylistMode.bookmarks);
    for (var frame = 0; frame < 10; frame += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    unawaited(controller.play());
    await tester.pump(const Duration(milliseconds: 20));
    expect(container.read(mediaPlaybackProvider).isPlaying, isTrue);

    // 模拟真实播放的高频 position stream。派生的收藏列表每次
    // 都是新 List 实例，但句子集合未变，不应重启自动滚动。
    for (var milliseconds = 1100; milliseconds <= 1400; milliseconds += 100) {
      backend.emitPosition(Duration(milliseconds: milliseconds));
      await tester.pump(const Duration(milliseconds: 80));
    }

    await tester.tap(
      find.byKey(const ValueKey('$kMaskedSentenceNumberHitAreaKeyPrefix-1')),
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(container.read(mediaPlaybackProvider).currentBookmarkIndex, 1);

    for (var frame = 0; frame < 10; frame += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(
      find.byKey(const ValueKey('$kMaskedSentenceBodyHitAreaKeyPrefix-1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sentence Detail'), findsOneWidget);
    Navigator.of(tester.element(find.text('Sentence Detail'))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(MediaPlaybackScreen), findsOneWidget);

    unawaited(controller.play());
    for (var frame = 0; frame < 10; frame += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    for (var milliseconds = 4100; milliseconds <= 4400; milliseconds += 100) {
      backend.emitPosition(Duration(milliseconds: milliseconds));
      await tester.pump(const Duration(milliseconds: 80));
    }

    await tester.tap(
      find.byKey(const ValueKey('$kMaskedSentenceBookmarkHitAreaKeyPrefix-1')),
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(container.read(mediaPlaybackProvider).bookmarkedIndices, {0});

    await controller.pause();
    await tester.pump(const Duration(milliseconds: 220));
  });

  testMediaWidgets('收藏模式取消最后一条后回全文并提示', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);

    final context = tester.element(find.byType(MediaPlaybackScreen));
    final container = ProviderScope.containerOf(context);
    final controller = container.read(mediaPlaybackProvider.notifier);
    await controller.toggleBookmark(1);
    await controller.setPlaylistMode(PlaylistMode.bookmarks);
    await tester.pumpAndSettle();

    final card = tester.widget<ParagraphSentenceListCard>(
      find.byType(ParagraphSentenceListCard),
    );
    card.onSentenceBookmarkToggle?.call(transcriptSentences[1]);
    await tester.pumpAndSettle();

    final state = container.read(mediaPlaybackProvider);
    expect(state.playlistMode, PlaylistMode.full);
    expect(state.currentFullIndex, 1);
    expect(state.bookmarkedSentences, isEmpty);
    expect(
      find.text('No bookmarked sentences remain. Switched to Full Text.'),
      findsOneWidget,
    );
  });

  testMediaWidgets('收藏精听连续取消倒数第二条和最后一条后仍保持精听', (tester) async {
    final fourSentences = [
      ...transcriptSentences,
      Sentence(
        index: 2,
        text: 'Third sentence.',
        startTime: const Duration(seconds: 7),
        endTime: const Duration(seconds: 9),
      ),
      Sentence(
        index: 3,
        text: 'Fourth sentence.',
        startTime: const Duration(seconds: 10),
        endTime: const Duration(seconds: 12),
      ),
    ];
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(
          withTranscript: true,
          transcriptOverride: fourSentences,
        ),
      ),
    );
    await pumpMediaReady(tester);

    final context = tester.element(find.byType(MediaPlaybackScreen));
    final container = ProviderScope.containerOf(context);
    final controller = container.read(mediaPlaybackProvider.notifier);
    for (var index = 0; index < fourSentences.length; index += 1) {
      await controller.toggleBookmark(index);
    }
    await controller.setPlaylistMode(PlaylistMode.bookmarks);
    await controller.selectBookmarkedSentence(2, autoPlay: false);
    await controller.updateSettings(
      container
          .read(mediaPlaybackProvider)
          .settings
          .copyWith(singleSentenceMode: true),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(kBookmarkSingleSentenceSwipeAreaKey), findsOneWidget);
    var view = tester.widget<FreePlayerSentencePager>(
      find.byType(FreePlayerSentencePager),
    );
    view.actions.onBookmarkToggle(2);
    await tester.pumpAndSettle();
    expect(container.read(mediaPlaybackProvider).currentBookmarkIndex, 3);

    view = tester.widget<FreePlayerSentencePager>(
      find.byType(FreePlayerSentencePager),
    );
    view.actions.onBookmarkToggle(3);
    await tester.pumpAndSettle();

    var state = container.read(mediaPlaybackProvider);
    expect(state.playlistMode, PlaylistMode.bookmarks);
    expect(state.bookmarkedIndices, {0, 1});
    expect(state.currentBookmarkIndex, 1);
    expect(state.settings.singleSentenceMode, isTrue);
    expect(find.byKey(kBookmarkSingleSentenceSwipeAreaKey), findsOneWidget);
    expect(find.byType(ParagraphSentenceListCard), findsNothing);

    final singleModeButton = find.ancestor(
      of: find.byIcon(Icons.format_quote),
      matching: find.byType(IconButton),
    );
    await tester.tap(singleModeButton);
    await tester.pumpAndSettle();
    state = container.read(mediaPlaybackProvider);
    expect(state.settings.singleSentenceMode, isFalse);
    expect(find.byType(ParagraphSentenceListCard), findsOneWidget);

    final listModeButton = find.ancestor(
      of: find.byIcon(Icons.article),
      matching: find.byType(IconButton),
    );
    await tester.tap(listModeButton);
    await tester.pumpAndSettle();
    expect(
      container.read(mediaPlaybackProvider).settings.singleSentenceMode,
      isTrue,
    );
    expect(find.byKey(kBookmarkSingleSentenceSwipeAreaKey), findsOneWidget);
  });

  testMediaWidgets('320px 窄屏下五个底部控制按钮不溢出', (tester) async {
    final originalPhysicalSize = tester.view.physicalSize;
    final originalDevicePixelRatio = tester.view.devicePixelRatio;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);

    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);

    expect(
      find.byKey(const ValueKey('media-playlist-mode-button')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    // 先卸载小屏页面再恢复测试视口，避免恢复尺寸时旧树重布局
    // 产生迟到的 overflow，污染下一个 widget 用例。
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.devicePixelRatio = originalDevicePixelRatio;
    tester.view.physicalSize = originalPhysicalSize;
    await tester.pump();
  });

  testMediaWidgets('宽横屏将视频控制区和字幕区自然拆为左右两栏', (tester) async {
    final originalPhysicalSize = tester.view.physicalSize;
    final originalDevicePixelRatio = tester.view.devicePixelRatio;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);

    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);

    final singleControlPanelHeight = tester
        .getSize(find.byKey(const ValueKey('media-control-panel')))
        .height;

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('media-playback-wide-layout')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('media-playback-single-layout')),
      findsNothing,
    );

    final videoRect = tester.getRect(
      find.byKey(const ValueKey('fake-video-view')),
    );
    final transcriptRect = tester.getRect(
      find.byType(ParagraphSentenceListCard),
    );
    final dividerRect = tester.getRect(
      find.byKey(const ValueKey('media-visual-transcript-divider')),
    );
    final wideLayoutRect = tester.getRect(
      find.byKey(const ValueKey('media-playback-wide-layout')),
    );
    final controlPanelRect = tester.getRect(
      find.byKey(const ValueKey('media-control-panel')),
    );
    final infoBarRect = tester.getRect(
      find.byKey(const ValueKey('media-info-bar')),
    );
    expect(videoRect.width, closeTo(dividerRect.left, 0.1));
    // 控制区与单列一致，其余左栏高度全部交给黑色观看画布。
    expect(controlPanelRect.height, closeTo(singleControlPanelHeight, 0.1));
    expect(
      videoRect.height,
      closeTo(wideLayoutRect.height - controlPanelRect.height, 0.1),
    );
    expect(videoRect.bottom, closeTo(controlPanelRect.top, 0.1));
    expect(transcriptRect.left, greaterThan(videoRect.left));
    expect(dividerRect.width, 1);
    expect(dividerRect.height, greaterThan(videoRect.height));
    expect(controlPanelRect.bottom, closeTo(wideLayoutRect.bottom, 0.1));
    expect(infoBarRect.center.dx, closeTo(controlPanelRect.center.dx, 0.1));
    expect(videoRect.left, closeTo(0, 0.1));

    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.devicePixelRatio = originalDevicePixelRatio;
    tester.view.physicalSize = originalPhysicalSize;
    await tester.pump();
  });

  testMediaWidgets('大尺寸竖屏保持单列，宽高比大于一时立即切为双栏', (tester) async {
    final originalPhysicalSize = tester.view.physicalSize;
    final originalDevicePixelRatio = tester.view.devicePixelRatio;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1500);

    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);

    expect(
      find.byKey(const ValueKey('media-playback-single-layout')),
      findsOneWidget,
    );

    tester.view.physicalSize = const Size(1200, 450);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('media-playback-wide-layout')),
      findsOneWidget,
    );

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('media-playback-wide-layout')),
      findsOneWidget,
    );

    final context = tester.element(find.byType(MediaPlaybackScreen));
    final controller = ProviderScope.containerOf(
      context,
    ).read(mediaPlaybackProvider.notifier);
    await controller.setVisualTrackVisible(false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('media-playback-single-layout')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('media-visual-collapsed-bar')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.devicePixelRatio = originalDevicePixelRatio;
    tester.view.physicalSize = originalPhysicalSize;
    await tester.pump();
  });

  testMediaWidgets('横向视频画布占满控制区之外的左栏余高', (tester) async {
    final originalPhysicalSize = tester.view.physicalSize;
    final originalDevicePixelRatio = tester.view.devicePixelRatio;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);

    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);
    backend.emitVideoAspectRatio(4 / 3);
    await tester.pump();

    final videoRect = tester.getRect(
      find.byKey(const ValueKey('fake-video-view')),
    );
    final dividerRect = tester.getRect(
      find.byKey(const ValueKey('media-visual-transcript-divider')),
    );
    final controlPanelRect = tester.getRect(
      find.byKey(const ValueKey('media-control-panel')),
    );
    expect(videoRect.width, closeTo(dividerRect.left, 0.1));
    expect(videoRect.height, greaterThan(videoRect.width * 3 / 4));
    expect(controlPanelRect.top, closeTo(videoRect.bottom, 0.1));

    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.devicePixelRatio = originalDevicePixelRatio;
    tester.view.physicalSize = originalPhysicalSize;
    await tester.pump();
  });

  testMediaWidgets('单列竖向视频保持固定画面高度并在画布内留黑边', (tester) async {
    final originalPhysicalSize = tester.view.physicalSize;
    final originalDevicePixelRatio = tester.view.devicePixelRatio;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1400);

    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(withTranscript: true),
      ),
    );
    await pumpMediaReady(tester);
    final canvasBeforeMetadata = tester.getSize(
      find.byKey(const ValueKey('media-video-canvas')),
    );
    backend.emitVideoAspectRatio(9 / 16);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('media-playback-single-layout')),
      findsOneWidget,
    );

    final canvasRect = tester.getRect(
      find.byKey(const ValueKey('media-video-canvas')),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('media-video-canvas'))),
      canvasBeforeMetadata,
    );
    expect(canvasRect.width, closeTo(800, 0.1));
    expect(canvasRect.height, 260);

    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.devicePixelRatio = originalDevicePixelRatio;
    tester.view.physicalSize = originalPhysicalSize;
    await tester.pump();
  });

  testMediaWidgets('字幕加载中已按宽高比直接显示双栏', (tester) async {
    final originalPhysicalSize = tester.view.physicalSize;
    final originalDevicePixelRatio = tester.view.devicePixelRatio;
    final transcriptCompleter = Completer<List<Sentence>>();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);

    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(
          withTranscript: true,
          transcriptFuture: transcriptCompleter.future,
        ),
      ),
    );
    await pumpMediaReady(tester);

    expect(
      find.byKey(const ValueKey('media-playback-wide-layout')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('media-transcript-loading-indicator')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.devicePixelRatio = originalDevicePixelRatio;
    tester.view.physicalSize = originalPhysicalSize;
    await tester.pump();
  });

  testMediaWidgets('macOS 未确认原生全屏时不进入窗口内伪全屏', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: [
          mediaBackendFactoryProvider.overrideWithValue(() => backend),
          mediaSessionRouterProvider.overrideWithValue(router),
        ],
      ),
    );
    await pumpMediaReady(tester);

    await tester.tap(find.byKey(const ValueKey('media-visual-surface')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('media-subtitle-track-button')));
    await tester.pump();

    expect(backend.subtitleTrackDataCalls, [null, null]);

    await tester.tap(find.byKey(const ValueKey('media-fullscreen-button')));
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('No transcript'), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-video-view')), findsOneWidget);
  });

  testMediaWidgets('生命周期切后台/回前台会断开并恢复视频轨', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: [
          mediaBackendFactoryProvider.overrideWithValue(() => backend),
          mediaSessionRouterProvider.overrideWithValue(router),
        ],
      ),
    );
    await pumpMediaReady(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(backend.videoTrackCalls, [false, false, false, true]);
  });

  testMediaWidgets('播放进度变化时同步刷新已播和剩余时间', (tester) async {
    backend.setDuration(const Duration(minutes: 2));
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: [
          mediaBackendFactoryProvider.overrideWithValue(() => backend),
          mediaSessionRouterProvider.overrideWithValue(router),
        ],
      ),
    );
    await pumpMediaReady(tester);

    expect(find.text('0:00'), findsOneWidget);
    expect(find.text('-2:00'), findsOneWidget);

    backend.emitPosition(const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 16));

    final elapsed = tester.widget<Text>(
      find.byKey(const ValueKey('media-progress-elapsed-label')),
    );
    final remaining = tester.widget<Text>(
      find.byKey(const ValueKey('media-progress-remaining-label')),
    );
    expect(elapsed.data, '0:10');
    expect(remaining.data, '-1:50');
  });

  testMediaWidgets('恢复断点后进度条按正确比例显示', (tester) async {
    final semanticsHandle = tester.ensureSemantics();
    final playbackStateDao = _MockPlaybackStateDao();
    when(() => playbackStateDao.getByAudioId(item.id)).thenAnswer(
      (_) async => PlaybackState(
        audioItemId: item.id,
        positionMs: 26000,
        playlistMode: PlaylistMode.full.index,
        savedAt: DateTime(2026, 7, 27),
      ),
    );
    backend.setDuration(const Duration(seconds: 66));
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: mediaOverrides(playbackStateDao: playbackStateDao),
      ),
    );
    await pumpMediaReady(tester);
    await tester.pump(const Duration(milliseconds: 16));

    final elapsed = tester.widget<Text>(
      find.byKey(const ValueKey('media-progress-elapsed-label')),
    );
    final remaining = tester.widget<Text>(
      find.byKey(const ValueKey('media-progress-remaining-label')),
    );
    final progressSemantics = tester.getSemantics(
      find.byKey(const ValueKey('media-progress-bar')),
    );
    expect(elapsed.data, '0:26');
    expect(remaining.data, '-0:40');
    expect(progressSemantics.value, '39%');
    semanticsHandle.dispose();
  });

  testMediaWidgets('进度条使用紧凑时间间距并尽量拉长', (tester) async {
    backend.setDuration(const Duration(minutes: 2));
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: [
          mediaBackendFactoryProvider.overrideWithValue(() => backend),
          mediaSessionRouterProvider.overrideWithValue(router),
        ],
      ),
    );
    await pumpMediaReady(tester);

    final barRect = tester.getRect(
      find.byKey(const ValueKey('media-progress-bar')),
    );
    final elapsedRect = tester.getRect(
      find.byKey(const ValueKey('media-progress-elapsed-label')),
    );
    final remainingRect = tester.getRect(
      find.byKey(const ValueKey('media-progress-remaining-label')),
    );
    final controlPanelRect = tester.getRect(
      find.byKey(const ValueKey('media-control-panel')),
    );

    expect(elapsedRect.left, closeTo(controlPanelRect.left + 6, 1));
    expect(remainingRect.right, closeTo(controlPanelRect.right - 6, 1));
    expect(barRect.left, closeTo(controlPanelRect.left + 48, 1));
    expect(barRect.right, closeTo(controlPanelRect.right - 56, 1));
    expect(barRect.width, closeTo(controlPanelRect.width - 104, 1));
  });

  testMediaWidgets('拖动进度圆点过程中实时刷新已播和剩余时间', (tester) async {
    backend.setDuration(const Duration(minutes: 2));
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: [
          mediaBackendFactoryProvider.overrideWithValue(() => backend),
          mediaSessionRouterProvider.overrideWithValue(router),
        ],
      ),
    );
    await pumpMediaReady(tester);

    final barRect = tester.getRect(
      find.byKey(const ValueKey('media-progress-bar')),
    );
    final gesture = await tester.startGesture(barRect.centerLeft);
    await tester.pump();
    await gesture.moveTo(barRect.center);
    await tester.pump();

    final elapsed = tester.widget<Text>(
      find.byKey(const ValueKey('media-progress-elapsed-label')),
    );
    final remaining = tester.widget<Text>(
      find.byKey(const ValueKey('media-progress-remaining-label')),
    );
    expect(elapsed.data, '1:00');
    expect(remaining.data, '-1:00');
    expect(backend.seekCalls, isEmpty);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 16));

    expect(backend.seekCalls.last.inSeconds, closeTo(60, 1));
    await tester.pump(const Duration(milliseconds: 180));
  });

  testMediaWidgets('媒体循环设置与音频共用次数和间隔滑块', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        MediaPlaybackScreen(audioItem: item),
        overrides: [
          mediaBackendFactoryProvider.overrideWithValue(() => backend),
          mediaSessionRouterProvider.overrideWithValue(router),
        ],
      ),
    );
    await pumpMediaReady(tester);

    await tester.tap(find.byIcon(Icons.repeat));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.byType(SegmentedButton<int>), findsNothing);
    expect(find.text('Repeat Count'), findsOneWidget);
    expect(find.text('Interval Duration'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(2));

    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders.first.min, 1);
    expect(sliders.first.max, 11);
    expect(sliders.first.divisions, 10);
    expect(sliders.last.min, 0);
    expect(sliders.last.max, 10);
    expect(sliders.last.divisions, 10);

    sliders.last.onChanged?.call(6);
    await tester.pump();
    final context = tester.element(find.byType(MediaPlaybackScreen));
    expect(
      ProviderScope.containerOf(
        context,
      ).read(mediaPlaybackProvider).settings.wholeInterval,
      const Duration(seconds: 6),
    );
  });

  testMediaWidgets('退出页面时异步释放媒体链路，不在 dispose 同步修改 provider', (tester) async {
    final showVideo = ValueNotifier<bool>(true);
    addTearDown(showVideo.dispose);
    await tester.pumpWidget(
      createTestApp(
        ValueListenableBuilder<bool>(
          valueListenable: showVideo,
          builder: (context, visible, child) {
            if (!visible) return const SizedBox.shrink();
            return MediaPlaybackScreen(audioItem: item);
          },
        ),
        overrides: [
          mediaBackendFactoryProvider.overrideWithValue(() => backend),
          mediaSessionRouterProvider.overrideWithValue(router),
        ],
      ),
    );
    await pumpMediaReady(tester);

    showVideo.value = false;
    await tester.pump();

    expect(tester.takeException(), isNull);
    await tester.idle();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

class _TranscriptAudioEngine extends TestAudioEngine {
  _TranscriptAudioEngine(this.sentences);

  final List<Sentence> sentences;

  @override
  Future<List<Sentence>> loadTranscript(AudioItem audioItem) async =>
      List<Sentence>.of(sentences);
}

class _MockPlaybackStateDao extends Mock implements PlaybackStateDao {}

class _FutureTranscriptAudioEngine extends TestAudioEngine {
  _FutureTranscriptAudioEngine(this.sentencesFuture);

  final Future<List<Sentence>> sentencesFuture;

  @override
  Future<List<Sentence>> loadTranscript(AudioItem audioItem) => sentencesFuture;
}

class _BlockingOpenMediaPlayerBackend extends FakeMediaPlayerBackend {
  final openCompleter = Completer<void>();

  @override
  Future<void> open(
    String filePath, {
    Duration initialPosition = Duration.zero,
  }) async {
    await super.open(filePath, initialPosition: initialPosition);
    await openCompleter.future;
  }
}
