/// 录音按钮（共享组件）
///
/// 圆形按钮 + 话筒图标，录音中带音波动画。
/// 三种模式：idle（待录音）、recording（录音中）、disabled（禁用）。
///
/// **纯展示组件**：只接收 UI 数据和回调，不依赖任何 Provider 状态类型。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 录音按钮模式
enum RecordingButtonMode {
  /// 待录音（蓝色麦克风，可点击）
  idle,

  /// 录音中（红色脉冲麦克风）
  recording,

  /// 禁用（灰显麦克风，不可点击）
  disabled,
}

const _buttonSize = 56.0;
const _iconSize = 28.0;

/// 录音按钮
class RecordingButton extends StatefulWidget {
  /// 显示模式
  final RecordingButtonMode mode;

  /// 点击回调
  final VoidCallback onTap;

  const RecordingButton({super.key, required this.mode, required this.onTap});

  @override
  State<RecordingButton> createState() => _RecordingButtonState();
}

class _RecordingButtonState extends State<RecordingButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _waveController;

  static const _waveDuration = Duration(milliseconds: 1400);

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(vsync: this, duration: _waveDuration);
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant RecordingButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.mode == RecordingButtonMode.recording) {
      if (!_waveController.isAnimating) _waveController.repeat();
    } else {
      _waveController.stop();
      _waveController.reset();
    }
  }

  @override
  void dispose() {
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRecording = widget.mode == RecordingButtonMode.recording;
    final isDisabled = widget.mode == RecordingButtonMode.disabled;

    final Color bgColor;
    final Color iconColor;
    final double elevation;

    if (isRecording) {
      bgColor = theme.colorScheme.error;
      iconColor = theme.colorScheme.onError;
      elevation = 4;
    } else {
      bgColor = theme.colorScheme.primaryContainer;
      iconColor = theme.colorScheme.primary;
      elevation = 1;
    }

    return IgnorePointer(
      ignoring: isDisabled,
      child: Opacity(
        opacity: isDisabled ? 0.45 : 1.0,
        child: SizedBox(
          width: _buttonSize,
          height: _buttonSize,
          child: Material(
            shape: const CircleBorder(),
            color: bgColor,
            elevation: elevation,
            shadowColor: bgColor.withValues(alpha: 0.4),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onTap,
              customBorder: const CircleBorder(),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (isRecording)
                    AnimatedBuilder(
                      animation: _waveController,
                      builder: (context, _) => CustomPaint(
                        size: const Size(_buttonSize, _buttonSize),
                        painter: _WaveArcPainter(
                          progress: _waveController.value,
                          color: iconColor,
                        ),
                      ),
                    ),
                  Icon(Icons.mic_rounded, size: _iconSize, color: iconColor),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 音波弧线画笔
class _WaveArcPainter extends CustomPainter {
  final double progress;
  final Color color;

  _WaveArcPainter({required this.progress, required this.color});

  static const _arcCount = 3;
  static const _arcWindow = 0.45;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    for (var i = 0; i < _arcCount; i++) {
      final start = i / _arcCount;
      final localT = _localProgress(progress, start, _arcWindow);
      if (localT <= 0) continue;

      final alpha = localT <= 0.5 ? localT * 2 : (1.0 - localT) * 2;
      paint.color = color.withValues(alpha: alpha * 0.65);
      paint.strokeWidth = 2.0;

      final radius = 14.0 + 5.0 * i + 3.0 * localT;
      const sweepAngle = 55.0 * math.pi / 180;
      const halfSweep = sweepAngle / 2;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -halfSweep,
        sweepAngle,
        false,
        paint,
      );
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        math.pi - halfSweep,
        sweepAngle,
        false,
        paint,
      );
    }
  }

  double _localProgress(double global, double start, double window) {
    var diff = global - start;
    if (diff < 0) diff += 1.0;
    if (diff > window) return 0.0;
    return diff / window;
  }

  @override
  bool shouldRepaint(covariant _WaveArcPainter old) => old.progress != progress;
}
