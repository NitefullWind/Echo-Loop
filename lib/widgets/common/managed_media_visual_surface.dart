import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/media_load_result.dart';
import '../../services/app_logger.dart';

/// 自动管理媒体准备、失败重试与迟到结果隔离的可复用画面托管层。
///
/// [load] 与 [cancel] 由 feature controller 注入，组件不直接依赖 Provider 或
/// MediaEngine。每次加载都会分配 generation；切换 [loadKey] 或销毁组件后，旧
/// Future 即使完成也不会覆盖当前 UI。
class ManagedMediaVisualSurface extends StatefulWidget {
  const ManagedMediaVisualSurface({
    super.key,
    required this.loadKey,
    required this.load,
    required this.cancel,
    required this.child,
    this.onReady,
    this.showVideoLoading = true,
  });

  /// 标识当前媒体准备任务；变化时取消旧任务并加载新媒体。
  final Object loadKey;

  /// 启动一次全新的媒体准备任务。
  final Future<MediaLoadResult> Function() load;

  /// 使当前业务加载 generation 失效；实现必须幂等。
  final Future<void> Function() cancel;

  /// 媒体 ready 后展示的业务内容。
  final Widget child;

  /// 当前 generation 首次 ready 后调用一次。
  final VoidCallback? onReady;

  /// 是否展示视频加载文案；音频学习任务只需要通用加载状态。
  final bool showVideoLoading;

  @override
  State<ManagedMediaVisualSurface> createState() =>
      _ManagedMediaVisualSurfaceState();
}

enum _ManagedMediaPhase { loading, ready, failure, cancelled }

class _ManagedMediaVisualSurfaceState extends State<ManagedMediaVisualSurface> {
  var _phase = _ManagedMediaPhase.loading;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _startLoad();
  }

  @override
  void didUpdateWidget(covariant ManagedMediaVisualSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loadKey != widget.loadKey) {
      unawaited(oldWidget.cancel());
      _startLoad();
    }
  }

  @override
  void dispose() {
    _generation += 1;
    if (_phase != _ManagedMediaPhase.ready) {
      unawaited(widget.cancel());
    }
    super.dispose();
  }

  /// 启动并守卫一次加载；只有最新 generation 可以提交终态。
  void _startLoad() {
    final generation = ++_generation;
    if (mounted) {
      setState(() => _phase = _ManagedMediaPhase.loading);
    }
    // 首次加载可能同步写入 Provider，必须等当前 widget tree 完成本帧构建。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      unawaited(_runLoad(generation));
    });
  }

  Future<void> _runLoad(int generation) async {
    MediaLoadResult result;
    AppLogger.log(
      'ManagedMedia',
      'event=startup_started generation=$generation loadKey=${widget.loadKey}',
    );
    try {
      result = await widget.load();
    } catch (error, stackTrace) {
      AppLogger.log(
        'ManagedMedia',
        '✗ load command failed: $error\n$stackTrace',
      );
      result = MediaLoadResult.failure;
    }
    if (!mounted || generation != _generation) return;

    switch (result) {
      case MediaLoadResult.ready:
        AppLogger.log(
          'ManagedMedia',
          'event=startup_ready generation=$generation loadKey=${widget.loadKey}',
        );
        setState(() => _phase = _ManagedMediaPhase.ready);
        widget.onReady?.call();
      case MediaLoadResult.failure:
        AppLogger.log(
          'ManagedMedia',
          'event=startup_failed generation=$generation loadKey=${widget.loadKey}',
        );
        setState(() => _phase = _ManagedMediaPhase.failure);
      case MediaLoadResult.cancelled:
        AppLogger.log(
          'ManagedMedia',
          'event=startup_cancelled generation=$generation loadKey=${widget.loadKey}',
        );
        setState(() => _phase = _ManagedMediaPhase.cancelled);
    }
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final overlay = switch (_phase) {
      _ManagedMediaPhase.loading => _MediaLoadingOverlay(
        key: ValueKey('managed-media-loading'),
        showVideoLoading: widget.showVideoLoading,
      ),
      _ManagedMediaPhase.failure => _MediaFailureOverlay(
        key: const ValueKey('managed-media-failure'),
        onRetry: _startLoad,
        showVideoLoading: widget.showVideoLoading,
      ),
      _ManagedMediaPhase.cancelled => _MediaLoadingOverlay(
        key: ValueKey('managed-media-cancelled'),
        showVideoLoading: widget.showVideoLoading,
      ),
      _ManagedMediaPhase.ready => const SizedBox.shrink(
        key: ValueKey('managed-media-ready'),
      ),
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            ignoring: _phase == _ManagedMediaPhase.ready,
            child: AnimatedSwitcher(
              duration: disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              child: overlay,
            ),
          ),
        ),
      ],
    );
  }
}

class _MediaLoadingOverlay extends StatelessWidget {
  const _MediaLoadingOverlay({super.key, required this.showVideoLoading});

  final bool showVideoLoading;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 视频加载画布是固定格式的临时状态，不应被系统字体缩放撑破。用局部
    // MediaQuery 固定整个遮罩，确保进度圈、间距和文案始终是同一视觉规格。
    return MediaQuery.withNoTextScaling(
      child: _MediaOverlayFrame(
        child: Semantics(
          label: showVideoLoading ? l10n.videoLoading : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 12),
              if (showVideoLoading)
                Text(
                  l10n.videoLoading,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaFailureOverlay extends StatelessWidget {
  const _MediaFailureOverlay({
    super.key,
    required this.onRetry,
    required this.showVideoLoading,
  });

  final VoidCallback onRetry;
  final bool showVideoLoading;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _MediaOverlayFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 40, color: Colors.white),
          const SizedBox(height: 12),
          if (showVideoLoading)
            Text(
              l10n.videoLoadFailed,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: Text(l10n.videoRetry)),
        ],
      ),
    );
  }
}

/// 在任意父级约束内保留稳定的 16:9 视频画布，其余区域保持页面背景。
class _MediaOverlayFrame extends StatelessWidget {
  const _MediaOverlayFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          final maxHeight = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : 260.0;
          final height = math.min(width / (16 / 9), math.min(260.0, maxHeight));
          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              key: const ValueKey('managed-media-overlay-canvas'),
              width: double.infinity,
              height: height,
              child: ColoredBox(
                color: Colors.black,
                child: Center(child: child),
              ),
            ),
          );
        },
      ),
    );
  }
}
