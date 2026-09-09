import 'dart:async';

import 'package:clock/clock.dart';

import '../models/study_stage.dart';
import 'app_logger.dart';
import 'study_activity_gate.dart';
import 'study_time_service.dart';

/// 统计一个固定阶段的前台有效学习会话，并以增量方式定期落库。
///
/// 会话的生命周期由学习页面控制，而不是由播放器控制。播放暂停或结束
/// 只会停止输入时长；只要页面仍有用户活动，总学习时长仍会继续累计。
/// 计时器实例一经创建只属于一个 [StudyStage]；阶段切换必须先 dispose
/// 旧实例再创建新实例。checkpoint 与 stop 共用串行落库操作，失败时
/// 不推进已持久化游标，下一次 checkpoint 或 stop 会重试同一增量。
final class StudySessionTimer {
  StudySessionTimer({
    required StudyTimeService studyTimeService,
    required StudyStage stage,
    required StudyActivityGate activityGate,
    this.checkpointInterval = const Duration(seconds: 30),
    this.idleTimeout,
    String? logScope,
  }) : _studyTimeService = studyTimeService,
       _stage = stage,
       _activityGate = activityGate,
       _studyStopwatch = clock.stopwatch(),
       _inputStopwatch = clock.stopwatch(),
       _logScope = logScope ?? 'StudySessionTimer' {
    if (checkpointInterval <= Duration.zero) {
      throw ArgumentError.value(
        checkpointInterval,
        'checkpointInterval',
        '必须大于 0。',
      );
    }
    final timeout = idleTimeout;
    if (timeout != null && timeout <= Duration.zero) {
      throw ArgumentError.value(idleTimeout, 'idleTimeout', '必须为 null 或大于 0。');
    }
    _activityGate.addListener(_onActivityChanged);
  }

  final StudyTimeService _studyTimeService;
  final StudyStage _stage;
  final StudyActivityGate _activityGate;
  final Duration checkpointInterval;
  final Duration? idleTimeout;
  final Stopwatch _studyStopwatch;
  final Stopwatch _inputStopwatch;
  final String _logScope;
  Timer? _checkpointTimer;
  Timer? _idleTimer;
  Future<void>? _checkpointOperation;
  int _persistedStudyMilliseconds = 0;
  int _persistedInputMilliseconds = 0;
  bool _started = false;
  bool _stopped = false;

  /// 页面会话仍处于活跃窗口内。
  bool _studyActive = false;

  /// 当前是否有音频/视频实际处于播放状态。
  bool _playbackActive = false;

  /// 当前会话累计的前台有效时长。
  Duration get elapsed => _studyStopwatch.elapsed;

  /// 当前会话累计的前台输入（播放）时长。
  Duration get inputElapsed => _inputStopwatch.elapsed;

  /// 当前是否正在累计总学习时长。
  bool get isRunning => _studyStopwatch.isRunning;

  /// 启动页面学习会话；重复调用不会重置已累计时长。
  void start() {
    if (_stopped || _started) return;
    _started = true;
    _studyActive = true;
    if (_activityGate.isForeground) {
      _startForegroundTiming();
    }
    AppLogger.log(_logScope, 'session.start stage=${_stage.name}');
  }

  /// 标记一次用户活动，并在 idle 后自动恢复总学习时长。
  void markActivity() {
    if (!_started || _stopped || !_activityGate.isForeground) return;
    final resumesFromIdle = !_studyActive;
    _studyActive = true;
    _startForegroundTiming();
    _scheduleIdleTimeout();
    if (resumesFromIdle) {
      AppLogger.log(
        _logScope,
        'session.activity stage=${_stage.name} resumedFromIdle=true',
      );
    }
  }

  /// 更新播放器活动状态。
  ///
  /// 播放期间持续计入输入时长；播放暂停或结束后不结束页面学习会话，
  /// 只等待 [idleTimeout] 到期后暂停总学习时长。
  void setPlaybackActive(bool active) {
    if (!_started || _stopped) return;
    _playbackActive = active;
    if (!_activityGate.isForeground) return;
    if (active) {
      _studyActive = true;
      _startForegroundTiming();
      _scheduleIdleTimeout();
      return;
    }
    _inputStopwatch.stop();
    // 播放结束本身是一次学习会话事件，为用户继续思考保留 idle 窗口。
    markActivity();
  }

  /// 只落库尚未持久化的有效时长；同一时刻的调用共享一个操作。
  Future<void> flush() {
    final active = _checkpointOperation;
    if (active != null) return active;
    final operation = _flushIncrement();
    final scheduled = operation.whenComplete(() {
      _checkpointOperation = null;
    });
    _checkpointOperation = scheduled;
    return scheduled;
  }

  Future<void> _flushIncrement() async {
    final elapsedMilliseconds = _studyStopwatch.elapsedMilliseconds;
    final pendingStudyMilliseconds =
        elapsedMilliseconds - _persistedStudyMilliseconds;
    final pendingInputMilliseconds =
        _inputStopwatch.elapsedMilliseconds - _persistedInputMilliseconds;
    if (pendingStudyMilliseconds <= 0 && pendingInputMilliseconds <= 0) {
      return;
    }
    try {
      await _studyTimeService.recordSessionDurations(
        studyDuration: Duration(milliseconds: pendingStudyMilliseconds),
        inputDuration: Duration(milliseconds: pendingInputMilliseconds),
        stage: _stage,
      );
      _persistedStudyMilliseconds += pendingStudyMilliseconds;
      _persistedInputMilliseconds += pendingInputMilliseconds;
      AppLogger.log(
        _logScope,
        'session.flush stage=${_stage.name} pendingStudyMs=$pendingStudyMilliseconds '
        'pendingInputMs=$pendingInputMilliseconds totalMs=$elapsedMilliseconds',
      );
    } catch (error, stackTrace) {
      AppLogger.log(
        _logScope,
        'session.flush.failed stage=${_stage.name} error=$error\n$stackTrace',
      );
      rethrow;
    }
  }

  /// 结束页面学习会话，等待在途 checkpoint，再写入最后增量。
  Future<void> stop() async {
    if (_stopped) {
      await flush();
      return;
    }
    _stopped = true;
    _studyActive = false;
    _playbackActive = false;
    _stopForegroundTiming();
    await flush();
    AppLogger.log(
      _logScope,
      'session.stop stage=${_stage.name} '
      'totalMs=${_studyStopwatch.elapsedMilliseconds}',
    );
  }

  /// 停止失败也必须释放生命周期资源。
  Future<void> dispose() async {
    try {
      await stop();
    } finally {
      _activityGate.removeListener(_onActivityChanged);
      _checkpointTimer?.cancel();
      _checkpointTimer = null;
      _idleTimer?.cancel();
      _idleTimer = null;
      _studyStopwatch.stop();
      _inputStopwatch.stop();
    }
  }

  void _startForegroundTiming() {
    if (!_activityGate.isForeground || (!_studyActive && !_playbackActive)) {
      return;
    }
    if (!_studyStopwatch.isRunning) _studyStopwatch.start();
    if (_playbackActive && !_inputStopwatch.isRunning) {
      _inputStopwatch.start();
    }
    if (_checkpointTimer != null) return;
    _checkpointTimer ??= Timer.periodic(checkpointInterval, (_) {
      unawaited(_flushFromTimer());
    });
    _scheduleIdleTimeout();
  }

  Future<void> _flushFromTimer() async {
    try {
      await flush();
    } catch (error, stackTrace) {
      AppLogger.log(_logScope, 'checkpoint.failed error=$error\n$stackTrace');
    }
  }

  void _stopForegroundTiming() {
    _studyStopwatch.stop();
    _inputStopwatch.stop();
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
  }

  void _onActivityChanged(bool isForeground) {
    if (!_started || _stopped) return;
    if (isForeground) {
      if (_studyActive || _playbackActive) _startForegroundTiming();
      AppLogger.log(_logScope, 'session.resume stage=${_stage.name}');
    } else {
      _idleTimer?.cancel();
      _idleTimer = null;
      unawaited(_flushFromActivityChange());
    }
  }

  Future<void> _flushFromActivityChange() async {
    _stopForegroundTiming();
    AppLogger.log(
      _logScope,
      'session.background stage=${_stage.name} '
      'elapsedMs=${_studyStopwatch.elapsedMilliseconds}',
    );
    try {
      await flush();
    } catch (error, stackTrace) {
      AppLogger.log(
        _logScope,
        'activity.flush.failed error=$error\n$stackTrace',
      );
    }
  }

  void _scheduleIdleTimeout() {
    final timeout = idleTimeout;
    if (timeout == null || _playbackActive || !_studyActive) {
      _idleTimer?.cancel();
      _idleTimer = null;
      return;
    }
    _idleTimer?.cancel();
    _idleTimer = Timer(timeout, _onIdleTimeout);
  }

  void _onIdleTimeout() {
    _idleTimer = null;
    if (!_started || _stopped || !_activityGate.isForeground) return;
    if (_playbackActive) {
      _scheduleIdleTimeout();
      return;
    }
    _studyActive = false;
    _stopForegroundTiming();
    unawaited(_flushFromTimer());
    AppLogger.log(_logScope, 'session.idle stage=${_stage.name}');
  }
}
