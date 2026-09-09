import 'package:flutter/widgets.dart';

/// 捕获学习页面上的低频用户活动，用于刷新学习会话的 idle deadline。
///
/// 只监听一次指针按下和滚轮信号，不订阅高频 position 或 pointer move，
/// 具体的节流、前后台判断和状态变更由页面控制器持有的会话负责。
final class StudyActivityDetector extends StatefulWidget {
  const StudyActivityDetector({
    required this.onActivity,
    required this.child,
    super.key,
  });

  final VoidCallback onActivity;
  final Widget child;

  @override
  State<StudyActivityDetector> createState() => _StudyActivityDetectorState();
}

final class _StudyActivityDetectorState extends State<StudyActivityDetector> {
  static const _activityThrottle = Duration(milliseconds: 250);
  final Stopwatch _throttle = Stopwatch();

  void _notifyActivity() {
    if (_throttle.isRunning && _throttle.elapsed < _activityThrottle) return;
    _throttle
      ..reset()
      ..start();
    widget.onActivity();
  }

  @override
  void dispose() {
    _throttle.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _notifyActivity(),
      onPointerSignal: (_) => _notifyActivity(),
      child: widget.child,
    );
  }
}
