import 'dart:async';

import '../models/study_stage.dart';
import 'app_logger.dart';
import 'study_activity_gate.dart';
import 'study_time_service.dart';

/// 统计一个前台有效学习会话，并以增量方式定期落库。
///
/// 计时器只负责会话生命周期和可靠落库，具体数据库写入统一委托给
/// [StudyTimeService]。后台、隐藏和锁屏期间不会计入学习时长。
final class StudySessionTimer {
  StudySessionTimer({
    required StudyTimeService studyTimeService,
    required StudyStage stage,
    required StudyActivityGate activityGate,
    this.checkpointInterval = const Duration(seconds: 30),
    this.recordInputDuration = false,
    String? logScope,
  }) : _studyTimeService = studyTimeService,
       _stage = stage,
       _activityGate = activityGate,
       _logScope = logScope ?? 'StudySessionTimer' {
    if (checkpointInterval <= Duration.zero) {
      throw ArgumentError.value(
        checkpointInterval,
        'checkpointInterval',
        '必须大于 0。',
      );
    }
    _activityGate.addListener(_onActivityChanged);
  }

  final StudyTimeService _studyTimeService;
  final StudyStage _stage;
  final StudyActivityGate _activityGate;
  final Duration checkpointInterval;

  /// 是否将同一段前台有效时长同时计入听力时长。
  ///
  /// 默认关闭，避免复习/任务计时被误归类为输入；随心听播放显式开启。
  final bool recordInputDuration;
  final String _logScope;
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _checkpointTimer;
  Future<void>? _flushOperation;
  int _persistedStudyMilliseconds = 0;
  int _persistedInputMilliseconds = 0;
  bool _started = false;
  bool _stopped = false;
  /// 区分“用户/业务主动暂停”和“App 进入后台”：前者不应在回前台时自动恢复。
  bool _timingRequested = false;

  /// 当前会话累计的前台有效时长。
  Duration get elapsed => _stopwatch.elapsed;

  /// 启动当前会话；重复调用不会重置已累计时长。
  void start() {
    if (_stopped || _started) return;
    _started = true;
    _timingRequested = true;
    if (_activityGate.isForeground) _startForegroundTiming();
    AppLogger.log(_logScope, 'session.start stage=${_stage.name}');
  }

  /// 暂停前台计时，并立即尝试落库。
  Future<void> pause() async {
    if (!_started || _stopped) return;
    _timingRequested = false;
    await _pauseAndFlush();
  }

  /// 恢复前台计时。
  void resume() {
    if (!_started || _stopped) return;
    _timingRequested = true;
    if (!_activityGate.isForeground) return;
    _startForegroundTiming();
    AppLogger.log(_logScope, 'session.resume stage=${_stage.name}');
  }

  /// 只落库尚未持久化的有效时长。
  Future<void> flush() {
    final active = _flushOperation;
    if (active != null) return active;
    final operation = _flushIncrement();
    _flushOperation = operation;
    return operation.whenComplete(() => _flushOperation = null);
  }

  Future<void> _flushIncrement() async {
    final elapsedMilliseconds = _stopwatch.elapsedMilliseconds;
    final pendingStudyMilliseconds =
        elapsedMilliseconds - _persistedStudyMilliseconds;
    final pendingInputMilliseconds = recordInputDuration
        ? elapsedMilliseconds - _persistedInputMilliseconds
        : 0;
    if (pendingStudyMilliseconds <= 0 && pendingInputMilliseconds <= 0) return;
    try {
      if (pendingStudyMilliseconds > 0) {
        await _studyTimeService.addStudyDuration(
          Duration(milliseconds: pendingStudyMilliseconds),
          stage: _stage,
        );
        _persistedStudyMilliseconds += pendingStudyMilliseconds;
      }
      if (pendingInputMilliseconds > 0) {
        await _studyTimeService.addInputDuration(
          Duration(milliseconds: pendingInputMilliseconds),
          stage: _stage,
        );
        _persistedInputMilliseconds += pendingInputMilliseconds;
      }
      AppLogger.log(
        _logScope,
        'session.flush stage=${_stage.name} pendingStudyMs=$pendingStudyMilliseconds '
        'pendingInputMs=$pendingInputMilliseconds '
        'totalMs=$elapsedMilliseconds',
      );
    } catch (error, stackTrace) {
      AppLogger.log(
        _logScope,
        'session.flush.failed stage=${_stage.name} error=$error\n$stackTrace',
      );
    }
  }

  /// 停止会话、最终落库并释放资源。
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _timingRequested = false;
    _stopForegroundTiming();
    await flush();
    AppLogger.log(
      _logScope,
      'session.stop stage=${_stage.name} totalMs=${_stopwatch.elapsedMilliseconds}',
    );
  }

  /// stop 的资源释放别名，便于 Provider 销毁时安全调用。
  Future<void> dispose() async {
    await stop();
    _activityGate.removeListener(_onActivityChanged);
  }

  void _startForegroundTiming() {
    if (_stopwatch.isRunning) return;
    _stopwatch.start();
    _checkpointTimer ??= Timer.periodic(checkpointInterval, (_) {
      unawaited(flush());
    });
  }

  void _stopForegroundTiming() {
    _stopwatch.stop();
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
  }

  void _onActivityChanged(bool isForeground) {
    if (!_started || _stopped) return;
    if (isForeground) {
      if (!_timingRequested) return;
      _startForegroundTiming();
      AppLogger.log(_logScope, 'session.resume stage=${_stage.name}');
    } else {
      unawaited(_pauseForActivity());
    }
  }

  /// App 进入后台时暂停前台计时，但保留业务层的恢复意图。
  Future<void> _pauseForActivity() => _pauseAndFlush();

  Future<void> _pauseAndFlush() async {
    _stopForegroundTiming();
    AppLogger.log(
      _logScope,
      'session.pause stage=${_stage.name} elapsedMs=${_stopwatch.elapsedMilliseconds}',
    );
    await flush();
  }
}
