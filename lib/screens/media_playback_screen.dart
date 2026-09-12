import 'dart:async';

import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/audio_item.dart';
import '../models/listening_practice_state.dart';
import '../models/media_playback_state.dart';
import '../models/playback_settings.dart';
import '../models/retell_settings.dart';
import '../models/sentence.dart';
import '../providers/collection_provider.dart';
import '../providers/media_engine/media_engine_provider.dart';
import '../providers/media_playback/media_playback_provider.dart';
import '../providers/media_playback/media_sleep_timer_provider.dart';
import '../router/app_router.dart';
import '../services/app_logger.dart';
import '../services/media_fullscreen_service.dart';
import '../theme/app_theme.dart';
import '../utils/playback_speed.dart';
import '../widgets/common/anchored_bubble.dart';
import '../widgets/common/audio_app_bar_title.dart';
import '../widgets/common/paragraph_sentence_list_card.dart';
import '../widgets/common/free_player_sentence_pager.dart';
import '../widgets/common/media_visual_surface.dart';
import '../widgets/common/managed_media_visual_surface.dart';
import '../widgets/dictionary/dictionary_panel_host.dart';
import '../widgets/player_hotkey_scope.dart';
import '../widgets/study/study_activity_detector.dart';
import '../widgets/settings_dialog.dart';
import '../widgets/sleep_timer.dart';
import 'sentence_detail_screen.dart';

/// media_kit 随心听页面。
///
/// 当前从带画面轨的媒体入口进入；命名与状态按未来音频/视频共用方向设计。
class MediaPlaybackScreen extends ConsumerStatefulWidget {
  const MediaPlaybackScreen({super.key, required this.audioItem});

  final AudioItem audioItem;

  @override
  ConsumerState<MediaPlaybackScreen> createState() =>
      _MediaPlaybackScreenState();
}

class _MediaPlaybackScreenState extends ConsumerState<MediaPlaybackScreen>
    with SingleTickerProviderStateMixin {
  /// 单列播放器控制区的紧凑基准高度。
  ///
  /// 双栏复用同一基准，避免宽屏时把视频下方的控制区人为拉高。
  static const _singleColumnControlPanelHeight = 176.0;

  late final TabController _playlistViewController;
  late final MediaPlayback _controller;
  late final int _studyPageGeneration;
  late final MediaSleepTimer _sleepTimer;
  late final MediaFullscreenService _fullscreenService;
  late final StreamSubscription<bool> _fullscreenSubscription;
  AppLifecycleListener? _lifecycle;
  Duration? _seekPreviewPosition;
  int _seekPreviewToken = 0;
  bool _isNavigatingToDetail = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(mediaPlaybackProvider.notifier);
    _studyPageGeneration = _controller.beginStudyPage();
    _sleepTimer = ref.read(mediaSleepTimerProvider.notifier);
    _fullscreenService = MediaFullscreenService();
    _fullscreenSubscription = _fullscreenService.changes.listen((expanded) {
      if (!mounted) return;
      unawaited(_controller.setVisualTrackExpanded(expanded));
    });
    _playlistViewController = TabController(length: 2, vsync: this);
    _lifecycle = AppLifecycleListener(onStateChange: _handleLifecycle);
  }

  void _handleLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(_controller.handleLifecycleHidden());
      case AppLifecycleState.resumed:
        unawaited(_controller.handleLifecycleResumed());
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.detached:
        unawaited(_fullscreenService.exit());
        unawaited(
          _controller.releaseFromScreen(
            studyPageGeneration: _studyPageGeneration,
          ),
        );
    }
  }

  Future<void> _setVisualTrackExpanded(bool expanded) async {
    if (expanded) {
      await _fullscreenService.enter(
        isLandscapeVideo:
            ref.read(mediaPlaybackProvider).isLandscapeVideo ?? false,
      );
      return;
    }
    await _fullscreenService.exit();
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    unawaited(_fullscreenSubscription.cancel());
    unawaited(_releaseFullscreen());
    _playlistViewController.dispose();
    // 页面销毁时在后台启动幂等收尾，防止媒体资源继续工作或丢失最终统计。
    unawaited(_controller.finishStudyPage(generation: _studyPageGeneration));
    scheduleMicrotask(_sleepTimer.cancel);
    super.dispose();
  }

  Future<void> _releaseFullscreen() async {
    await _fullscreenService.exit();
    await _fullscreenService.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(mediaPlaybackProvider);
    final l10n = AppLocalizations.of(context)!;
    return StudyActivityDetector(
      onActivity: _controller.markStudyActivity,
      child: LearningHotkeyScope(
        onPlayPause: () => state.isPlaying
            ? unawaited(_controller.pause())
            : unawaited(_controller.play()),
        onPrevious: () => unawaited(_controller.previousSentence()),
        onNext: () => unawaited(_controller.nextSentence()),
        child: Scaffold(
          backgroundColor: state.visualTrackExpanded ? Colors.black : null,
          appBar: state.visualTrackExpanded
              ? null
              : AppBar(
                  titleSpacing: 0,
                  title: _buildAppBarTitle(state, l10n),
                  actions: const [SleepTimerButton.mediaPlayback()],
                ),
          body: ManagedMediaVisualSurface(
            loadKey: widget.audioItem.id,
            load: () => _controller.load(widget.audioItem),
            cancel: _controller.cancelLoad,
            child: DictionaryPanelHost(
              handleBackButton: true,
              child: _buildBody(context, state, l10n),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAppBarTitle(MediaPlaybackState state, AppLocalizations l10n) {
    final item = state.audioItem ?? widget.audioItem;
    final collectionNames = ref.watch(
      collectionListProvider.select((s) {
        final ids = s.audioToCollectionsMap[item.id] ?? const <String>[];
        if (ids.isEmpty) return const <String>[];
        final idSet = ids.toSet();
        return s.collections
            .where((c) => idSet.contains(c.id))
            .map((c) => c.name)
            .toList(growable: false);
      }),
    );
    return AudioAppBarTitle(
      audioName: item.name.isEmpty ? l10n.player : item.name,
      collectionNames: collectionNames,
    );
  }

  Widget _buildBody(
    BuildContext context,
    MediaPlaybackState state,
    AppLocalizations l10n,
  ) {
    if (state.visualTrackExpanded) {
      return _buildMediaVisualSurface(state);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final useWideLayout = _useWideMediaLayout(constraints, state);
        if (!useWideLayout) {
          return Column(
            key: const ValueKey('media-playback-single-layout'),
            children: [
              _buildMediaVisualSurface(state),
              const _MediaContentDivider(),
              Expanded(child: _buildTranscriptView(context, state, l10n)),
              _buildControlPanel(context, state),
            ],
          );
        }

        return Row(
          key: const ValueKey('media-playback-wide-layout'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: Column(
                children: [
                  Expanded(
                    child: _buildMediaVisualSurface(
                      state,
                      fillAvailableHeight: true,
                    ),
                  ),
                  _buildControlPanel(
                    context,
                    state,
                    minimumHeight: _singleColumnControlPanelHeight,
                    compact: true,
                  ),
                ],
              ),
            ),
            const _MediaContentDivider(vertical: true),
            Expanded(
              flex: 2,
              child: _buildTranscriptView(context, state, l10n),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMediaVisualSurface(
    MediaPlaybackState state, {
    bool fillAvailableHeight = false,
  }) {
    // 讲解子路由正在显示同一个 media_kit 会话时，父路由不再同时创建第二个
    // Video 纹理；但必须保留同尺寸黑色画布，避免路由交接首帧露出下方字幕区。
    // 返回后由本页面恢复唯一画面宿主。
    if (_isNavigatingToDetail) {
      return _MediaVisualHandoffCanvas(
        fillAvailableHeight: fillAvailableHeight,
        expanded: state.visualTrackExpanded,
      );
    }
    final controller = ref.read(mediaPlaybackProvider.notifier);
    return MediaVisualSurface(
      state: MediaVisualSurfaceState(
        visible: state.visualTrackVisible,
        expanded: state.visualTrackExpanded,
        isPlaying: state.isPlaying,
        subtitleVisible: state.videoSubtitleVisible,
      ),
      actions: MediaVisualSurfaceActions(
        onShow: () => unawaited(controller.setVisualTrackVisible(true)),
        onHide: () => unawaited(controller.setVisualTrackVisible(false)),
        onPlayPause: () =>
            unawaited(state.isPlaying ? controller.pause() : controller.play()),
        onSubtitleToggle: () => unawaited(
          controller.setVideoSubtitleVisible(!state.videoSubtitleVisible),
        ),
        onFullscreenToggle: () =>
            unawaited(_setVisualTrackExpanded(!state.visualTrackExpanded)),
      ),
      fillAvailableHeight: fillAvailableHeight,
      buildVideoView: (size) => ref
          .read(mediaEngineProvider.notifier)
          .buildVideoView(viewportSize: size),
    );
  }

  /// 根据页面实际可用空间决定是否采用视频与字幕双栏。
  ///
  /// 此策略刻意只存在于 UI 层：窗口缩放不应影响媒体会话、播放进度或字幕状态。
  /// 画面可见时，仅按实际内容区宽高比决定布局，避免等待字幕异步加载后再跳变。
  bool _useWideMediaLayout(
    BoxConstraints constraints,
    MediaPlaybackState state,
  ) {
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    return state.visualTrackVisible &&
        width.isFinite &&
        height.isFinite &&
        height > 0 &&
        width / height > 1;
  }

  Widget _buildTranscriptView(
    BuildContext context,
    MediaPlaybackState state,
    AppLocalizations l10n,
  ) {
    final controller = ref.read(mediaPlaybackProvider.notifier);
    final isTranscriptPending =
        state.audioItem?.id != widget.audioItem.id || state.isTranscriptLoading;
    if (isTranscriptPending) {
      return const Center(
        child: CircularProgressIndicator(
          key: ValueKey('media-transcript-loading-indicator'),
        ),
      );
    }
    if (!state.hasSentences) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.subtitles_off_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: AppSpacing.m),
            Text(
              l10n.videoNoTranscript,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    if (_playlistViewController.index != state.playlistMode.index) {
      _playlistViewController.index = state.playlistMode.index;
    }

    // 保留原有 TabBarView/PageView 的列表保活、自动聚焦和命中测试
    // 行为；只移除可见 TabBar，由底部按钮驱动 playlistMode。
    return TabBarView(
      controller: _playlistViewController,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _buildSentencePane(
          state,
          state.sentences,
          state.currentFullIndex,
          PlaylistMode.full,
          (s) => controller.selectFullSentence(s.index),
        ),
        _buildBookmarkPane(state, l10n),
      ],
    );
  }

  Widget _buildBookmarkPane(MediaPlaybackState state, AppLocalizations l10n) {
    final bookmarked = state.bookmarkedSentences;
    if (bookmarked.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.bookmark_border,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: AppSpacing.m),
            Text(
              l10n.noBookmarkedSentences,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.s),
            Text(
              l10n.tapBookmarkIcon,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    final playingLocalIndex = bookmarked.indexWhere(
      (s) => s.index == state.currentBookmarkIndex,
    );
    final controller = ref.read(mediaPlaybackProvider.notifier);
    return _buildSentencePane(
      state,
      bookmarked,
      state.currentBookmarkIndex,
      PlaylistMode.bookmarks,
      (s) => controller.selectBookmarkedSentence(s.index),
      playingLocalIndex: playingLocalIndex,
    );
  }

  Widget _buildSentencePane(
    MediaPlaybackState state,
    List<Sentence> sentences,
    int? currentSentenceIndex,
    PlaylistMode mode,
    ValueChanged<Sentence> onPlayFrom, {
    int? playingLocalIndex,
  }) {
    final controller = ref.read(mediaPlaybackProvider.notifier);
    final settings = mode == PlaylistMode.bookmarks
        ? state.bookmarkSettings
        : state.fullSettings;
    if (settings.singleSentenceMode && currentSentenceIndex != null) {
      final audioItem = state.audioItem ?? widget.audioItem;
      final isBookmarkMode = mode == PlaylistMode.bookmarks;
      return FreePlayerSentencePager(
        key: PageStorageKey(
          'media-single-sentence-${audioItem.id}-${mode.name}',
        ),
        audioItem: audioItem,
        sentences: sentences,
        currentSentenceIndex: currentSentenceIndex,
        bookmarkedSentenceIndices: state.bookmarkedIndices,
        showTranscript: settings.showTranscript,
        isPlaying: state.isPlaying,
        scope: isBookmarkMode
            ? FreePlayerSentenceScope.bookmarks
            : FreePlayerSentenceScope.full,
        actions: FreePlayerSentenceActions(
          onSentenceSelected: isBookmarkMode
              ? controller.selectBookmarkedSentence
              : controller.selectFullSentence,
          onBookmarkToggle: _handleBookmarkToggle,
          onStopMainPlayer: () => unawaited(controller.pause()),
          onToolbarButtonTapped: () =>
              unawaited(controller.pauseAfterCurrentSentence()),
        ),
      );
    }
    return ParagraphSentenceListCard(
      key: PageStorageKey(
        'media-sentence-list-${widget.audioItem.id}-${mode.name}',
      ),
      sentences: sentences,
      displayMode: state.settings.showTranscript
          ? RetellDisplayMode.showAll
          : RetellDisplayMode.hideAll,
      keywordMap: const {},
      playingSentenceIndex: playingLocalIndex ?? currentSentenceIndex ?? -1,
      autoFocusEnabled: true,
      bookmarkedSentenceIndices: state.bookmarkedIndices,
      onSentencePlayFrom: onPlayFrom,
      onSentenceTap: _handleSentenceDetail,
      onSentenceBookmarkToggle: (s) => _handleBookmarkToggle(s.index),
    );
  }

  /// 收藏模式删除最后一条时，controller 会回到全文；页面只负责
  /// 给出一次可见反馈，避免用户对列表突然切换感到困惑。
  Future<void> _handleBookmarkToggle(int index) async {
    final before = ref.read(mediaPlaybackProvider);
    await ref.read(mediaPlaybackProvider.notifier).toggleBookmark(index);
    if (!mounted) return;
    final after = ref.read(mediaPlaybackProvider);
    if (before.playlistMode == PlaylistMode.bookmarks &&
        before.bookmarkedSentences.length == 1 &&
        after.playlistMode == PlaylistMode.full &&
        after.bookmarkedSentences.isEmpty) {
      _showBookmarkFallbackSnackBar();
    }
  }

  void _showBookmarkFallbackSnackBar() {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.bookmarksEmptyReturned),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  /// 点击字幕正文后暂停媒体，进入嵌套句子讲解页；返回时恢复媒体侧状态。
  Future<void> _handleSentenceDetail(Sentence sentence) async {
    if (_isNavigatingToDetail) return;
    _isNavigatingToDetail = true;
    if (mounted) setState(() {});
    final controller = ref.read(mediaPlaybackProvider.notifier);

    try {
      await controller.prepareSentenceDetail(sentence.index);
      if (!mounted) return;

      AppLogger.log(
        'Navigation',
        'media-player push sentence-detail audio=${widget.audioItem.id} '
            'sentence=${sentence.index}',
      );
      await AppRoutes.pushNested(
        context,
        AppRoutes.sentenceDetailSegment,
        extra: SentenceDetailArgs(
          audioItemId: widget.audioItem.id,
          audioName: widget.audioItem.name,
          sentenceText: sentence.text,
          sentenceIndex: sentence.index,
          totalSentenceCount: ref.read(mediaPlaybackProvider).sentences.length,
          startTimeMs: sentence.startTime.inMilliseconds,
          endTimeMs: sentence.endTime.inMilliseconds,
          rangePlayback: controller.senseGroupRangePlayback,
          mediaSession: SentenceDetailMediaSession(
            readState: () => ref.read(mediaPlaybackProvider),
            setVisible: controller.setVisualTrackVisible,
            setSubtitleVisible: controller.setVideoSubtitleVisible,
            setFullscreen: _setVisualTrackExpanded,
            buildVideoView: (size) => ref
                .read(mediaEngineProvider.notifier)
                .buildVideoView(viewportSize: size),
          ),
        ),
      );
      if (!mounted) return;

      AppLogger.log(
        'Navigation',
        'media-player returned from sentence-detail '
            'audio=${widget.audioItem.id} sentence=${sentence.index}',
      );
      final modeBeforeRestore = ref.read(mediaPlaybackProvider).playlistMode;
      await controller.restoreAfterSentenceDetail();
      if (mounted &&
          modeBeforeRestore == PlaylistMode.bookmarks &&
          ref.read(mediaPlaybackProvider).playlistMode == PlaylistMode.full) {
        _showBookmarkFallbackSnackBar();
      }
    } finally {
      _isNavigatingToDetail = false;
      if (mounted) setState(() {});
    }
  }

  Widget _buildControlPanel(
    BuildContext context,
    MediaPlaybackState state, {
    double? minimumHeight,
    bool compact = false,
  }) {
    final controls = _MediaControls(state: state, compact: compact);
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minimumHeight ?? 0),
      child: Container(
        key: const ValueKey('media-control-panel'),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 0.5,
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          bottom: true,
          maintainBottomViewPadding: true,
          minimum: const EdgeInsets.only(bottom: AppSpacing.s),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildProgressBar(state),
              controls,
              _MediaInfoBar(state: state),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgressBar(MediaPlaybackState state) {
    final isPlaybackPending =
        state.audioItem?.id != widget.audioItem.id || state.isLoading;
    if (isPlaybackPending) {
      return const SizedBox(
        key: ValueKey('media-progress-placeholder'),
        height: 36,
      );
    }
    final controller = ref.read(mediaPlaybackProvider.notifier);
    final progress = _seekPreviewPosition ?? state.position;
    final total = state.duration ?? Duration.zero;
    final labelStyle = AppTextStyles.caption(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 12, 6, 8),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text(
              _formatMediaTime(progress),
              key: const ValueKey('media-progress-elapsed-label'),
              textAlign: TextAlign.start,
              style: labelStyle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            // audio_video_progress_bar 会先更新 progress 再更新 total。若进度先于
            // 总时长到达，内部会把进度钳成 0；总时长变化时重建 render object，
            // 让它用同一帧的完整数据计算滑块比例。
            child: KeyedSubtree(
              key: ValueKey('media-progress-total-${total.inMilliseconds}'),
              child: ProgressBar(
                key: const ValueKey('media-progress-bar'),
                progress: progress,
                total: total,
                onDragStart: (details) {
                  _seekPreviewToken += 1;
                  _updateSeekPreview(details.timeStamp);
                },
                onDragUpdate: (details) =>
                    _updateSeekPreview(details.timeStamp),
                onSeek: (duration) {
                  final token = ++_seekPreviewToken;
                  setState(() => _seekPreviewPosition = duration);
                  unawaited(_settleSeekPreview(token, duration, controller));
                },
                barHeight: 3,
                thumbRadius: 8,
                thumbGlowRadius: 14,
                timeLabelLocation: TimeLabelLocation.none,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 42,
            child: Text(
              _formatRemainingMediaTime(progress: progress, total: total),
              key: const ValueKey('media-progress-remaining-label'),
              textAlign: TextAlign.end,
              style: labelStyle,
            ),
          ),
        ],
      ),
    );
  }

  void _updateSeekPreview(Duration position) {
    if (_seekPreviewPosition == position) return;
    setState(() => _seekPreviewPosition = position);
  }

  Future<void> _settleSeekPreview(
    int token,
    Duration target,
    MediaPlayback controller,
  ) async {
    await controller.seekAbsolute(target);
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted || token != _seekPreviewToken) return;
    setState(() => _seekPreviewPosition = null);
  }
}

/// 父子路由交接同一个视频纹理时的临时黑色画布。
///
/// [MediaVisualSurface] 不能在两个路由树中同时挂载同一纹理；交接期间父页以
/// 相同的布局尺寸保留黑色观看区域，避免用户误以为先回到了纯字幕列表。
class _MediaVisualHandoffCanvas extends StatelessWidget {
  const _MediaVisualHandoffCanvas({
    required this.fillAvailableHeight,
    required this.expanded,
  });

  final bool fillAvailableHeight;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final maxHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : double.infinity;
        final preferredHeight = width / (16 / 9);
        final height = expanded || fillAvailableHeight
            ? maxHeight
            : preferredHeight
                  .clamp(0.0, maxHeight < 260 ? maxHeight : 260.0)
                  .toDouble();
        return SizedBox(
          key: const ValueKey('media-visual-handoff-canvas'),
          width: double.infinity,
          height: height,
          child: const ColoredBox(color: Colors.black),
        );
      },
    );
  }
}

/// 在视频画面和字幕阅读区之间提供不占空间的细分割线。
class _MediaContentDivider extends StatelessWidget {
  const _MediaContentDivider({this.vertical = false});

  static const _opacity = 0.45;

  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('media-visual-transcript-divider'),
      height: vertical ? double.infinity : 1,
      width: vertical ? 1 : double.infinity,
      color: colorScheme.outlineVariant.withValues(alpha: _opacity),
    );
  }
}

String _formatMediaTime(Duration value) {
  final safe = value < Duration.zero ? Duration.zero : value;
  final hours = safe.inHours;
  final minutes = safe.inMinutes.remainder(60);
  final seconds = safe.inSeconds.remainder(60);
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _formatRemainingMediaTime({
  required Duration progress,
  required Duration total,
}) {
  final remaining = total - progress;
  return '-${_formatMediaTime(remaining)}';
}

class _MediaControls extends ConsumerWidget {
  const _MediaControls({required this.state, this.compact = false});

  static const double _controlButtonSize = 56;
  static const double _mainControlGap = 48;
  static const double _compactControlGap = 12;

  final MediaPlaybackState state;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(mediaPlaybackProvider.notifier);
    final isMobile = compact || MediaQuery.sizeOf(context).width < 600;
    final compactControlGap = MediaQuery.sizeOf(context).width <= 360
        ? 4.0
        : _compactControlGap;
    if (!state.hasSentences) {
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: isMobile ? 0 : 8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _MediaSpeedButton(),
                SizedBox(width: 12),
                _MediaLoopButton(),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _navButton(
                  Icons.replay_10,
                  () => controller.previousSentence(),
                ),
                const SizedBox(width: _mainControlGap),
                _playPauseButton(context, controller),
                const SizedBox(width: _mainControlGap),
                _navButton(Icons.forward_10, () => controller.nextSentence()),
              ],
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: isMobile ? 0 : 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _playlistModeButton(context, controller),
              SizedBox(width: compactControlGap),
              _toggleButton(
                context,
                icon: state.settings.singleSentenceMode
                    ? Icons.format_quote
                    : Icons.article,
                active: state.settings.singleSentenceMode,
                onPressed: () => controller.updateSettings(
                  state.settings.copyWith(
                    singleSentenceMode: !state.settings.singleSentenceMode,
                  ),
                ),
              ),
              SizedBox(width: compactControlGap),
              const _MediaSpeedButton(),
              SizedBox(width: compactControlGap),
              _toggleButton(
                context,
                icon: state.settings.showTranscript
                    ? Icons.visibility
                    : Icons.visibility_off,
                active: state.settings.showTranscript,
                onPressed: () => controller.updateSettings(
                  state.settings.copyWith(
                    showTranscript: !state.settings.showTranscript,
                  ),
                ),
              ),
              SizedBox(width: compactControlGap),
              const _MediaLoopButton(),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _navButton(
                Icons.skip_previous,
                state.isFirstSentence
                    ? null
                    : () => controller.previousSentence(),
              ),
              const SizedBox(width: _mainControlGap),
              _playPauseButton(context, controller),
              const SizedBox(width: _mainControlGap),
              _navButton(
                Icons.skip_next,
                state.isLastSentence ? null : () => controller.nextSentence(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _playlistModeButton(BuildContext context, MediaPlayback controller) {
    final l10n = AppLocalizations.of(context)!;
    final isBookmarks = state.playlistMode == PlaylistMode.bookmarks;
    final bookmarkCount = state.bookmarkedSentences.length;
    final targetLabel = isBookmarks
        ? '${l10n.fullText} (${state.sentences.length})'
        : '${l10n.bookmarked} ($bookmarkCount)';
    final badgeLabel = bookmarkCount > 99 ? '99+' : '$bookmarkCount';
    final colorScheme = Theme.of(context).colorScheme;

    return IconButton(
      key: const ValueKey('media-playlist-mode-button'),
      tooltip: targetLabel,
      isSelected: isBookmarks,
      icon: Badge(
        isLabelVisible: bookmarkCount > 0,
        label: Text(badgeLabel),
        child: const Icon(Icons.bookmarks_outlined),
      ),
      selectedIcon: Badge(
        isLabelVisible: bookmarkCount > 0,
        label: Text(badgeLabel),
        child: const Icon(Icons.bookmarks),
      ),
      color: colorScheme.onSurface.withValues(alpha: 0.6),
      style: isBookmarks
          ? IconButton.styleFrom(
              foregroundColor: colorScheme.primary,
              backgroundColor: colorScheme.primaryContainer,
            )
          : null,
      onPressed: () {
        if (!isBookmarks && bookmarkCount == 0) {
          final messenger = ScaffoldMessenger.of(context);
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(l10n.noBookmarksHint),
                duration: const Duration(seconds: 3),
              ),
            );
          return;
        }
        unawaited(
          controller.setPlaylistMode(
            isBookmarks ? PlaylistMode.full : PlaylistMode.bookmarks,
          ),
        );
      },
    );
  }

  Widget _playPauseButton(BuildContext context, MediaPlayback controller) {
    return SizedBox.square(
      dimension: _controlButtonSize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          shape: BoxShape.circle,
        ),
        child: IconButton(
          icon: Icon(state.isPlaying ? Icons.pause : Icons.play_arrow),
          iconSize: 36,
          color: Theme.of(context).colorScheme.onPrimary,
          onPressed: () => state.isPlaying
              ? unawaited(controller.pause())
              : unawaited(controller.play()),
        ),
      ),
    );
  }

  static Widget _navButton(IconData icon, VoidCallback? onPressed) {
    return SizedBox.square(
      dimension: _controlButtonSize,
      child: IconButton(icon: Icon(icon), iconSize: 32, onPressed: onPressed),
    );
  }

  static Widget _toggleButton(
    BuildContext context, {
    required IconData icon,
    required bool active,
    required VoidCallback onPressed,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(icon),
      iconSize: 22,
      color: active
          ? colorScheme.primary
          : colorScheme.onSurface.withValues(alpha: 0.6),
      style: active
          ? IconButton.styleFrom(backgroundColor: colorScheme.primaryContainer)
          : null,
      onPressed: onPressed,
    );
  }
}

class _MediaSpeedButton extends ConsumerStatefulWidget {
  const _MediaSpeedButton();

  @override
  ConsumerState<_MediaSpeedButton> createState() => _MediaSpeedButtonState();
}

class _MediaSpeedButtonState extends ConsumerState<_MediaSpeedButton> {
  final OverlayPortalController _portalController = OverlayPortalController();

  @override
  Widget build(BuildContext context) {
    final speed = ref.watch(
      mediaPlaybackProvider.select((s) => s.settings.playbackSpeed),
    );
    final color = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.6);
    return AnchoredBubble(
      controller: _portalController,
      direction: BubbleDirection.up,
      width: 120,
      contentBuilder: (_) =>
          _MediaSpeedPopup(onSelected: _portalController.hide),
      child: TextButton(
        onPressed: _portalController.toggle,
        style: TextButton.styleFrom(
          minimumSize: const Size(40, 40),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: color,
        ),
        child: Text(
          formatPlaybackSpeedLabel(speed),
          style: TextStyle(fontSize: 14, color: color),
        ),
      ),
    );
  }
}

class _MediaSpeedPopup extends ConsumerWidget {
  const _MediaSpeedPopup({required this.onSelected});

  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(mediaPlaybackProvider);
    final controller = ref.read(mediaPlaybackProvider.notifier);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final speed in kFreePlayerPlaybackSpeeds)
            BubbleMenuRow(
              label: formatPlaybackSpeedLabel(speed),
              selected: speed == state.settings.playbackSpeed,
              color: speed == state.settings.playbackSpeed
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
              trailing: speed == state.settings.playbackSpeed
                  ? Icon(
                      Icons.check,
                      size: 18,
                      color: theme.colorScheme.primary,
                    )
                  : null,
              onTap: () {
                controller.updateSettings(
                  state.settings.copyWith(playbackSpeed: speed),
                );
                onSelected();
              },
            ),
        ],
      ),
    );
  }
}

class _MediaLoopButton extends ConsumerStatefulWidget {
  const _MediaLoopButton();

  @override
  ConsumerState<_MediaLoopButton> createState() => _MediaLoopButtonState();
}

class _MediaLoopButtonState extends ConsumerState<_MediaLoopButton> {
  final OverlayPortalController _portalController = OverlayPortalController();

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(mediaPlaybackProvider.select((s) => s.settings));
    final active = settings.loopWhole || settings.loopSentence;
    final icon = settings.loopSentence && !settings.loopWhole
        ? Icons.repeat_one
        : Icons.repeat;
    final colorScheme = Theme.of(context).colorScheme;
    return AnchoredBubble(
      controller: _portalController,
      direction: BubbleDirection.up,
      width: 280,
      contentBuilder: (_) => const _MediaLoopPopup(),
      child: IconButton(
        icon: Icon(icon),
        iconSize: 22,
        color: active
            ? colorScheme.primary
            : colorScheme.onSurface.withValues(alpha: 0.6),
        style: active
            ? IconButton.styleFrom(
                backgroundColor: colorScheme.primaryContainer,
              )
            : null,
        onPressed: _portalController.toggle,
      ),
    );
  }
}

class _MediaLoopPopup extends ConsumerWidget {
  const _MediaLoopPopup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(mediaPlaybackProvider);
    final controller = ref.read(mediaPlaybackProvider.notifier);
    return LoopSettingsContent(
      settings: state.settings,
      hasSentences: state.hasSentences,
      onChanged: controller.updateSettings,
    );
  }
}

class _MediaInfoBar extends StatelessWidget {
  const _MediaInfoBar({required this.state});

  final MediaPlaybackState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final mutedColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.45);
    final captionStyle = AppTextStyles.caption(
      context,
    ).copyWith(color: mutedColor);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state.hasSentences) ...[
          Icon(
            state.settings.singleSentenceMode
                ? Icons.format_quote
                : Icons.article,
            size: 14,
            color: mutedColor,
          ),
          const SizedBox(width: 3),
          Text(
            state.settings.singleSentenceMode
                ? l10n.singleSentenceMode
                : l10n.listMode,
            style: captionStyle,
          ),
          const SizedBox(width: 12),
        ],
        Text(
          formatPlaybackSpeedLabel(state.settings.playbackSpeed),
          style: captionStyle,
        ),
        if (state.settings.loopWhole) ...[
          const SizedBox(width: 12),
          _loopBadge(
            Icons.repeat,
            state.settings.wholeLoopCount,
            state.wholeLoopsDone,
            captionStyle,
            mutedColor,
          ),
        ],
        if (state.settings.loopSentence) ...[
          const SizedBox(width: 12),
          _loopBadge(
            Icons.repeat_one,
            state.settings.sentenceLoopCount,
            state.sentenceRepeatsDone,
            captionStyle,
            mutedColor,
          ),
        ],
      ],
    );
    return Padding(
      key: const ValueKey('media-info-bar'),
      padding: EdgeInsets.fromLTRB(AppSpacing.m, AppSpacing.s, AppSpacing.m, 0),
      child: Center(child: row),
    );
  }

  Widget _loopBadge(
    IconData icon,
    int count,
    int done,
    TextStyle? style,
    Color color,
  ) {
    final label = count == 0
        ? '${done + 1}/∞'
        : '${(done + 1).clamp(1, count)}/$count';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(label, style: style),
      ],
    );
  }
}
