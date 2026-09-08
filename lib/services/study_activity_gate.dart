import 'package:flutter/widgets.dart';

/// 学习统计基础设施接收的前后台资格变化回调。
typedef StudyActivityListener = void Function(bool isForeground);

/// 统一判断学习统计事件是否发生在前台有效状态。
///
/// 统计基础设施通过此门控统一过滤后台、隐藏和非激活状态，
/// 业务播放器无需在每个回调中重复判断 App 生命周期。
final class StudyActivityGate {
  StudyActivityGate() {
    _isForeground = _isForegroundState(WidgetsBinding.instance.lifecycleState);
    _lifecycleListener = AppLifecycleListener(onStateChange: _onStateChange);
  }

  late final AppLifecycleListener _lifecycleListener;
  bool _isForeground = true;
  final Set<StudyActivityListener> _listeners = <StudyActivityListener>{};

  /// 当前是否允许将学习事件写入统计。
  bool get isForeground => _isForeground;

  /// 监听前后台资格变化，供需要暂停/恢复会话的统计基础设施复用。
  void addListener(StudyActivityListener listener) {
    _listeners.add(listener);
  }

  /// 移除前后台资格监听。
  void removeListener(StudyActivityListener listener) {
    _listeners.remove(listener);
  }

  /// 释放生命周期监听。
  void dispose() {
    _listeners.clear();
    _lifecycleListener.dispose();
  }

  void _onStateChange(AppLifecycleState state) {
    final nextIsForeground = _isForegroundState(state);
    if (_isForeground == nextIsForeground) return;
    _isForeground = nextIsForeground;
    for (final listener in List<StudyActivityListener>.of(_listeners)) {
      listener(_isForeground);
    }
  }

  static bool _isForegroundState(AppLifecycleState? state) {
    return state == null || state == AppLifecycleState.resumed;
  }
}
